//! Withdrawals and the signed abort of a proposal that has no certificate.
use super::journal::{
    all, array, get, inspect, local_host, put, save_floor, scope, session, signer_matches, state,
    verified_proposal,
};
use super::*;
use anyhow::Context as _;
use rusqlite::{Connection, params};
use std::collections::BTreeMap;

/// Proposals this host withdrew from, each bound to its signed statement.
pub(super) fn withdrawals(
    db: &Connection,
    records: &BTreeMap<Digest, Signed>,
) -> anyhow::Result<BTreeSet<Digest>> {
    let mut found = BTreeSet::new();
    if !freeze::exists(db, "activation_control_withdrawals")? {
        return Ok(found);
    }
    let mut statement =
        db.prepare("SELECT proposal, statement FROM activation_control_withdrawals")?;
    let rows = statement.query_map([], |r| {
        Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, Vec<u8>>(1)?))
    })?;
    for row in rows {
        let (id, statement) = row?;
        let id: Digest = array(id)?;
        let statement: Digest = array(statement)?;
        let Some(Body::Withdrawn(w)) = records.get(&statement).map(|s| &s.body) else {
            anyhow::bail!("missing withdrawal statement")
        };
        ensure!(w.proposal == id, "corrupt withdrawal binding");
        found.insert(id);
    }
    Ok(found)
}

fn certified(records: &BTreeMap<Digest, Signed>, id: &Digest) -> anyhow::Result<bool> {
    for signed in records.values() {
        if let Body::Certificate(c) = &signed.body
            && c.proposal.id()? == *id
        {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Proposals resolved by a signed abort.
pub(super) fn aborted(records: &BTreeMap<Digest, Signed>) -> BTreeSet<Digest> {
    records
        .values()
        .filter_map(|s| match &s.body {
            Body::Aborted(a) => Some(a.proposal),
            _ => None,
        })
        .collect()
}

/// Proposals any host is known to have withdrawn from.
pub(super) fn withdrawn(records: &BTreeMap<Digest, Signed>) -> BTreeSet<Digest> {
    records
        .values()
        .filter_map(|s| match &s.body {
            Body::Withdrawn(w) => Some(w.proposal),
            _ => None,
        })
        .collect()
}

/// A signature carries no time, so a withdrawal cannot reopen an installation
/// its host acknowledged or an earlier epoch. A released head has every
/// acknowledgment. Otherwise one host could halt every journal with a
/// withdrawal signed after the fact.
pub(super) fn settled(
    db: &Connection,
    head: Option<Digest>,
    id: &Digest,
    host: &Host,
) -> anyhow::Result<bool> {
    let records = all(db)?;
    let mut cursor = head;
    while let Some(installed) = cursor {
        let c = certificate(
            records
                .get(&installed)
                .context("installed certificate missing")?,
        )?;
        if c.proposal.id()? == *id {
            let acknowledged = records.values().any(|s| {
                matches!(&s.body, Body::Installed(i)
                    if i.certificate == installed && i.host.key == host.key)
            });
            return Ok(Some(installed) != head || acknowledged);
        }
        cursor = proposal(&c.proposal)?.previous;
    }
    Ok(false)
}

/// A certificate cannot stand beside an abort of its proposal, or beside a
/// host's promise never to install it.
pub(super) fn contradicts(
    db: &Connection,
    candidate: &Signed,
    proposed: &Signed,
) -> anyhow::Result<bool> {
    let id = proposed.id()?;
    let records = all(db)?;
    match &candidate.body {
        Body::Certificate(_) => Ok(withdrawals(db, &records)?.contains(&id)
            || aborted(&records).contains(&id)
            || withdrawn(&records).contains(&id)),
        Body::Aborted(_) | Body::Withdrawn(_) => certified(&records, &id),
        _ => Ok(false),
    }
}

/// The profile floor comes from installed certificates and unresolved prepare
/// locks, so an abort gives back what its proposal alone required.
pub(super) fn settle_floor(db: &Connection) -> anyhow::Result<()> {
    let records = all(db)?;
    let aborted = aborted(&records);
    let mut floor = BTreeSet::new();
    let mut cursor = state(db)?.head;
    while let Some(id) = cursor {
        let installed = records.get(&id).context("installed certificate missing")?;
        let p = proposal(&certificate(installed)?.proposal)?;
        floor.extend(p.profiles.iter().cloned());
        cursor = p.previous;
    }
    let mut statement =
        db.prepare("SELECT proposal, required_floor FROM activation_control_prepare")?;
    let rows = statement.query_map([], |r| {
        Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, Vec<u8>>(1)?))
    })?;
    for row in rows {
        let (id, required) = row?;
        if !aborted.contains(&array::<32>(id)?) {
            floor.extend(serde_json::from_slice::<BTreeSet<String>>(&required)?);
        }
    }
    save_floor(db, &floor)
}

impl crate::shared_audio::Store {
    /// Durably promise never to prepare, store or install a certificate for the
    /// proposal. Refused once this host holds such a certificate.
    pub fn control_withdraw(
        &self,
        id: Digest,
        host: Host,
        identity: &crate::peer::Identity,
        expected: &Session,
    ) -> anyhow::Result<Signed> {
        signer_matches(identity, &host)?;
        // Signing is deterministic, so a retry stores the same envelope.
        let signed = Signed::sign(
            Body::Withdrawn(Withdrawn {
                proposal: id,
                host: host.clone(),
            }),
            identity,
        )?;
        self.run(|db, _| {
            let tx = db.transaction()?;
            freeze::tables(&tx)?;
            let inspection = inspect(&tx)?;
            ensure!(!inspection.halted, "control journal halted for review");
            let proposed = get(&tx, &id)?;
            verified_proposal(&tx, &proposed)?;
            let p = proposal(&proposed)?;
            scope(&state(&tx)?, p)?;
            session(p, expected)?;
            local_host(&tx, p, &host)?;
            ensure!(
                !certified(&all(&tx)?, &id)?,
                "a certificate exists for this proposal; install it"
            );
            if !inspection.withdrawn.contains(&id) {
                put(&tx, &signed)?;
                tx.execute(
                    "INSERT INTO activation_control_withdrawals VALUES (?, ?)",
                    params![id.as_slice(), signed.id()?.as_slice()],
                )?;
                tx.commit()?;
            }
            Ok(())
        })?;
        Ok(signed)
    }

    /// Coordinator only. Signs the abort once a withdrawal from every host of
    /// the proposal, its own included, is stored here.
    pub fn control_abort(
        &self,
        id: Digest,
        identity: &crate::peer::Identity,
        expected: &Session,
    ) -> anyhow::Result<Signed> {
        self.run(|db, _| {
            let tx = db.transaction()?;
            let inspection = inspect(&tx)?;
            ensure!(!inspection.halted, "control journal halted for review");
            let proposed = get(&tx, &id)?;
            verified_proposal(&tx, &proposed)?;
            let p = proposal(&proposed)?;
            scope(&state(&tx)?, p)?;
            session(p, expected)?;
            signer_matches(identity, &p.coordinator)?;
            ensure!(
                inspection.withdrawn.contains(&id),
                "the coordinator has not withdrawn"
            );
            let records = all(&tx)?;
            ensure!(
                !certified(&records, &id)?,
                "a certificate exists for this proposal; install it"
            );
            let mut withdrawn = BTreeMap::new();
            for signed in records.into_values() {
                let key = match &signed.body {
                    Body::Withdrawn(w) if w.proposal == id => w.host.key,
                    _ => continue,
                };
                withdrawn.entry(key).or_insert(signed);
            }
            let signed = Signed::sign(
                Body::Aborted(Aborted {
                    proposal: id,
                    withdrawn: withdrawn.into_values().collect(),
                    coordinator: p.coordinator.clone(),
                }),
                identity,
            )?;
            // Fails while any host of the proposal has not withdrawn.
            verify_aborted(&signed, &proposed)?;
            put(&tx, &signed)?;
            settle_floor(&tx)?;
            inspect(&tx)?;
            tx.commit()?;
            Ok(signed)
        })
    }
}
