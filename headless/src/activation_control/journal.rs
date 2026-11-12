use super::*;
use anyhow::Context as _;
use rusqlite::{Connection, OptionalExtension as _, params};
use std::collections::BTreeMap;

#[derive(Clone, Debug)]
pub struct Session {
    pub coordinator: Host,
    pub nonce: Digest,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Stored,
    Duplicate,
    ReviewRequired,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Inspection {
    pub epoch: u64,
    pub head: Option<Digest>,
    pub minimum_profiles: BTreeSet<String>,
    pub prepare_locks: Vec<Digest>,
    pub pending_certificates: Vec<Digest>,
    pub unsigned_preparations: Vec<Digest>,
    pub all_installations_recorded: bool,
    pub halted: bool,
}

#[derive(Debug)]
struct State {
    cluster: [u8; 16],
    root: Key,
    baseline: Digest,
    epoch: u64,
    head: Option<Digest>,
    floor: BTreeSet<String>,
    halted: bool,
}

fn array<const N: usize>(bytes: Vec<u8>) -> anyhow::Result<[u8; N]> {
    bytes
        .try_into()
        .map_err(|_| anyhow::anyhow!("corrupt control state width"))
}

fn state(db: &Connection) -> anyhow::Result<State> {
    let (cluster, root, baseline, epoch, head, floor, halted) = db.query_row(
        "SELECT cluster, root, baseline, epoch, head, floor, halted FROM activation_control_state WHERE singleton=1",
        [],
        |r| {
            Ok((
                r.get::<_, Vec<u8>>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, Vec<u8>>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, Option<Vec<u8>>>(4)?,
                r.get::<_, Vec<u8>>(5)?,
                r.get::<_, i64>(6)?,
            ))
        },
    )?;
    ensure!(
        epoch >= 0 && matches!(halted, 0 | 1),
        "corrupt control epoch/halt"
    );
    Ok(State {
        cluster: array(cluster)?,
        root: array(root)?,
        baseline: array(baseline)?,
        epoch: epoch as u64,
        head: head.map(array).transpose()?,
        floor: serde_json::from_slice(&floor)?,
        halted: halted == 1,
    })
}

fn save_floor(db: &Connection, floor: &BTreeSet<String>) -> anyhow::Result<()> {
    db.execute(
        "UPDATE activation_control_state SET floor=? WHERE singleton=1",
        [serde_json::to_vec(floor)?],
    )?;
    Ok(())
}

fn put(db: &Connection, signed: &Signed) -> anyhow::Result<()> {
    db.execute(
        "INSERT OR IGNORE INTO activation_control_envelopes VALUES (?, ?, ?)",
        params![
            signed.id()?.as_slice(),
            signed.body.kind(),
            signed.canonical()?
        ],
    )?;
    Ok(())
}

fn get(db: &Connection, id: &Digest) -> anyhow::Result<Signed> {
    let raw: Vec<u8> = db.query_row(
        "SELECT canonical FROM activation_control_envelopes WHERE digest=?",
        [id.as_slice()],
        |r| r.get(0),
    )?;
    let signed = Signed::decode(&raw)?;
    ensure!(signed.id()? == *id, "control envelope identity mismatch");
    Ok(signed)
}

fn all(db: &Connection) -> anyhow::Result<BTreeMap<Digest, Signed>> {
    let mut statement = db.prepare(
        "SELECT digest, kind, canonical FROM activation_control_envelopes ORDER BY digest",
    )?;
    let rows = statement.query_map([], |r| {
        Ok((
            r.get::<_, Vec<u8>>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, Vec<u8>>(2)?,
        ))
    })?;
    rows.map(|row| {
        let (id, kind, raw) = row?;
        let id = array(id)?;
        let signed = Signed::decode(&raw)?;
        ensure!(
            signed.id()? == id && kind == signed.body.kind(),
            "corrupt control envelope index"
        );
        Ok((id, signed))
    })
    .collect()
}

fn proof(
    db: &Connection,
    revision: &Digest,
    cluster: [u8; 16],
) -> anyhow::Result<crate::enrollment::Proof> {
    let bytes: Vec<u8> = db.query_row(
        "SELECT canonical FROM activation_control_membership WHERE revision=?",
        [revision.as_slice()],
        |r| r.get(0),
    )?;
    ensure!(bytes.len() <= MAX_BYTES, "membership evidence too large");
    let proof: crate::enrollment::Proof = serde_json::from_slice(&bytes)?;
    ensure!(
        membership_revision(cluster, &proof)?.0 == *revision,
        "corrupt membership snapshot"
    );
    Ok(proof)
}

fn save_proof(
    db: &Connection,
    p: &Proposal,
    proof: &crate::enrollment::Proof,
) -> anyhow::Result<()> {
    let mut canonical = proof.clone();
    canonical.grants.sort_by(|a, b| a.id.cmp(&b.id));
    canonical.revocations.sort_by(|a, b| a.id.cmp(&b.id));
    let bytes = serde_json::to_vec(&canonical)?;
    ensure!(bytes.len() <= MAX_BYTES, "membership evidence too large");
    db.execute(
        "INSERT OR IGNORE INTO activation_control_membership VALUES (?, ?)",
        params![p.membership.as_slice(), bytes],
    )?;
    Ok(())
}

fn scope(s: &State, p: &Proposal) -> anyhow::Result<()> {
    ensure!(
        s.cluster == p.cluster && s.root == p.root && s.baseline == p.baseline,
        "wrong control cluster/root/baseline"
    );
    Ok(())
}

fn session(p: &Proposal, expected: &Session) -> anyhow::Result<()> {
    ensure!(
        p.coordinator == expected.coordinator && p.nonce == expected.nonce,
        "wrong designated coordinator/session"
    );
    Ok(())
}

fn current_membership(db: &Connection, p: &Proposal) -> anyhow::Result<()> {
    let baseline: String = db.query_row(
        "SELECT fingerprint FROM shared_baseline WHERE singleton=1",
        [],
        |r| r.get(0),
    )?;
    ensure!(digest(&baseline)? == p.baseline, "local baseline changed");
    let current = crate::enrollment::read_proof(db)?;
    ensure!(
        membership_revision(p.cluster, &current)?.0 == p.membership,
        "membership changed; retain preparation lock"
    );
    Ok(())
}

fn local_host(db: &Connection, p: &Proposal, host: &Host) -> anyhow::Result<()> {
    let grant: String = db.query_row(
        "SELECT local_grant FROM cluster_trust WHERE singleton=1",
        [],
        |r| r.get(0),
    )?;
    ensure!(
        digest(&grant)? == host.grant && p.hosts.contains(host),
        "wrong local host/grant"
    );
    Ok(())
}

fn supports(
    p: &Proposal,
    floor: &BTreeSet<String>,
    implemented: &BTreeSet<String>,
) -> anyhow::Result<()> {
    ensure!(
        p.profiles
            .iter()
            .chain(floor)
            .all(|v| implemented.contains(v)),
        "unsupported required profile"
    );
    Ok(())
}

fn extends(s: &State, p: &Proposal) -> anyhow::Result<()> {
    ensure!(
        s.head == p.previous && s.epoch.checked_add(1) == Some(p.epoch),
        "stale or skipped control epoch/head"
    );
    ensure!(
        s.floor.iter().all(|v| p.profiles.contains(v)),
        "profile floor cannot decrease"
    );
    Ok(())
}

fn verified_proposal(db: &Connection, signed: &Signed) -> anyhow::Result<()> {
    let p = proposal(signed)?;
    verify_proposal(signed, &proof(db, &p.membership, p.cluster)?)
}

/// Return true for observed siblings, including a rival discovered after install.
fn conflicts(db: &Connection, candidate: &Signed, proposed: &Signed) -> anyhow::Result<bool> {
    let p = proposal(proposed)?;
    for signed in all(db)?.values() {
        if let Body::Proposal(other) = &signed.body
            && other.previous == p.previous
            && other.epoch == p.epoch
            && signed.id()? != proposed.id()?
        {
            return Ok(true);
        }
        if let (Body::Certificate(a), Body::Certificate(b)) = (&signed.body, &candidate.body) {
            let pa = proposal(&a.proposal)?;
            let pb = proposal(&b.proposal)?;
            if pa.previous == pb.previous
                && pa.epoch == pb.epoch
                && signed.id()? != candidate.id()?
            {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

/// The supplied proof only shows the signer was authorized at some revision,
/// so a revoked host could replay a stale proof to halt the journal. Refuse
/// signers this host already knows to be revoked or disputed. A grant this
/// host has not seen yet still halts, so a genuine rival is never missed.
fn revoked_locally(db: &Connection, host: &Host) -> anyhow::Result<bool> {
    let local = crate::enrollment::read_proof(db)?;
    let grant = hex::encode(host.grant);
    if local.grants.iter().any(|g| g.id == grant) && local.verify(&grant).is_err() {
        return Ok(true);
    }
    let member = iroh::EndpointId::from_bytes(&host.key)?.to_string();
    let (active, disputed) = local.revocation_state()?;
    Ok(disputed.contains(&member)
        || active
            .iter()
            .any(|&i| local.revocations[i].member == member))
}

/// Signing happens after the durable lock or install commits, so a signer
/// that cannot sign for `host` must be refused before anything is written.
fn signer_matches(identity: &crate::peer::Identity, host: &Host) -> anyhow::Result<()> {
    ensure!(
        identity.id().as_bytes() == &host.key,
        "signing identity does not match the asserted host"
    );
    Ok(())
}

fn mark_conflict(db: &Connection, candidate: &Signed) -> anyhow::Result<()> {
    db.execute(
        "INSERT OR IGNORE INTO activation_control_conflicts VALUES (?, ?, ?)",
        params![
            candidate.id()?.as_slice(),
            candidate.canonical()?,
            "observed sibling or competing coordinator"
        ],
    )?;
    db.execute(
        "UPDATE activation_control_state SET halted=1 WHERE singleton=1",
        [],
    )?;
    Ok(())
}

impl crate::shared_audio::Store {
    /// Explicitly initialize local evidence storage. Ordinary Store::open is unchanged.
    pub fn control_initialize(&self) -> anyhow::Result<()> {
        self.run(|db, _| {
            let tx = db.transaction()?;
            let proof = crate::enrollment::read_proof(&tx)?;
            let grant = proof.grants.first().context("missing cluster authority")?;
            let cluster = *uuid::Uuid::parse_str(&grant.cluster)?.as_bytes();
            membership_revision(cluster, &proof)?;
            let baseline: String = tx.query_row("SELECT fingerprint FROM shared_baseline WHERE singleton=1", [], |r| r.get(0))?;
            let baseline = digest(&baseline)?;
            tx.execute_batch("CREATE TABLE IF NOT EXISTS activation_control_envelopes (digest BLOB PRIMARY KEY, kind TEXT NOT NULL, canonical BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS activation_control_membership (revision BLOB PRIMARY KEY, canonical BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS activation_control_state (singleton INTEGER PRIMARY KEY CHECK(singleton=1), cluster BLOB NOT NULL, root BLOB NOT NULL, baseline BLOB NOT NULL, epoch INTEGER NOT NULL, head BLOB, floor BLOB NOT NULL, halted INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS activation_control_prepare (proposal BLOB PRIMARY KEY, host BLOB NOT NULL, required_floor BLOB NOT NULL, acknowledgment_digest BLOB);
                CREATE TABLE IF NOT EXISTS activation_control_conflicts (digest BLOB PRIMARY KEY, canonical BLOB NOT NULL, reason TEXT NOT NULL);")?;
            tx.execute("INSERT OR IGNORE INTO activation_control_state VALUES (1, ?, ?, ?, 0, NULL, ?, 0)", params![cluster.as_slice(), key(&proof.root)?.as_slice(), baseline.as_slice(), b"[]".as_slice()])?;
            let s = state(&tx)?;
            ensure!(s.cluster == cluster && s.root == key(&proof.root)? && s.baseline == baseline, "control storage scope changed");
            inspect(&tx)?;
            tx.commit()?;
            Ok(())
        })
    }

    /// Record supplied signed evidence; never sends it or enables a profile.
    pub fn control_record(
        &self,
        signed: &Signed,
        membership: &crate::enrollment::Proof,
        expected: &Session,
    ) -> anyhow::Result<Outcome> {
        self.run(|db, _| {
            let tx = db.transaction()?;
            inspect(&tx)?;
            let s = state(&tx)?;
            signed.verify()?;
            let id = signed.id()?;
            if all(&tx)?.contains_key(&id) {
                return Ok(Outcome::Duplicate);
            }
            ensure!(!s.halted, "control journal halted for review");
            let proposed = match &signed.body {
                Body::Proposal(_) => signed.clone(),
                Body::Certificate(c) => {
                    verify_certificate(signed, membership)?;
                    *c.proposal.clone()
                }
                Body::Prepared(a) => {
                    let p = get(&tx, &a.proposal)?;
                    verified_proposal(&tx, &p)?;
                    verify_prepared(signed, &p)?;
                    p
                }
                Body::Installed(i) => {
                    let stored = get(&tx, &i.certificate)?;
                    let c = certificate(&stored)?;
                    let p = proposal(&c.proposal)?;
                    ensure!(
                        i.epoch == p.epoch && p.hosts.contains(&i.host),
                        "installation acknowledgment mismatch"
                    );
                    c.proposal.as_ref().clone()
                }
            };
            let p = proposal(&proposed)?;
            if matches!(signed.body, Body::Proposal(_) | Body::Certificate(_)) {
                verify_proposal(&proposed, membership)?;
            }
            scope(&s, p)?;
            if matches!(signed.body, Body::Proposal(_) | Body::Certificate(_))
                && conflicts(&tx, signed, &proposed)?
            {
                ensure!(
                    !revoked_locally(&tx, signed.body.signer())?,
                    "sibling signer is revoked or disputed locally"
                );
                save_proof(&tx, p, membership)?;
                mark_conflict(&tx, signed)?;
                tx.commit()?;
                return Ok(Outcome::ReviewRequired);
            }
            session(p, expected)?;
            if !matches!(signed.body, Body::Installed(_)) {
                current_membership(&tx, p)?;
                extends(&s, p)?;
            } else {
                ensure!(
                    s.head
                        == match &signed.body {
                            Body::Installed(i) => Some(i.certificate),
                            _ => None,
                        }
                        && s.epoch == p.epoch,
                    "installation acknowledgment is not for current head"
                );
            }
            if matches!(signed.body, Body::Proposal(_) | Body::Certificate(_)) {
                save_proof(&tx, p, membership)?;
            }
            if let Body::Certificate(c) = &signed.body {
                put(&tx, &c.proposal)?;
                for ack in &c.prepared {
                    put(&tx, ack)?;
                }
            }
            put(&tx, signed)?;
            tx.commit()?;
            Ok(Outcome::Stored)
        })
    }

    /// The caller supplies verified freeze assertions. This API does not freeze writers.
    pub fn control_prepare(
        &self,
        ack: Prepared,
        identity: &crate::peer::Identity,
        expected: &Session,
        supported: &BTreeSet<String>,
    ) -> anyhow::Result<Signed> {
        signer_matches(identity, &ack.host)?;
        self.run(|db, _| lock_prepare(db, &ack, expected, supported))?;
        let signed = Signed::sign(Body::Prepared(ack), identity)?;
        self.run(|db, _| finish_prepare(db, &signed, expected))?;
        Ok(signed)
    }

    /// Install the exact stored certificate, then durably acknowledge that commit.
    pub fn control_install(
        &self,
        id: Digest,
        host: Host,
        identity: &crate::peer::Identity,
        expected: &Session,
        supported: &BTreeSet<String>,
    ) -> anyhow::Result<Signed> {
        signer_matches(identity, &host)?;
        let epoch = self.run(|db, _| install(db, &id, &host, expected, supported))?;
        let signed = Signed::sign(
            Body::Installed(Installed {
                certificate: id,
                host,
                epoch,
            }),
            identity,
        )?;
        self.run(|db, _| {
            let tx = db.transaction()?;
            inspect(&tx)?;
            let s = state(&tx)?;
            ensure!(
                !s.halted && s.head == Some(id) && s.epoch == epoch,
                "installed head changed before acknowledgment"
            );
            put(&tx, &signed)?;
            tx.commit()?;
            Ok(())
        })?;
        Ok(signed)
    }

    /// Corruption is an error requiring review; committed locks are never discarded.
    pub fn control_inspect(&self) -> anyhow::Result<Inspection> {
        self.run(|db, _| inspect(db))
    }
}

pub(super) fn lock_prepare(
    db: &mut Connection,
    ack: &Prepared,
    expected: &Session,
    supported: &BTreeSet<String>,
) -> anyhow::Result<()> {
    let tx = db.transaction()?;
    inspect(&tx)?;
    let mut s = state(&tx)?;
    ensure!(!s.halted, "control journal halted for review");
    let signed = get(&tx, &ack.proposal)?;
    verified_proposal(&tx, &signed)?;
    let p = proposal(&signed)?;
    scope(&s, p)?;
    session(p, expected)?;
    current_membership(&tx, p)?;
    local_host(&tx, p, &ack.host)?;
    supports(p, &s.floor, supported)?;
    extends(&s, p)?;
    ensure!(
        ack.write_frozen
            && ack.admission_frozen
            && ack.baseline == p.baseline
            && !ack.implementations.is_empty(),
        "invalid local freeze/baseline assertions"
    );
    // Canonical validation happens before committing even an unsigned lock.
    Body::Prepared(ack.clone()).signing_bytes()?;
    ensure!(
        ack.minimum_profiles == p.profiles
            && p.profiles
                .iter()
                .chain(s.floor.iter())
                .all(|v| ack.implemented_profiles.contains(v) && supported.contains(v)),
        "local profile floor unsupported"
    );
    let existing: Option<Vec<u8>> = tx
        .query_row(
            "SELECT required_floor FROM activation_control_prepare WHERE proposal=?",
            [ack.proposal.as_slice()],
            |r| r.get(0),
        )
        .optional()?;
    let floor: BTreeSet<_> = ack.minimum_profiles.iter().cloned().collect();
    if let Some(existing) = existing {
        ensure!(
            serde_json::from_slice::<BTreeSet<String>>(&existing)? == floor,
            "preparation floor changed"
        );
    }
    tx.execute(
        "INSERT OR IGNORE INTO activation_control_prepare VALUES (?, ?, ?, NULL)",
        params![
            ack.proposal.as_slice(),
            ack.host.key.as_slice(),
            serde_json::to_vec(&floor)?
        ],
    )?;
    s.floor.extend(floor);
    save_floor(&tx, &s.floor)?;
    tx.commit()?;
    Ok(())
}

pub(super) fn finish_prepare(
    db: &mut Connection,
    signed: &Signed,
    expected: &Session,
) -> anyhow::Result<()> {
    let tx = db.transaction()?;
    inspect(&tx)?;
    let s = state(&tx)?;
    ensure!(!s.halted, "control journal halted for review");
    let Body::Prepared(ack) = &signed.body else {
        anyhow::bail!("expected prepared acknowledgment")
    };
    let proposed = get(&tx, &ack.proposal)?;
    let p = proposal(&proposed)?;
    verify_prepared(signed, &proposed)?;
    session(p, expected)?;
    current_membership(&tx, p)?;
    extends(&s, p)?;
    let (floor, prior): (Vec<u8>, Option<Vec<u8>>) = tx.query_row("SELECT required_floor, acknowledgment_digest FROM activation_control_prepare WHERE proposal=? AND host=?", params![ack.proposal.as_slice(), ack.host.key.as_slice()], |r| Ok((r.get(0)?, r.get(1)?)))?;
    ensure!(
        serde_json::from_slice::<BTreeSet<String>>(&floor)?
            == ack.minimum_profiles.iter().cloned().collect(),
        "prepared lock floor mismatch"
    );
    let id = signed.id()?;
    ensure!(
        prior.is_none_or(|bytes| bytes == id),
        "cannot replace durable preparation acknowledgment"
    );
    put(&tx, signed)?;
    tx.execute(
        "UPDATE activation_control_prepare SET acknowledgment_digest=? WHERE proposal=?",
        params![id.as_slice(), ack.proposal.as_slice()],
    )?;
    tx.commit()?;
    Ok(())
}

pub(super) fn install(
    db: &mut Connection,
    id: &Digest,
    host: &Host,
    expected: &Session,
    supported: &BTreeSet<String>,
) -> anyhow::Result<u64> {
    let tx = db.transaction()?;
    inspect(&tx)?;
    let mut s = state(&tx)?;
    ensure!(!s.halted, "control journal halted for review");
    let signed = get(&tx, id)?;
    let c = certificate(&signed)?;
    let p = proposal(&c.proposal)?;
    verify_certificate(&signed, &proof(&tx, &p.membership, p.cluster)?)?;
    scope(&s, p)?;
    session(p, expected)?;
    current_membership(&tx, p)?;
    local_host(&tx, p, host)?;
    supports(p, &s.floor, supported)?;
    if s.head != Some(*id) {
        extends(&s, p)?;
        s.floor.extend(p.profiles.iter().cloned());
        tx.execute(
            "UPDATE activation_control_state SET epoch=?, head=? WHERE singleton=1",
            params![p.epoch as i64, id.as_slice()],
        )?;
        save_floor(&tx, &s.floor)?;
    }
    tx.commit()?;
    Ok(p.epoch)
}

fn inspect(db: &Connection) -> anyhow::Result<Inspection> {
    let s = state(db)?;
    let records = all(db)?;
    let mut siblings = BTreeMap::new();
    let mut certificates = BTreeMap::new();
    let mut certificate_children = BTreeMap::new();
    for (id, signed) in &records {
        match &signed.body {
            Body::Proposal(p) => {
                scope(&s, p)?;
                verified_proposal(db, signed)?;
                ensure!(
                    siblings.insert((p.previous, p.epoch), *id).is_none(),
                    "unrecorded proposal fork; review required"
                );
            }
            Body::Prepared(a) => verify_prepared(
                signed,
                records
                    .get(&a.proposal)
                    .context("missing proposal evidence")?,
            )?,
            Body::Certificate(c) => {
                let p = proposal(&c.proposal)?;
                scope(&s, p)?;
                verify_certificate(signed, &proof(db, &p.membership, p.cluster)?)?;
                ensure!(
                    records.get(&c.proposal.id()?) == Some(c.proposal.as_ref()),
                    "missing nested proposal evidence"
                );
                for ack in &c.prepared {
                    ensure!(
                        records.get(&ack.id()?) == Some(ack),
                        "missing nested prepared evidence"
                    );
                }
                ensure!(
                    certificate_children
                        .insert((p.previous, p.epoch), *id)
                        .is_none(),
                    "unrecorded certificate fork; review required"
                );
                certificates.insert(*id, p);
            }
            Body::Installed(i) => {
                let c = certificate(
                    records
                        .get(&i.certificate)
                        .context("missing certificate evidence")?,
                )?;
                let p = proposal(&c.proposal)?;
                ensure!(
                    p.epoch == i.epoch && p.hosts.contains(&i.host),
                    "corrupt installation acknowledgment"
                );
            }
        }
    }
    for p in certificates
        .values()
        .copied()
        .chain(records.values().filter_map(|v| {
            if let Body::Proposal(p) = &v.body {
                Some(p.as_ref())
            } else {
                None
            }
        }))
    {
        match p.previous {
            None => ensure!(p.epoch == 1, "invalid genesis epoch"),
            Some(id) => {
                let previous = certificates
                    .get(&id)
                    .context("missing previous certificate")?;
                ensure!(
                    previous.epoch.checked_add(1) == Some(p.epoch)
                        && previous.profiles.iter().all(|v| p.profiles.contains(v)),
                    "invalid certificate ancestry/floor"
                );
            }
        }
    }
    let mut installed = BTreeSet::new();
    let mut expected_floor = BTreeSet::new();
    let mut cursor = s.head;
    let mut epoch = s.epoch;
    while let Some(id) = cursor {
        ensure!(installed.insert(id), "cyclic control ancestry");
        let p = certificates
            .get(&id)
            .context("installed certificate missing")?;
        ensure!(p.epoch == epoch, "corrupt installed epoch");
        expected_floor.extend(p.profiles.iter().cloned());
        cursor = p.previous;
        epoch = epoch.checked_sub(1).context("epoch underflow")?;
    }
    ensure!(epoch == 0, "corrupt installed head");
    // Installation acknowledgments are only stored for the current head, so
    // one outside the installed ancestry means the head was rolled back.
    for signed in records.values() {
        if let Body::Installed(i) = &signed.body {
            ensure!(
                installed.contains(&i.certificate),
                "installation acknowledgment outside installed ancestry"
            );
        }
    }
    let mut prepare_locks = Vec::new();
    let mut unsigned_preparations = Vec::new();
    let mut statement = db.prepare("SELECT proposal, host, required_floor, acknowledgment_digest FROM activation_control_prepare ORDER BY proposal")?;
    let rows = statement.query_map([], |r| {
        Ok((
            r.get::<_, Vec<u8>>(0)?,
            r.get::<_, Vec<u8>>(1)?,
            r.get::<_, Vec<u8>>(2)?,
            r.get::<_, Option<Vec<u8>>>(3)?,
        ))
    })?;
    for row in rows {
        let (id, host, floor, ack) = row?;
        let id = array(id)?;
        let p = proposal(records.get(&id).context("missing locked proposal")?)?;
        let floor: BTreeSet<String> = serde_json::from_slice(&floor)?;
        ensure!(
            p.hosts.iter().any(|h| h.key.as_slice() == host)
                && p.profiles.iter().all(|v| floor.contains(v)),
            "corrupt prepare lock"
        );
        expected_floor.extend(floor.iter().cloned());
        if let Some(ack) = ack {
            let ack: Digest = array(ack)?;
            let Body::Prepared(a) = &records
                .get(&ack)
                .context("missing locked acknowledgment")?
                .body
            else {
                anyhow::bail!("wrong lock acknowledgment kind")
            };
            ensure!(
                a.proposal == id
                    && a.host.key.as_slice() == host
                    && a.minimum_profiles.iter().cloned().collect::<BTreeSet<_>>() == floor,
                "corrupt lock acknowledgment binding"
            );
        } else {
            unsigned_preparations.push(id);
        }
        prepare_locks.push(id);
    }
    ensure!(expected_floor == s.floor, "corrupt durable profile floor");
    let mut conflicts_found = false;
    let mut statement = db.prepare("SELECT digest, canonical FROM activation_control_conflicts")?;
    let rows = statement.query_map([], |r| {
        Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, Vec<u8>>(1)?))
    })?;
    for row in rows {
        let (id, raw) = row?;
        let signed = Signed::decode(&raw)?;
        ensure!(signed.id()?.as_slice() == id, "corrupt conflict identity");
        let proposed = match &signed.body {
            Body::Proposal(_) => &signed,
            Body::Certificate(c) => {
                let p = proposal(&c.proposal)?;
                verify_certificate(&signed, &proof(db, &p.membership, p.cluster)?)?;
                &c.proposal
            }
            _ => anyhow::bail!("invalid conflict kind"),
        };
        verified_proposal(db, proposed)?;
        scope(&s, proposal(proposed)?)?;
        ensure!(
            conflicts(db, &signed, proposed)?,
            "conflict lacks sibling evidence"
        );
        conflicts_found = true;
    }
    ensure!(s.halted == conflicts_found, "corrupt review halt marker");
    let expected_hosts: BTreeSet<_> = s
        .head
        .and_then(|id| certificates.get(&id))
        .map(|p| p.hosts.iter().map(|h| h.key).collect())
        .unwrap_or_default();
    let actual_hosts: BTreeSet<_> = records
        .values()
        .filter_map(|v| match &v.body {
            Body::Installed(i) if Some(i.certificate) == s.head => Some(i.host.key),
            _ => None,
        })
        .collect();
    Ok(Inspection {
        epoch: s.epoch,
        head: s.head,
        minimum_profiles: s.floor,
        prepare_locks,
        pending_certificates: certificates
            .keys()
            .filter(|id| !installed.contains(*id))
            .copied()
            .collect(),
        unsigned_preparations,
        all_installations_recorded: !expected_hosts.is_empty() && expected_hosts == actual_hosts,
        halted: s.halted,
    })
}
