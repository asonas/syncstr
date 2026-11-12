use super::*;
use rusqlite::{Connection, params};
use serde_json::Value;

fn vectors() -> Value {
    serde_json::from_str(include_str!(
        "../../fixtures/activation-control/vectors.json"
    ))
    .unwrap()
}

fn vector(name: &str) -> Signed {
    Signed::decode(&hex::decode(vectors()[name]["canonical"].as_str().unwrap()).unwrap()).unwrap()
}

fn member_proof() -> crate::enrollment::Proof {
    serde_json::from_value(vectors()["proof"].clone()).unwrap()
}

fn supported() -> BTreeSet<String> {
    ["registration-equivalence-v1".into()].into()
}

fn session() -> Session {
    Session {
        coordinator: proposal(&vector("proposal")).unwrap().coordinator.clone(),
        nonce: [0x66; 32],
    }
}

struct Fixture {
    directory: tempfile::TempDir,
    store: Option<crate::shared_audio::Store>,
}

impl Fixture {
    fn new() -> anyhow::Result<Self> {
        let directory = tempfile::tempdir()?;
        std::fs::write(directory.path().join("node.lock"), [])?;
        let db = Connection::open(directory.path().join("node.sqlite"))?;
        db.execute_batch("PRAGMA user_version=5;
            CREATE TABLE shared_baseline (singleton INTEGER PRIMARY KEY, fingerprint TEXT, payload BLOB);
            CREATE TABLE shared_records (id TEXT PRIMARY KEY, payload BLOB);
            CREATE TABLE shared_playlists (id TEXT PRIMARY KEY, payload BLOB);
            CREATE TABLE shared_objects (sha256 TEXT PRIMARY KEY, bytes INTEGER, locator TEXT);
            CREATE TABLE shared_requests (id TEXT PRIMARY KEY, digest TEXT, record TEXT);
            INSERT INTO shared_requests VALUES ('retained-request', 'retained-digest', 'retained-record');")?;
        crate::enrollment::migrate(&db)?;
        let proof = member_proof();
        let root_grant = proof.grants.iter().find(|g| g.authority.is_none()).unwrap();
        db.execute(
            "INSERT INTO cluster_trust VALUES (1, ?, ?)",
            params![proof.root, root_grant.id],
        )?;
        for grant in &proof.grants {
            db.execute(
                "INSERT INTO cluster_enrollment_grants VALUES (?, ?)",
                params![grant.id, serde_json::to_vec(grant)?],
            )?;
        }
        let baseline = crate::shared_audio::Baseline {
            cluster: "11111111-1111-4111-8111-111111111111".into(),
            library: "fixture-library".into(),
            legacy_organization: serde_json::json!({}),
            tracks: Default::default(),
            addresses: Default::default(),
            objects: Default::default(),
            pins: Default::default(),
            legacy_fingerprint: "fixture".into(),
        };
        db.execute(
            "INSERT INTO shared_baseline VALUES (1, ?, ?)",
            params![hex::encode([0x22; 32]), serde_json::to_vec(&baseline)?],
        )?;
        drop(db);
        let store = crate::shared_audio::Store::open(directory.path())?;
        store.control_initialize()?;
        Ok(Self {
            directory,
            store: Some(store),
        })
    }

    fn store(&self) -> &crate::shared_audio::Store {
        self.store.as_ref().unwrap()
    }

    fn identity(&self, seed: u8) -> anyhow::Result<crate::peer::Identity> {
        crate::peer::Identity::from_secret(
            &self.directory.path().join(format!("identity-{seed}")),
            [seed; 32],
        )
    }

    fn resign(&self, body: Body, seed: u8) -> anyhow::Result<Signed> {
        Signed::sign(body, &self.identity(seed)?)
    }

    fn record(&self, signed: &Signed) -> anyhow::Result<Outcome> {
        self.store()
            .control_record(signed, &member_proof(), &session())
    }

    fn prepare(&self) -> anyhow::Result<Signed> {
        let ack = root_prepared();
        self.store()
            .control_prepare(ack, &self.identity(7)?, &session(), &supported())
    }

    fn install(&self) -> anyhow::Result<Signed> {
        self.store().control_install(
            vector("certificate").id()?,
            session().coordinator,
            &self.identity(7)?,
            &session(),
            &supported(),
        )
    }

    fn reopen(&mut self) -> anyhow::Result<()> {
        self.store.take();
        self.store = Some(crate::shared_audio::Store::open(self.directory.path())?);
        Ok(())
    }

    fn sql(&self, sql: &str) -> anyhow::Result<()> {
        self.store().run(|db, _| {
            db.execute_batch(sql)?;
            Ok(())
        })
    }
}

fn root_prepared() -> Prepared {
    let p = vector("proposal");
    Prepared {
        proposal: p.id().unwrap(),
        host: session().coordinator,
        implementations: vec!["fixture-build-v1".into()],
        implemented_profiles: supported().into_iter().collect(),
        input_history: [0x33; 32],
        baseline: [0x22; 32],
        write_frozen: true,
        admission_frozen: true,
        minimum_profiles: supported().into_iter().collect(),
    }
}

fn assert_vector(signed: &Signed, expected: &Value) -> anyhow::Result<()> {
    assert_eq!(
        hex::encode(signed.body.signing_bytes()?),
        expected["signing"].as_str().unwrap()
    );
    assert_eq!(
        hex::encode(signed.signature),
        expected["signature"].as_str().unwrap()
    );
    assert_eq!(hex::encode(signed.id()?), expected["id"].as_str().unwrap());
    let canonical = hex::decode(expected["canonical"].as_str().unwrap())?;
    assert_eq!(signed.canonical()?, canonical);
    assert_eq!(Signed::decode(&canonical)?, *signed);
    Ok(())
}

#[test]
fn canonical_vectors() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    let proof = member_proof();
    let (revision, hosts) = membership_revision(
        [
            0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x41, 0x11, 0x81, 0x11, 0x11, 0x11, 0x11, 0x11,
            0x11, 0x11,
        ],
        &proof,
    )?;
    let p = Proposal {
        cluster: *uuid::Uuid::parse_str("11111111-1111-4111-8111-111111111111")?.as_bytes(),
        root: key(&proof.root)?,
        baseline: [0x22; 32],
        previous: None,
        epoch: 1,
        membership: revision,
        hosts,
        profiles: supported().into_iter().collect(),
        inventory: [0x44; 32],
        backup: [0x55; 32],
        coordinator: session().coordinator,
        nonce: [0x66; 32],
    };
    let proposed = f.resign(Body::Proposal(Box::new(p.clone())), 7)?;
    assert_vector(&proposed, &vectors()["proposal"])?;
    let mut acks = Vec::new();
    for seed in [7, 8, 9] {
        let identity = f.identity(seed)?;
        let host = p
            .hosts
            .iter()
            .find(|h| h.key == *identity.id().as_bytes())
            .unwrap()
            .clone();
        let mut ack = root_prepared();
        ack.host = host;
        acks.push(Signed::sign(Body::Prepared(ack), &identity)?);
    }
    acks.sort_by_key(|a| a.body.signer().key);
    for (signed, expected) in acks.iter().zip(vectors()["prepared"].as_array().unwrap()) {
        assert_vector(signed, expected)?;
    }
    let cert = f.resign(
        Body::Certificate(Certificate {
            proposal: Box::new(proposed),
            prepared: acks,
            coordinator: p.coordinator.clone(),
        }),
        7,
    )?;
    assert_vector(&cert, &vectors()["certificate"])?;
    let installed = f.resign(
        Body::Installed(Installed {
            certificate: cert.id()?,
            host: p.coordinator.clone(),
            epoch: 1,
        }),
        7,
    )?;
    assert_vector(&installed, &vectors()["installed"])?;
    let successor = f.resign(
        Body::Proposal(Box::new(Proposal {
            previous: Some(cert.id()?),
            epoch: 2,
            nonce: [0x77; 32],
            ..p
        })),
        7,
    )?;
    assert_vector(&successor, &vectors()["successor"])?;
    Ok(())
}

#[test]
fn membership_revision_vectors() -> anyhow::Result<()> {
    let p = vector("proposal");
    let p = proposal(&p)?;
    let mut proof = member_proof();
    let (revision, hosts) = membership_revision(p.cluster, &proof)?;
    assert_eq!(
        hex::encode(revision),
        vectors()["membership_revision"].as_str().unwrap()
    );
    let expected: Digest = Sha256::digest(hex::decode(
        vectors()["membership_signing"].as_str().unwrap(),
    )?)
    .into();
    assert_eq!(revision, expected);
    proof.grants.reverse();
    assert_eq!(membership_revision(p.cluster, &proof)?, (revision, hosts));
    proof.grants.push(proof.grants[0].clone());
    assert!(membership_revision(p.cluster, &proof).is_err());
    let mut proof = member_proof();
    proof.grants[0].host = false;
    assert!(membership_revision(p.cluster, &proof).is_err());
    Ok(())
}

#[test]
fn bounded_noncanonical_decode() -> anyhow::Result<()> {
    for name in ["proposal", "certificate", "installed", "successor"] {
        let bytes = vector(name).canonical()?;
        for length in [0, 1, 4, bytes.len() - 1] {
            assert!(Signed::decode(&bytes[..length]).is_err());
        }
        let mut trailing = bytes.clone();
        trailing.push(0);
        assert!(Signed::decode(&trailing).is_err());
        let mut oversized = bytes.clone();
        oversized[..4].copy_from_slice(&u32::MAX.to_be_bytes());
        assert!(Signed::decode(&oversized).is_err());
    }
    assert!(Signed::decode(&vec![0; MAX_BYTES + 1]).is_err());
    let mut p = proposal(&vector("proposal"))?.clone();
    p.hosts.reverse();
    assert!(Body::Proposal(Box::new(p)).signing_bytes().is_err());
    let mut a = root_prepared();
    a.minimum_profiles.push(a.minimum_profiles[0].clone());
    assert!(Body::Prepared(a).signing_bytes().is_err());
    let mut a = root_prepared();
    a.implementations = vec!["x".repeat(129)];
    assert!(Body::Prepared(a).signing_bytes().is_err());
    let mut a = root_prepared();
    a.implementations = vec!["non-ascii-\u{e9}".into()];
    assert!(Body::Prepared(a).signing_bytes().is_err());
    Ok(())
}

#[test]
fn tampered_envelopes() -> anyhow::Result<()> {
    for name in ["proposal", "certificate", "installed", "successor"] {
        let bytes = vector(name).canonical()?;
        // Cover each digest-sized signing region and every signature byte.
        for offset in (4..bytes.len())
            .step_by(32)
            .chain(bytes.len() - 64..bytes.len())
        {
            let mut tampered = bytes.clone();
            tampered[offset] ^= 1;
            assert!(Signed::decode(&tampered).is_err(), "{name} offset {offset}");
        }
    }
    for value in vectors()["prepared"].as_array().unwrap() {
        let mut bytes = hex::decode(value["canonical"].as_str().unwrap())?;
        let last = bytes.len() - 1;
        bytes[last] ^= 1;
        assert!(Signed::decode(&bytes).is_err());
    }
    Ok(())
}

#[test]
fn journal_replay_and_chain() -> anyhow::Result<()> {
    let mut f = Fixture::new()?;
    let p = vector("proposal");
    assert_eq!(f.record(&p)?, Outcome::Stored);
    assert_eq!(f.record(&p)?, Outcome::Duplicate);
    f.prepare()?;
    assert_eq!(f.record(&vector("certificate"))?, Outcome::Stored);
    assert!(!f.store().control_inspect()?.all_installations_recorded);
    assert_eq!(f.install()?, vector("installed"));
    assert_eq!(f.record(&vector("certificate"))?, Outcome::Duplicate);
    let Body::Certificate(c) = vector("certificate").body else {
        unreachable!()
    };
    let id = vector("certificate").id()?;
    for (seed, ack) in [7, 8, 9]
        .into_iter()
        .map(|s| Ok((s, f.identity(s)?)))
        .collect::<anyhow::Result<Vec<_>>>()?
    {
        let host = proposal(&c.proposal)?
            .hosts
            .iter()
            .find(|h| h.key == *ack.id().as_bytes())
            .unwrap()
            .clone();
        let installed = f.resign(
            Body::Installed(Installed {
                certificate: id,
                host,
                epoch: 1,
            }),
            seed,
        )?;
        f.record(&installed)?;
    }
    assert!(f.store().control_inspect()?.all_installations_recorded);
    let next = vector("successor");
    let expected = Session {
        coordinator: session().coordinator,
        nonce: [0x77; 32],
    };
    f.store()
        .control_record(&next, &member_proof(), &expected)?;
    let mut acks = Vec::new();
    for old in c.prepared {
        let Body::Prepared(mut a) = old.body else {
            unreachable!()
        };
        a.proposal = next.id()?;
        let seed = [7, 8, 9]
            .into_iter()
            .find(|s| *f.identity(*s).unwrap().id().as_bytes() == a.host.key)
            .unwrap();
        acks.push(f.resign(Body::Prepared(a), seed)?);
    }
    let next_certificate = f.resign(
        Body::Certificate(Certificate {
            proposal: Box::new(next),
            prepared: acks,
            coordinator: session().coordinator,
        }),
        7,
    )?;
    f.store()
        .control_record(&next_certificate, &member_proof(), &expected)?;
    f.store().control_install(
        next_certificate.id()?,
        session().coordinator,
        &f.identity(7)?,
        &expected,
        &supported(),
    )?;
    assert_eq!(f.store().control_inspect()?.epoch, 2);
    assert!(f.install().is_err());
    f.reopen()?;
    assert_eq!(f.store().control_inspect()?.epoch, 2);
    assert_eq!(f.record(&p)?, Outcome::Duplicate);
    Ok(())
}

#[test]
fn membership_and_baseline_mismatch() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    let p = proposal(&vector("proposal"))?.clone();
    for bad in [
        Proposal {
            baseline: [1; 32],
            ..p.clone()
        },
        Proposal {
            membership: [1; 32],
            ..p.clone()
        },
        Proposal {
            root: [1; 32],
            ..p.clone()
        },
        Proposal {
            cluster: [1; 16],
            ..p.clone()
        },
        Proposal {
            previous: Some([1; 32]),
            ..p.clone()
        },
        Proposal {
            epoch: 2,
            ..p.clone()
        },
        Proposal {
            epoch: u64::MAX,
            ..p.clone()
        },
        Proposal {
            nonce: [1; 32],
            ..p.clone()
        },
    ] {
        assert!(
            f.record(&f.resign(Body::Proposal(Box::new(bad)), 7)?)
                .is_err()
        );
    }
    assert_eq!(f.store().control_inspect()?.epoch, 0);
    f.record(&vector("proposal"))?;
    f.prepare()?;
    let before = f.store().control_inspect()?;
    f.sql(
        "DELETE FROM cluster_enrollment_grants WHERE id != (SELECT local_grant FROM cluster_trust)",
    )?;
    assert!(f.prepare().is_err());
    assert!(f.record(&vector("certificate")).is_err());
    assert_eq!(f.store().control_inspect()?, before);
    Ok(())
}

#[test]
fn certificate_requires_every_host() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    let c = certificate(&vector("certificate"))?.clone();
    let mut missing = c.clone();
    missing.prepared.pop();
    assert!(f.record(&f.resign(Body::Certificate(missing), 7)?).is_err());
    let mut divergent = c.clone();
    let Body::Prepared(mut a) = divergent.prepared[0].body.clone() else {
        unreachable!()
    };
    let seed = [7, 8, 9]
        .into_iter()
        .find(|s| *f.identity(*s).unwrap().id().as_bytes() == a.host.key)
        .unwrap();
    a.input_history = [1; 32];
    divergent.prepared[0] = f.resign(Body::Prepared(a), seed)?;
    assert!(
        f.record(&f.resign(Body::Certificate(divergent), 7)?)
            .is_err()
    );
    let mut bad = root_prepared();
    bad.write_frozen = false;
    assert!(verify_prepared(&f.resign(Body::Prepared(bad), 7)?, &vector("proposal")).is_err());
    let mut bad = root_prepared();
    bad.baseline = [1; 32];
    assert!(verify_prepared(&f.resign(Body::Prepared(bad), 7)?, &vector("proposal")).is_err());
    Ok(())
}

#[test]
fn profile_floor_never_decreases() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    assert!(
        f.store()
            .control_prepare(
                root_prepared(),
                &f.identity(7)?,
                &session(),
                &BTreeSet::new()
            )
            .is_err()
    );
    f.prepare()?;
    f.record(&vector("certificate"))?;
    assert!(
        f.store()
            .control_install(
                vector("certificate").id()?,
                session().coordinator,
                &f.identity(7)?,
                &session(),
                &BTreeSet::new()
            )
            .is_err()
    );
    f.install()?;
    let mut next = proposal(&vector("successor"))?.clone();
    next.profiles.clear();
    assert!(
        f.store()
            .control_record(
                &f.resign(Body::Proposal(Box::new(next)), 7)?,
                &member_proof(),
                &Session {
                    coordinator: session().coordinator,
                    nonce: [0x77; 32]
                }
            )
            .is_err()
    );
    assert_eq!(f.store().control_inspect()?.minimum_profiles, supported());
    Ok(())
}

#[test]
fn fork_and_competing_coordinators_halt() -> anyhow::Result<()> {
    for seed in [7, 9] {
        let mut f = Fixture::new()?;
        f.record(&vector("proposal"))?;
        let mut p = proposal(&vector("proposal"))?.clone();
        p.nonce = [0x99; 32];
        p.coordinator = p
            .hosts
            .iter()
            .find(|h| h.key == *f.identity(seed).unwrap().id().as_bytes())
            .unwrap()
            .clone();
        let rival = f.resign(Body::Proposal(Box::new(p)), seed)?;
        assert_eq!(f.record(&rival)?, Outcome::ReviewRequired);
        f.reopen()?;
        assert!(f.store().control_inspect()?.halted);
        assert!(f.prepare().is_err());
        assert!(f.record(&vector("certificate")).is_err());
        assert_eq!(f.store().control_inspect()?.epoch, 0);
    }
    Ok(())
}

#[test]
fn late_sibling_halts_installed_head() -> anyhow::Result<()> {
    let mut f = Fixture::new()?;
    f.record(&vector("certificate"))?;
    f.install()?;
    let head = f.store().control_inspect()?.head;
    let mut sibling = certificate(&vector("certificate"))?.clone();
    for a in &mut sibling.prepared {
        let Body::Prepared(mut body) = a.body.clone() else {
            unreachable!()
        };
        body.input_history = [0x88; 32];
        let seed = [7, 8, 9]
            .into_iter()
            .find(|s| *f.identity(*s).unwrap().id().as_bytes() == body.host.key)
            .unwrap();
        *a = f.resign(Body::Prepared(body), seed)?;
    }
    let sibling = f.resign(Body::Certificate(sibling), 7)?;
    assert_eq!(f.record(&sibling)?, Outcome::ReviewRequired);
    f.reopen()?;
    let inspection = f.store().control_inspect()?;
    assert!(inspection.halted);
    assert_eq!(inspection.head, head);
    assert!(f.install().is_err());
    Ok(())
}

#[test]
fn unauthenticated_fork_does_not_halt() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    let mut rival = vector("proposal");
    rival.signature[0] ^= 1;
    assert!(f.record(&rival).is_err());
    assert!(!f.store().control_inspect()?.halted);
    Ok(())
}

#[test]
fn prepare_crash_retains_lock() -> anyhow::Result<()> {
    let mut f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    f.store()
        .run(|db, _| journal::lock_prepare(db, &root_prepared(), &session(), &supported()))?;
    // Simulate process loss after the durable lock and before signing/ack persistence.
    f.reopen()?;
    let inspection = f.store().control_inspect()?;
    assert_eq!(
        inspection.unsigned_preparations,
        vec![vector("proposal").id()?]
    );
    assert_eq!(inspection.minimum_profiles, supported());
    f.prepare()?;
    f.reopen()?;
    assert!(
        f.store()
            .control_inspect()?
            .unsigned_preparations
            .is_empty()
    );
    assert_eq!(f.store().control_inspect()?.prepare_locks.len(), 1);
    Ok(())
}

#[test]
fn prepare_retry_cannot_replace_signed_assertion() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    let first = f.prepare()?;
    assert_eq!(f.prepare()?, first);
    let mut different = root_prepared();
    different.input_history = [0x88; 32];
    assert!(
        f.store()
            .control_prepare(different, &f.identity(7)?, &session(), &supported())
            .is_err()
    );
    assert!(
        f.store()
            .control_inspect()?
            .unsigned_preparations
            .is_empty()
    );
    Ok(())
}

#[test]
fn certificate_crash_resumes_same_installation() -> anyhow::Result<()> {
    let mut f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    f.prepare()?;
    f.record(&vector("certificate"))?;
    f.reopen()?;
    let inspection = f.store().control_inspect()?;
    assert_eq!(inspection.epoch, 0);
    assert_eq!(
        inspection.pending_certificates,
        vec![vector("certificate").id()?]
    );
    assert_eq!(inspection.prepare_locks.len(), 1);
    assert!(!inspection.all_installations_recorded);
    f.install()?;
    f.reopen()?;
    assert_eq!(f.store().control_inspect()?.epoch, 1);
    assert!(f.store().control_inspect()?.pending_certificates.is_empty());
    Ok(())
}

#[test]
fn installed_crash_recreates_ack() -> anyhow::Result<()> {
    let mut f = Fixture::new()?;
    f.record(&vector("certificate"))?;
    let id = vector("certificate").id()?;
    f.store()
        .run(|db, _| journal::install(db, &id, &session().coordinator, &session(), &supported()))?;
    f.reopen()?;
    assert_eq!(f.store().control_inspect()?.head, Some(id));
    assert!(!f.store().control_inspect()?.all_installations_recorded);
    assert_eq!(f.install()?, vector("installed"));
    assert_eq!(f.install()?, vector("installed"));
    Ok(())
}

#[test]
fn interrupted_transaction_rolls_back() -> anyhow::Result<()> {
    let mut f = Fixture::new()?;
    let before = f.store().control_inspect()?;
    f.store().run(|db, _| {
        let tx = db.transaction()?;
        tx.execute("UPDATE activation_control_state SET epoch=99, halted=1", [])?;
        // Drop without commit is the same SQLite boundary as process loss.
        Ok(())
    })?;
    f.reopen()?;
    assert_eq!(f.store().control_inspect()?, before);
    Ok(())
}

#[test]
fn reopen_rejects_corrupt_state() -> anyhow::Result<()> {
    for damage in [
        "UPDATE activation_control_state SET epoch=2",
        "UPDATE activation_control_state SET floor=x'5b5d'",
        "UPDATE activation_control_state SET halted=1",
        "DELETE FROM activation_control_envelopes WHERE kind='proposal'",
        "UPDATE activation_control_envelopes SET canonical=x'00' WHERE kind='certificate'",
        "DELETE FROM activation_control_membership",
        "UPDATE activation_control_prepare SET acknowledgment_digest=zeroblob(32)",
    ] {
        let mut f = Fixture::new()?;
        f.record(&vector("proposal"))?;
        f.prepare()?;
        f.record(&vector("certificate"))?;
        f.install()?;
        f.sql(damage)?;
        f.reopen()?;
        assert!(f.store().control_inspect().is_err(), "{damage}");
        assert!(f.install().is_err());
    }
    Ok(())
}

#[test]
fn additive_tables_preserve_existing_store() -> anyhow::Result<()> {
    let mut f = Fixture::new()?;
    let catalog = serde_json::to_value(f.store().catalog()?)?;
    let existing_schema = f.store().run(|db, _| {
        let mut statement = db.prepare("SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'activation_control_%' ORDER BY name")?;
        Ok(statement.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?.collect::<Result<Vec<_>, _>>()?)
    })?;
    f.record(&vector("proposal"))?;
    f.prepare()?;
    f.record(&vector("certificate"))?;
    f.install()?;
    f.reopen()?;
    assert_eq!(serde_json::to_value(f.store().catalog()?)?, catalog);
    f.store().run(|db, _| {
        let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        assert_eq!(version, 5);
        let mut statement = db.prepare("SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'activation_control_%' ORDER BY name")?;
        assert_eq!(statement.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?.collect::<Result<Vec<_>, _>>()?, existing_schema);
        let receipt: (String, String) = db.query_row("SELECT digest, record FROM shared_requests WHERE id='retained-request'", [], |r| Ok((r.get(0)?, r.get(1)?)))?;
        assert_eq!(receipt, ("retained-digest".into(), "retained-record".into()));
        Ok(())
    })?;
    Ok(())
}
