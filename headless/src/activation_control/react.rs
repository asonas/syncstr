//! What a host does on its own with the control records it holds. The owner
//! consented by freezing the host and designating the session; a host reacts
//! to that session only, and signs nothing for any other.
use super::journal::{all, inspect, local_grant};
use super::*;
use rusqlite::Connection;

/// The implementation a host names in its prepared acknowledgment.
pub const IMPLEMENTATION: &str = concat!("syncstr-headless/", env!("CARGO_PKG_VERSION"));
/// Projection profiles this build implements. None is bound to an
/// implementation yet, so a proposal that requires one is not prepared.
pub const PROFILES: &[&str] = &[];

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Step {
    Withdraw,
    Install,
    Prepare,
}

/// One step a host took, or could not take yet, for its designated session.
#[derive(Debug)]
pub struct Reaction {
    pub step: Step,
    /// The proposal withdrawn from or prepared, or the certificate installed.
    pub subject: Digest,
    pub outcome: anyhow::Result<Signed>,
}

enum Planned {
    Withdraw(Digest),
    Install(Digest),
    Prepare(Box<Prepared>),
}

impl Planned {
    fn step(&self) -> Step {
        match self {
            Self::Withdraw(_) => Step::Withdraw,
            Self::Install(_) => Step::Install,
            Self::Prepare(_) => Step::Prepare,
        }
    }
}

struct Plan {
    session: Session,
    host: Host,
    steps: Vec<Planned>,
}

fn plan(
    db: &Connection,
    key: Key,
    implementations: &[String],
    supported: &BTreeSet<String>,
) -> anyhow::Result<Option<Plan>> {
    if !freeze::exists(db, "activation_control_state")? {
        return Ok(None);
    }
    let Some(session) = freeze::designated(db)? else {
        return Ok(None);
    };
    // A journal that needs review is left exactly as it is.
    let Ok(inspection) = inspect(db) else {
        return Ok(None);
    };
    // The owner consents by freezing and designating; a host that is not
    // frozen signs nothing, a withdrawal included.
    if inspection.halted || !inspection.frozen {
        return Ok(None);
    }
    let host = Host {
        key,
        grant: local_grant(db)?,
    };
    let records = all(db)?;
    let designated =
        |p: &Proposal| p.coordinator == session.coordinator && p.nonce == session.nonce;
    let mut certified = BTreeSet::new();
    let mut steps = Vec::new();
    for (id, signed) in &records {
        let Body::Certificate(c) = &signed.body else {
            continue;
        };
        certified.insert(c.proposal.id()?);
        let p = proposal(&c.proposal)?;
        if !designated(p) || !p.hosts.contains(&host) {
            continue;
        }
        // A stored certificate, or an installed head whose acknowledgment was
        // lost before it was stored.
        if inspection.pending_certificates.contains(id)
            || (inspection.head == Some(*id) && inspection.unacknowledged.contains(&key))
        {
            steps.push(Planned::Install(*id));
        }
    }
    for (id, signed) in &records {
        let Body::Proposal(p) = &signed.body else {
            continue;
        };
        if !designated(p)
            || !p.hosts.contains(&host)
            || certified.contains(id)
            || inspection.aborted.contains(id)
        {
            continue;
        }
        let abandoned = records.values().any(|other| {
            matches!(&other.body, Body::Withdrawn(w)
                if w.proposal == *id && w.host == p.coordinator)
        });
        if abandoned {
            if !inspection.withdrawn.contains(id) {
                steps.push(Planned::Withdraw(*id));
            }
            continue;
        }
        let acknowledged =
            inspection.prepare_locks.contains(id) && !inspection.unsigned_preparations.contains(id);
        // A readable, unhalted journal holds no other open proposal than one
        // that extends the installed head: a sibling halts it.
        if inspection.withdrawn.contains(id) || acknowledged {
            continue;
        }
        steps.push(Planned::Prepare(Box::new(Prepared {
            proposal: *id,
            host: host.clone(),
            implementations: implementations.to_vec(),
            implemented_profiles: supported.iter().cloned().collect(),
            input_history: intake::input_history(db)?,
            baseline: p.baseline,
            write_frozen: true,
            admission_frozen: true,
            minimum_profiles: p.profiles.clone(),
        })));
    }
    steps.sort_by_key(Planned::step);
    Ok(Some(Plan {
        session,
        host,
        steps,
    }))
}

impl crate::shared_audio::Store {
    /// React to the control records this host holds for its designated
    /// session: withdraw from a proposal its coordinator withdrew from,
    /// install a stored certificate, and prepare a proposal that extends the
    /// installed head. It does nothing unless the host is frozen. Every step
    /// goes through the journal operation of the same name, whose rules still
    /// apply; a step that is refused is reported and tried again on a later
    /// call.
    pub fn control_react(
        &self,
        identity: &crate::peer::Identity,
        implementations: &[String],
        supported: &BTreeSet<String>,
    ) -> anyhow::Result<Vec<Reaction>> {
        let key = *identity.id().as_bytes();
        let Some(plan) = self.run(|db, _| plan(db, key, implementations, supported))? else {
            return Ok(vec![]);
        };
        let (session, host) = (plan.session, plan.host);
        Ok(plan
            .steps
            .into_iter()
            .map(|planned| {
                let step = planned.step();
                match planned {
                    Planned::Withdraw(id) => Reaction {
                        step,
                        subject: id,
                        outcome: self.control_withdraw(id, host.clone(), identity, &session),
                    },
                    Planned::Install(id) => Reaction {
                        step,
                        subject: id,
                        outcome: self.control_install(
                            id,
                            host.clone(),
                            identity,
                            &session,
                            supported,
                        ),
                    },
                    Planned::Prepare(ack) => Reaction {
                        step,
                        subject: ack.proposal,
                        outcome: self.control_prepare(*ack, identity, &session, supported),
                    },
                }
            })
            .collect())
    }
}
