//! What a host tells a peer about its control journal, and how it serves and
//! takes in signed envelopes. No network code.
use super::journal::{all, get, inspect, proof, state};
use super::*;
use rusqlite::Connection;
use std::collections::BTreeMap;
use std::collections::btree_map::Entry;

/// A readable control journal at a glance.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Summary {
    pub epoch: u64,
    pub head: Option<Digest>,
    pub frozen: bool,
    pub released: bool,
    pub halted: bool,
    /// A preparation or a certificate is unresolved.
    pub pending: bool,
    pub session: Option<Session>,
    /// Absent while the local membership cannot be verified.
    pub membership: Option<Digest>,
    pub input_history: Digest,
    pub envelopes: Vec<Digest>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "kebab-case", deny_unknown_fields)]
pub enum Journal {
    /// Control storage was never initialized on this host.
    Absent,
    /// The journal exists and needs review before anything relies on it.
    Unreadable,
    Readable { summary: Box<Summary> },
}

fn proposed(db: &Connection, signed: &Signed) -> anyhow::Result<Signed> {
    Ok(match &signed.body {
        Body::Proposal(_) => signed.clone(),
        Body::Certificate(c) => c.proposal.as_ref().clone(),
        Body::Prepared(a) => get(db, &a.proposal)?,
        Body::Installed(i) => certificate(&get(db, &i.certificate)?)?
            .proposal
            .as_ref()
            .clone(),
        Body::Withdrawn(w) => get(db, &w.proposal)?,
        Body::Aborted(a) => get(db, &a.proposal)?,
    })
}

/// Dependencies first: a proposal before what refers to it, and a certificate
/// before its installation acknowledgments.
fn rank(body: &Body) -> u8 {
    match body {
        Body::Proposal(_) => 0,
        Body::Prepared(_) => 1,
        Body::Withdrawn(_) => 2,
        Body::Aborted(_) => 3,
        Body::Certificate(_) => 4,
        Body::Installed(_) => 5,
    }
}

impl crate::shared_audio::Store {
    pub fn control_journal(&self) -> anyhow::Result<Journal> {
        self.run(|db, _| {
            if !freeze::exists(db, "activation_control_state")? {
                return Ok(Journal::Absent);
            }
            let Ok(inspection) = inspect(db) else {
                return Ok(Journal::Unreadable);
            };
            let cluster = state(db)?.cluster;
            let membership = crate::enrollment::read_proof(db)
                .and_then(|current| membership_revision(cluster, &current))
                .ok()
                .map(|(revision, _)| revision);
            Ok(Journal::Readable {
                summary: Box::new(Summary {
                    epoch: inspection.epoch,
                    head: inspection.head,
                    frozen: inspection.frozen,
                    released: inspection.released,
                    halted: inspection.halted,
                    pending: !inspection.pending_preparations.is_empty()
                        || !inspection.pending_certificates.is_empty(),
                    session: freeze::designated(db)?,
                    membership,
                    input_history: intake::input_history(db)?,
                    envelopes: all(db)?.into_keys().collect(),
                }),
            })
        })
    }

    /// The requested envelopes this host holds, each with the membership
    /// revision of its proposal, and the membership snapshots by revision.
    #[allow(clippy::type_complexity)]
    pub fn control_evidence(
        &self,
        ids: &[Digest],
    ) -> anyhow::Result<(
        Vec<(Signed, Digest)>,
        BTreeMap<Digest, crate::enrollment::Proof>,
    )> {
        self.run(|db, _| {
            let mut envelopes = Vec::new();
            let mut memberships = BTreeMap::new();
            for id in ids {
                // An envelope this host cannot produce intact is not served.
                let Ok(signed) = get(db, id) else { continue };
                let Ok(stored) = proposed(db, &signed) else {
                    continue;
                };
                let p = proposal(&stored)?;
                if let Entry::Vacant(entry) = memberships.entry(p.membership) {
                    let Ok(snapshot) = proof(db, &p.membership, p.cluster) else {
                        continue;
                    };
                    entry.insert(snapshot);
                }
                envelopes.push((signed, p.membership));
            }
            Ok((envelopes, memberships))
        })
    }

    /// Record envelopes received from a peer under the session the owner
    /// designated on this host. Without a designation nothing is recorded.
    pub fn control_accept(
        &self,
        mut evidence: Vec<(Signed, crate::enrollment::Proof)>,
    ) -> anyhow::Result<Vec<(Digest, anyhow::Result<Outcome>)>> {
        let Some(session) = self.control_session()? else {
            return Ok(vec![]);
        };
        evidence.sort_by_key(|(signed, _)| rank(&signed.body));
        evidence
            .into_iter()
            .map(|(signed, membership)| {
                Ok((
                    signed.id()?,
                    self.control_record(&signed, &membership, &session),
                ))
            })
            .collect()
    }
}
