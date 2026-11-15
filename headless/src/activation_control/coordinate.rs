//! The designated coordinator drives its session. The owner records a request
//! on the stopped host; the serving host signs the proposal once every host is
//! ready, the certificate once every host prepared, and on request its
//! withdrawal and the abort. Everything else is another host's reaction.
use super::journal::{
    all, array, current_membership, get, inspect, local_grant, proof, record, scope, session,
    signer_matches, state, verified_proposal,
};
use super::*;
use anyhow::Context as _;
use rusqlite::{Connection, OptionalExtension as _, params};
use std::collections::BTreeMap;

/// What the owner asked the coordinator to do in the designated session.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub profiles: Vec<String>,
    pub inventory: Digest,
    pub backup: Digest,
    /// The proposal signed for this request, once every host was ready.
    pub proposal: Option<Digest>,
    /// The owner asked to abort that proposal.
    pub abort: bool,
}

/// What the coordinator learned about another host in the current pass.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Peer {
    pub journal: Journal,
    /// The peer lists an envelope this host lacks and has not seen to be
    /// anything else than a certificate.
    pub withheld: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Progress {
    /// No request is recorded.
    Idle,
    Waiting(String),
    Proposed(Digest),
    Certified(Digest),
    Withdrew(Digest),
    Aborted(Digest),
    Complete(Digest),
}

impl std::fmt::Display for Progress {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Idle => f.write_str("no session requested"),
            Self::Waiting(reason) => write!(f, "waiting: {reason}"),
            Self::Proposed(id) => write!(f, "signed proposal {}", hex::encode(id)),
            Self::Certified(id) => write!(f, "signed the certificate of {}", hex::encode(id)),
            Self::Withdrew(id) => write!(f, "withdrew from proposal {}", hex::encode(id)),
            Self::Aborted(id) => write!(
                f,
                "proposal {} is aborted; designate a new session to try again",
                hex::encode(id)
            ),
            Self::Complete(id) => write!(
                f,
                "proposal {} is installed on every host; release each host",
                hex::encode(id)
            ),
        }
    }
}

enum Next {
    Done(Progress),
    Withdraw(Digest, Session),
    Abort(Digest, Session),
}

fn waiting(reason: impl Into<String>) -> anyhow::Result<Next> {
    Ok(Next::Done(Progress::Waiting(reason.into())))
}

fn name(key: &Key) -> String {
    iroh::EndpointId::from_bytes(key)
        .map(|id| id.to_string())
        .unwrap_or_else(|_| hex::encode(key))
}

fn names<'a>(keys: impl Iterator<Item = &'a Key>) -> String {
    keys.map(name).collect::<Vec<_>>().join(", ")
}

fn request(db: &Connection) -> anyhow::Result<Option<Request>> {
    if !freeze::exists(db, "activation_control_request")? {
        return Ok(None);
    }
    #[allow(clippy::type_complexity)]
    let row: Option<(Vec<u8>, Vec<u8>, Vec<u8>, Option<Vec<u8>>, i64)> = db
        .query_row(
            "SELECT profiles, inventory, backup, proposal, abort FROM activation_control_request",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .optional()?;
    row.map(|(profiles, inventory, backup, proposal, abort)| {
        Ok(Request {
            profiles: serde_json::from_slice(&profiles)?,
            inventory: array(inventory)?,
            backup: array(backup)?,
            proposal: proposal.map(array).transpose()?,
            abort: abort == 1,
        })
    })
    .transpose()
}

/// The designated session, if this host is its coordinator.
fn coordinated(db: &Connection) -> anyhow::Result<Session> {
    let designated = freeze::designated(db)?.context("no session is designated on this host")?;
    ensure!(
        designated.coordinator.grant == local_grant(db)?,
        "this host is not the designated coordinator"
    );
    Ok(designated)
}

/// The certificate stored for a proposal, if any.
fn certificate_of(
    records: &BTreeMap<Digest, Signed>,
    id: &Digest,
) -> anyhow::Result<Option<Digest>> {
    for (stored, signed) in records {
        if let Body::Certificate(c) = &signed.body
            && c.proposal.id()? == *id
        {
            return Ok(Some(*stored));
        }
    }
    Ok(None)
}

/// Why the coordinator does not propose yet. Every host of the membership
/// has to answer in the same pass; the set is never reduced to those that do.
fn unready(
    local: &Summary,
    designated: &Session,
    hosts: &[Host],
    peers: &BTreeMap<Key, Peer>,
) -> Vec<String> {
    let mut reasons = Vec::new();
    if local.membership.is_none() {
        reasons.push("the local membership cannot be verified".to_owned());
    }
    for host in hosts {
        if host.key == designated.coordinator.key {
            continue;
        }
        let reason = match peers.get(&host.key).map(|peer| &peer.journal) {
            None => "was not reached",
            Some(Journal::Absent) => "has no control journal",
            Some(Journal::Unreadable) => "has a control journal that needs review",
            Some(Journal::Readable { summary }) => {
                if summary.halted {
                    "is halted for review"
                } else if !summary.frozen {
                    "is not frozen"
                } else if summary.session.as_ref() != Some(designated) {
                    "is not designated for this session"
                } else if summary.head != local.head || summary.epoch != local.epoch {
                    "is at another installed head"
                } else if summary.membership != local.membership {
                    "has another membership revision"
                } else if summary.input_history != local.input_history {
                    "has another input history"
                } else {
                    continue;
                }
            }
        };
        reasons.push(format!("host {} {reason}", name(&host.key)));
    }
    reasons
}

/// Why the coordinator does not withdraw yet: a host it has not synchronized
/// with in this pass may hold a certificate.
fn unsynchronized(p: &Proposal, peers: &BTreeMap<Key, Peer>) -> Vec<String> {
    let mut reasons = Vec::new();
    for host in &p.hosts {
        if host.key == p.coordinator.key {
            continue;
        }
        let reason = match peers.get(&host.key) {
            None => "was not reached",
            Some(Peer {
                journal: Journal::Readable { .. },
                withheld: false,
            }) => continue,
            Some(Peer {
                journal: Journal::Readable { .. },
                ..
            }) => "holds a control record this host could not take in",
            Some(_) => "has no readable control journal",
        };
        reasons.push(format!("host {} {reason}", name(&host.key)));
    }
    reasons
}

/// Sign and store the certificate of a proposal every host prepared. The
/// coordinator's own withdrawal and its certificate exclude each other: this
/// refuses after any withdrawal, and withdrawing refuses once a certificate is
/// stored. Both commit with their check.
pub(super) fn certify(
    tx: &Connection,
    id: Digest,
    identity: &crate::peer::Identity,
    expected: &Session,
) -> anyhow::Result<Signed> {
    let inspection = inspect(tx)?;
    ensure!(!inspection.halted, "control journal halted for review");
    ensure!(inspection.frozen, "host is not frozen for maintenance");
    let proposed = get(tx, &id)?;
    verified_proposal(tx, &proposed)?;
    let p = proposal(&proposed)?;
    scope(&state(tx)?, p)?;
    session(p, expected)?;
    signer_matches(identity, &p.coordinator)?;
    // A coordinator that knows of a membership change aborts instead.
    current_membership(tx, p)?;
    let records = all(tx)?;
    ensure!(
        !abort::withdrawn(&records).contains(&id) && !inspection.aborted.contains(&id),
        "a host withdrew from this proposal"
    );
    let mut prepared = BTreeMap::new();
    for signed in records.into_values() {
        let key = match &signed.body {
            Body::Prepared(a) if a.proposal == id => a.host.key,
            _ => continue,
        };
        prepared.entry(key).or_insert(signed);
    }
    let signed = Signed::sign(
        Body::Certificate(Certificate {
            proposal: Box::new(proposed.clone()),
            prepared: prepared.into_values().collect(),
            coordinator: p.coordinator.clone(),
        }),
        identity,
    )?;
    let membership = proof(tx, &p.membership, p.cluster)?;
    // Fails while a host has not prepared, or the input histories differ.
    verify_certificate(&signed, &membership)?;
    ensure!(
        record(tx, &signed, &membership, expected)? != Outcome::ReviewRequired,
        "the certificate contradicts a stored record"
    );
    Ok(signed)
}

fn drive(
    db: &mut Connection,
    identity: &crate::peer::Identity,
    peers: &BTreeMap<Key, Peer>,
) -> anyhow::Result<Next> {
    // Dropped without a commit on every path that signs nothing.
    let tx = db.transaction()?;
    let Some(request) = request(&tx)? else {
        return Ok(Next::Done(Progress::Idle));
    };
    let designated = match coordinated(&tx) {
        Ok(designated) => designated,
        Err(error) => return waiting(error.to_string()),
    };
    if designated.coordinator.key != *identity.id().as_bytes() {
        return waiting("the signing identity is not the designated coordinator");
    }
    let inspection = inspect(&tx)?;
    if inspection.halted {
        return waiting("control journal halted for review");
    }
    if !inspection.frozen {
        return waiting("host is not frozen for maintenance");
    }
    let Some(id) = request.proposal else {
        let Journal::Readable { summary } = exchange::journal(&tx)? else {
            return waiting("control journal requires review");
        };
        let s = state(&tx)?;
        let current = crate::enrollment::read_proof(&tx)?;
        let (membership, hosts) = membership_revision(s.cluster, &current)?;
        let mut reasons = unready(&summary, &designated, &hosts, peers);
        // The hosts refuse to prepare while the installed head lacks an
        // acknowledgment of a host the next proposal still authorizes.
        let behind: Vec<_> = inspection
            .unacknowledged
            .iter()
            .filter(|key| hosts.iter().any(|h| h.key == **key))
            .collect();
        if !behind.is_empty() {
            reasons.push(format!(
                "the installed head lacks the acknowledgment of {}",
                names(behind.into_iter())
            ));
        }
        if !reasons.is_empty() {
            return waiting(reasons.join("; "));
        }
        let signed = Signed::sign(
            Body::Proposal(Box::new(Proposal {
                cluster: s.cluster,
                root: s.root,
                baseline: s.baseline,
                previous: s.head,
                epoch: s.epoch.checked_add(1).context("epoch overflow")?,
                membership,
                hosts,
                profiles: request.profiles,
                inventory: request.inventory,
                backup: request.backup,
                coordinator: designated.coordinator.clone(),
                nonce: designated.nonce,
            })),
            identity,
        )?;
        let id = signed.id()?;
        if inspection.aborted.contains(&id) {
            return waiting("this proposal was aborted; designate a new session to try again");
        }
        // A rival of this proposal is left for review by whoever records it;
        // this host does not publish its own side of a fork.
        ensure!(
            record(&tx, &signed, &current, &designated)? != Outcome::ReviewRequired,
            "another proposal extends the installed head"
        );
        tx.execute(
            "UPDATE activation_control_request SET proposal=?",
            [id.as_slice()],
        )?;
        tx.commit()?;
        return Ok(Next::Done(Progress::Proposed(id)));
    };
    if inspection.aborted.contains(&id) {
        return Ok(Next::Done(Progress::Aborted(id)));
    }
    let records = all(&tx)?;
    let proposed = records.get(&id).context("requested proposal is missing")?;
    let p = proposal(proposed)?;
    if let Some(certificate) = certificate_of(&records, &id)? {
        // With a certificate the session only goes forward, also after a
        // request to abort.
        if inspection.pending_certificates.contains(&certificate) {
            return waiting("the certificate is stored and not installed here yet");
        }
        if inspection.head == Some(certificate) && !inspection.unacknowledged.is_empty() {
            return waiting(format!(
                "installation acknowledgments from {}",
                names(inspection.unacknowledged.iter())
            ));
        }
        return Ok(Next::Done(Progress::Complete(id)));
    }
    let lacking = |kind: fn(&Body) -> Option<(&Digest, &Host)>| -> Vec<Key> {
        p.hosts
            .iter()
            .map(|h| h.key)
            .filter(|key| {
                !records.values().any(|signed| {
                    kind(&signed.body)
                        .is_some_and(|(proposal, host)| *proposal == id && host.key == *key)
                })
            })
            .collect()
    };
    if request.abort {
        if !inspection.withdrawn.contains(&id) {
            let reasons = unsynchronized(p, peers);
            if !reasons.is_empty() {
                return waiting(format!("before withdrawing: {}", reasons.join("; ")));
            }
            return Ok(Next::Withdraw(id, designated));
        }
        let missing = lacking(|body| match body {
            Body::Withdrawn(w) => Some((&w.proposal, &w.host)),
            _ => None,
        });
        if !missing.is_empty() {
            return waiting(format!("withdrawals from {}", names(missing.iter())));
        }
        return Ok(Next::Abort(id, designated));
    }
    let missing = lacking(|body| match body {
        Body::Prepared(a) => Some((&a.proposal, &a.host)),
        _ => None,
    });
    if !missing.is_empty() {
        return waiting(format!(
            "prepared acknowledgments from {}",
            names(missing.iter())
        ));
    }
    match certify(&tx, id, identity, &designated) {
        Ok(_) => {
            tx.commit()?;
            Ok(Next::Done(Progress::Certified(id)))
        }
        // Nothing was stored. Only an abort resolves a proposal that cannot
        // be certified.
        Err(error) => waiting(format!(
            "the proposal cannot be certified ({error:#}); request an abort"
        )),
    }
}

impl crate::shared_audio::Store {
    /// Record the owner's request to run the designated session from this
    /// host. Refused unless the host is frozen and is the session's
    /// coordinator, and while an earlier request is unresolved.
    pub fn control_start(
        &self,
        profiles: &BTreeSet<String>,
        inventory: Digest,
        backup: Digest,
    ) -> anyhow::Result<()> {
        self.run(|db, _| {
            let tx = db.transaction()?;
            ensure!(
                freeze::exists(&tx, "activation_control_state")?,
                "control storage is not initialized"
            );
            freeze::tables(&tx)?;
            let inspection = inspect(&tx)?;
            ensure!(!inspection.halted, "control journal halted for review");
            ensure!(inspection.frozen, "host is not frozen for maintenance");
            coordinated(&tx)?;
            ensure!(
                inspection
                    .minimum_profiles
                    .iter()
                    .all(|v| profiles.contains(v)),
                "profile floor cannot decrease"
            );
            if let Some(id) = request(&tx)?.and_then(|earlier| earlier.proposal) {
                let certified = certificate_of(&all(&tx)?, &id)?;
                ensure!(
                    inspection.aborted.contains(&id)
                        || certified.is_some_and(|c| !inspection.pending_certificates.contains(&c)),
                    "the earlier request is not resolved"
                );
            }
            tx.execute(
                "INSERT OR REPLACE INTO activation_control_request VALUES (1, ?, ?, ?, NULL, 0)",
                params![
                    serde_json::to_vec(profiles)?,
                    inventory.as_slice(),
                    backup.as_slice()
                ],
            )?;
            tx.commit()?;
            Ok(())
        })
    }

    /// Record the owner's request to abort. A request whose proposal was never
    /// signed is dropped. Refused once a certificate exists: the session then
    /// goes forward.
    pub fn control_request_abort(&self) -> anyhow::Result<()> {
        self.run(|db, _| {
            let tx = db.transaction()?;
            let request = request(&tx)?.context("no session was requested")?;
            inspect(&tx)?;
            match request.proposal {
                None => tx.execute("DELETE FROM activation_control_request", [])?,
                Some(id) => {
                    ensure!(
                        certificate_of(&all(&tx)?, &id)?.is_none(),
                        "a certificate exists for this proposal; install it"
                    );
                    tx.execute("UPDATE activation_control_request SET abort=1", [])?
                }
            };
            tx.commit()?;
            Ok(())
        })
    }

    pub fn control_request(&self) -> anyhow::Result<Option<Request>> {
        self.run(|db, _| request(db))
    }

    /// Coordinator only. Refused after any host withdrew from the proposal.
    pub fn control_certify(
        &self,
        id: Digest,
        identity: &crate::peer::Identity,
        expected: &Session,
    ) -> anyhow::Result<Signed> {
        self.run(|db, _| {
            let tx = db.transaction()?;
            let signed = certify(&tx, id, identity, expected)?;
            tx.commit()?;
            Ok(signed)
        })
    }

    /// Advance the recorded request by at most one signature and say what
    /// happened or what it waits for. `peers` holds what every other host
    /// showed in the current synchronization pass.
    pub fn control_drive(
        &self,
        identity: &crate::peer::Identity,
        peers: &BTreeMap<Key, Peer>,
    ) -> anyhow::Result<Progress> {
        match self.run(|db, _| drive(db, identity, peers))? {
            Next::Done(progress) => Ok(progress),
            Next::Withdraw(id, designated) => {
                let host = designated.coordinator.clone();
                self.control_withdraw(id, host, identity, &designated)?;
                Ok(Progress::Withdrew(id))
            }
            Next::Abort(id, designated) => {
                self.control_abort(id, identity, &designated)?;
                Ok(Progress::Aborted(id))
            }
        }
    }
}
