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
    /// An initialized host already frozen for maintenance.
    fn new() -> anyhow::Result<Self> {
        let f = Self::uninitialized()?;
        f.store().control_initialize()?;
        f.store().control_freeze()?;
        Ok(f)
    }

    fn unfrozen() -> anyhow::Result<Self> {
        let f = Self::uninitialized()?;
        f.store().control_initialize()?;
        Ok(f)
    }

    fn uninitialized() -> anyhow::Result<Self> {
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

    /// The refusal a signing transaction would get, if any.
    fn refusal(&self) -> anyhow::Result<Option<Refusal>> {
        match self.store().run(|db, _| ensure_writable(db)) {
            Ok(()) => Ok(None),
            Err(error) => Ok(Some(
                *error
                    .downcast_ref::<Refusal>()
                    .ok_or_else(|| anyhow::anyhow!("untyped refusal"))?,
            )),
        }
    }

    fn acknowledge_installations(&self) -> anyhow::Result<()> {
        let certificate = vector("certificate");
        let id = certificate.id()?;
        for seed in [8, 9] {
            let key = *self.identity(seed)?.id().as_bytes();
            let host = proposal(&super::certificate(&certificate)?.proposal)?
                .hosts
                .iter()
                .find(|h| h.key == key)
                .unwrap()
                .clone();
            self.record(&self.resign(
                Body::Installed(Installed {
                    certificate: id,
                    host,
                    epoch: 1,
                }),
                seed,
            )?)?;
        }
        Ok(())
    }

    fn sql(&self, sql: &str) -> anyhow::Result<()> {
        self.store().run(|db, _| {
            db.execute_batch(sql)?;
            Ok(())
        })
    }
}

/// The host of the fixture proposal whose identity has `seed`.
fn host(f: &Fixture, seed: u8) -> anyhow::Result<Host> {
    let key = *f.identity(seed)?.id().as_bytes();
    Ok(proposal(&vector("proposal"))?
        .hosts
        .iter()
        .find(|h| h.key == key)
        .unwrap()
        .clone())
}

/// A withdrawal from the fixture proposal signed by another host.
fn withdrawal(f: &Fixture, seed: u8) -> anyhow::Result<Signed> {
    f.resign(
        Body::Withdrawn(Withdrawn {
            proposal: vector("proposal").id()?,
            host: host(f, seed)?,
        }),
        seed,
    )
}

fn withdraw(f: &Fixture) -> anyhow::Result<Signed> {
    f.store().control_withdraw(
        vector("proposal").id()?,
        session().coordinator,
        &f.identity(7)?,
        &session(),
    )
}

fn abort(f: &Fixture) -> anyhow::Result<Signed> {
    f.store()
        .control_abort(vector("proposal").id()?, &f.identity(7)?, &session())
}

/// Whether a replicated record this host does not hold may be stored.
fn intake(f: &Fixture) -> anyhow::Result<()> {
    f.store().run(|db, _| ensure_intake(db))
}

fn root_prepared() -> Prepared {
    let p = vector("proposal");
    Prepared {
        proposal: p.id().unwrap(),
        host: session().coordinator,
        implementations: vec!["fixture-build-v1".into()],
        implemented_profiles: supported().into_iter().collect(),
        input_history: digest(vectors()["input_history"].as_str().unwrap()).unwrap(),
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
            proposal: Box::new(proposed.clone()),
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
            ..p.clone()
        })),
        7,
    )?;
    assert_vector(&successor, &vectors()["successor"])?;
    let mut withdrawals = Vec::new();
    for seed in [7, 8, 9] {
        withdrawals.push(withdrawal(&f, seed)?);
    }
    withdrawals.sort_by_key(|w| w.body.signer().key);
    for (signed, expected) in withdrawals
        .iter()
        .zip(vectors()["withdrawn"].as_array().unwrap())
    {
        assert_vector(signed, expected)?;
    }
    let aborted = f.resign(
        Body::Aborted(Aborted {
            proposal: proposed.id()?,
            withdrawn: withdrawals,
            coordinator: p.coordinator,
        }),
        7,
    )?;
    assert_vector(&aborted, &vectors()["aborted"])?;
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
    for name in ["proposal", "certificate", "installed", "successor", "aborted"] {
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
    for name in ["proposal", "certificate", "installed", "successor", "aborted"] {
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
    // Installation enforces only the proposal's profiles, so an acknowledgment
    // demanding more would be certified but never enforced.
    let mut bad = root_prepared();
    let wider: BTreeSet<String> = supported()
        .into_iter()
        .chain(["extra-profile-v1".into()])
        .collect();
    bad.minimum_profiles = wider.iter().cloned().collect();
    bad.implemented_profiles = wider.into_iter().collect();
    assert!(verify_prepared(&f.resign(Body::Prepared(bad), 7)?, &vector("proposal")).is_err());
    Ok(())
}

#[test]
fn nested_acknowledgment_signature_is_verified() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    let mut c = certificate(&vector("certificate"))?.clone();
    c.prepared[0].signature[0] ^= 1;
    // Body::signing_bytes covers nested envelopes, so a valid outer signature
    // must not hide an invalid nested one.
    let body = Body::Certificate(c);
    let signature = f.identity(7)?.sign(&body.signing_bytes()?);
    let outer = Signed {
        body,
        signature: signature.try_into().unwrap(),
    };
    assert!(outer.verify().is_err());
    assert!(f.record(&outer).is_err());
    Ok(())
}

#[test]
fn mismatched_prepare_identity_changes_nothing() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    let before = f.store().control_inspect()?;
    assert!(
        f.store()
            .control_prepare(root_prepared(), &f.identity(8)?, &session(), &supported())
            .is_err()
    );
    assert_eq!(f.store().control_inspect()?, before);
    Ok(())
}

#[test]
fn mismatched_install_identity_changes_nothing() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    f.prepare()?;
    f.record(&vector("certificate"))?;
    let before = f.store().control_inspect()?;
    assert!(
        f.store()
            .control_install(
                vector("certificate").id()?,
                session().coordinator,
                &f.identity(8)?,
                &session(),
                &supported(),
            )
            .is_err()
    );
    assert_eq!(f.store().control_inspect()?, before);
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

/// Revoke the host with `seed` in this host's trusted membership only.
fn revoke_locally(f: &Fixture, seed: u8) -> anyhow::Result<()> {
    // Observe every grant stored so far, as a real revocation would.
    let proof = f.store().run(|db, _| crate::enrollment::read_proof(db))?;
    let root_grant = proof.grants.iter().find(|g| g.authority.is_none()).unwrap();
    let mut revocation = crate::enrollment::Revocation {
        version: 1,
        id: String::new(),
        cluster: root_grant.cluster.clone(),
        issuer: root_grant.member.clone(),
        member: f.identity(seed)?.id().to_string(),
        authority: root_grant.id.clone(),
        observed: proof.grants.iter().map(|g| g.id.clone()).collect(),
        change_heads: vec![],
        signature: String::new(),
    };
    revocation.id = hex::encode(Sha256::digest(revocation.signing_bytes()?));
    revocation.signature = hex::encode(f.identity(7)?.sign(&revocation.signing_bytes()?));
    f.store().run(|db, _| {
        db.execute(
            "INSERT INTO cluster_revocations VALUES (?, ?)",
            params![revocation.id, serde_json::to_vec(&revocation)?],
        )?;
        Ok(())
    })?;
    let local = f.store().run(|db, _| crate::enrollment::read_proof(db))?;
    assert_eq!(
        local.revocation_state()?.0,
        vec![0],
        "revocation must be active"
    );
    Ok(())
}

/// A grant signed by the fixture host `issuer` under its fixture grant.
fn issue(
    f: &Fixture,
    issuer: u8,
    member: String,
    host: bool,
) -> anyhow::Result<crate::enrollment::Grant> {
    let identity = f.identity(issuer)?;
    let issuer_key = identity.id().to_string();
    let authority = member_proof()
        .grants
        .into_iter()
        .find(|g| g.member == issuer_key)
        .unwrap();
    issue_under(&identity, &authority, member, host)
}

/// As `issue`, for callers that issue many grants and load the issuer once.
fn issue_under(
    identity: &crate::peer::Identity,
    authority: &crate::enrollment::Grant,
    member: String,
    host: bool,
) -> anyhow::Result<crate::enrollment::Grant> {
    let mut grant = crate::enrollment::Grant {
        version: 1,
        id: String::new(),
        cluster: authority.cluster.clone(),
        issuer: authority.member.clone(),
        member,
        host,
        authority: Some(authority.id.clone()),
        signature: String::new(),
    };
    grant.id = hex::encode(Sha256::digest(grant.signing_bytes()?));
    grant.signature = hex::encode(identity.sign(&grant.signing_bytes()?));
    Ok(grant)
}

/// The fixture proof plus a host grant from `issuer` to `member` that this
/// host has never stored.
fn delegated(f: &Fixture, issuer: u8, member: u8) -> anyhow::Result<crate::enrollment::Proof> {
    let mut proof = member_proof();
    proof.grants.push(issue(
        f,
        issuer,
        f.identity(member)?.id().to_string(),
        true,
    )?);
    Ok(proof)
}

fn store_grant(f: &Fixture, grant: &crate::enrollment::Grant) -> anyhow::Result<()> {
    f.store().run(|db, _| {
        db.execute(
            "INSERT INTO cluster_enrollment_grants VALUES (?, ?)",
            params![grant.id, serde_json::to_vec(grant)?],
        )?;
        Ok(())
    })
}

/// RFC 4648 base32 without padding, an alternative text form of a key.
fn base32(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let (mut buffer, mut bits, mut out) = (0u32, 0, String::new());
    for &byte in bytes {
        buffer = (buffer << 8) | u32::from(byte);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            out.push(ALPHABET[((buffer >> bits) & 31) as usize] as char);
        }
        buffer &= (1 << bits) - 1;
    }
    if bits > 0 {
        out.push(ALPHABET[((buffer << (5 - bits)) & 31) as usize] as char);
    }
    out
}

/// A sibling of the fixture proposal coordinated by `seed` under `proof`.
fn rival(f: &Fixture, proof: &crate::enrollment::Proof, seed: u8) -> anyhow::Result<Signed> {
    rival_as(f, proof, seed, None)
}

/// As `rival`, choosing the coordinator's grant when its key has several.
fn rival_as(
    f: &Fixture,
    proof: &crate::enrollment::Proof,
    seed: u8,
    grant: Option<Digest>,
) -> anyhow::Result<Signed> {
    let mut p = proposal(&vector("proposal"))?.clone();
    let (membership, hosts) = membership_revision(p.cluster, proof)?;
    p.membership = membership;
    p.nonce = [0x99; 32];
    p.coordinator = hosts
        .iter()
        .find(|h| {
            h.key == *f.identity(seed).unwrap().id().as_bytes()
                && grant.is_none_or(|g| g == h.grant)
        })
        .unwrap()
        .clone();
    p.hosts = hosts;
    f.resign(Body::Proposal(Box::new(p)), seed)
}

#[test]
fn locally_revoked_signer_cannot_halt() -> anyhow::Result<()> {
    // The supplied proof predates the revocation, so it still authorizes
    // the signer and verifies on its own.
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    revoke_locally(&f, 9)?;
    let proof = member_proof();
    let signed = rival(&f, &proof, 9)?;
    assert!(
        f.store()
            .control_record(&signed, &proof, &session())
            .is_err()
    );
    assert!(!f.store().control_inspect()?.halted);
    Ok(())
}

#[test]
fn grant_from_locally_revoked_issuer_cannot_halt() -> anyhow::Result<()> {
    // A revoked host delegates to a fresh key this host has never seen.
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    revoke_locally(&f, 9)?;
    let proof = delegated(&f, 9, 10)?;
    let signed = rival(&f, &proof, 10)?;
    assert!(
        f.store()
            .control_record(&signed, &proof, &session())
            .is_err()
    );
    assert!(!f.store().control_inspect()?.halted);
    Ok(())
}

#[test]
fn key_encoding_alias_cannot_evade_revocation() -> anyhow::Result<()> {
    // Before its revocation, host 9 grants itself a second identity that
    // names the same key in base32 instead of hex.
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    let key9 = *f.identity(9)?.id().as_bytes();
    let alias = base32(&key9);
    assert_eq!(key(&alias)?, key9, "alias must decode to the same key");
    assert_ne!(alias, f.identity(9)?.id().to_string());
    let grant = issue(&f, 9, alias, true)?;
    store_grant(&f, &grant)?;
    revoke_locally(&f, 9)?;
    let mut proof = member_proof();
    proof.grants.push(grant.clone());
    let signed = rival_as(&f, &proof, 9, Some(digest(&grant.id)?))?;
    assert!(
        f.store()
            .control_record(&signed, &proof, &session())
            .is_err()
    );
    assert!(!f.store().control_inspect()?.halted);
    Ok(())
}

#[test]
fn large_local_membership_does_not_veto_unknown_valid_grant() -> anyhow::Result<()> {
    // Local and supplied proofs each hold the 4,096-grant maximum but differ
    // in one grant, so their union would exceed it. Call the veto directly:
    // recording a sibling recomputes membership over 4,096 grants, which is
    // too slow for CI.
    let f = Fixture::new()?;
    let mut local = member_proof();
    let known = local.grants.len();
    // Load the issuer once and commit once: thousands of separate commits and
    // fixture reads made this test the longest in the suite on CI.
    let identity = f.identity(7)?;
    let issuer_key = identity.id().to_string();
    let authority = local
        .grants
        .iter()
        .find(|g| g.member == issuer_key)
        .unwrap()
        .clone();
    for i in 0..(4096 - known) as u32 {
        let mut secret = [0u8; 32];
        secret[..4].copy_from_slice(&i.to_le_bytes());
        secret[31] = 0xa5;
        let member = iroh::SecretKey::from_bytes(&secret).public().to_string();
        local
            .grants
            .push(issue_under(&identity, &authority, member, false)?);
    }
    f.store().run(|db, _| {
        let tx = db.transaction()?;
        for grant in &local.grants[known..] {
            tx.execute(
                "INSERT INTO cluster_enrollment_grants VALUES (?, ?)",
                params![grant.id, serde_json::to_vec(grant)?],
            )?;
        }
        tx.commit()?;
        Ok(())
    })?;
    let mut supplied = local.clone();
    supplied.grants.pop();
    let grant = issue(&f, 7, f.identity(10)?.id().to_string(), true)?;
    supplied.grants.push(grant.clone());
    let host = Host {
        key: *f.identity(10)?.id().as_bytes(),
        grant: digest(&grant.id)?,
    };
    assert!(
        !f.store()
            .run(|db, _| journal::revoked_locally(db, &host, &supplied))?
    );
    Ok(())
}

#[test]
fn locally_unknown_valid_grant_still_halts() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    revoke_locally(&f, 9)?;
    let proof = delegated(&f, 7, 10)?;
    let signed = rival(&f, &proof, 10)?;
    assert_eq!(
        f.store().control_record(&signed, &proof, &session())?,
        Outcome::ReviewRequired
    );
    assert!(f.store().control_inspect()?.halted);
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
        // A rolled-back head contradicts the retained signed installation.
        "UPDATE activation_control_state SET head=NULL, epoch=0",
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

#[test]
fn host_without_control_storage_stays_writable() -> anyhow::Result<()> {
    let f = Fixture::uninitialized()?;
    assert_eq!(f.refusal()?, None);
    assert!(f.store().control_freeze().is_err());
    assert_eq!(f.refusal()?, None);
    let f = Fixture::unfrozen()?;
    assert_eq!(f.refusal()?, None);
    Ok(())
}

#[test]
fn activation_steps_require_the_freeze() -> anyhow::Result<()> {
    let f = Fixture::unfrozen()?;
    f.record(&vector("proposal"))?;
    assert!(f.prepare().is_err());
    assert!(f.record(&vector("certificate")).is_err());
    let state = f.store().control_inspect()?;
    assert!(state.prepare_locks.is_empty() && state.pending_certificates.is_empty());
    assert!(state.minimum_profiles.is_empty() && !state.frozen);
    assert_eq!(f.refusal()?, None);
    f.store().control_freeze()?;
    f.prepare()?;
    f.record(&vector("certificate"))?;
    f.install()?;
    Ok(())
}

#[test]
fn freeze_survives_restart_and_releases_only_when_settled() -> anyhow::Result<()> {
    let mut f = Fixture::new()?;
    f.store().control_freeze()?;
    f.reopen()?;
    assert!(f.store().control_inspect()?.frozen);
    assert_eq!(f.refusal()?, Some(Refusal::Maintenance));
    f.record(&vector("proposal"))?;
    f.prepare()?;
    assert!(f.store().control_release().is_err(), "pending preparation");
    f.record(&vector("certificate"))?;
    assert!(f.store().control_release().is_err(), "pending certificate");
    f.install()?;
    assert!(
        f.store().control_release().is_err(),
        "other hosts have not acknowledged installation"
    );
    f.reopen()?;
    assert_eq!(f.refusal()?, Some(Refusal::Maintenance));
    f.acknowledge_installations()?;
    f.store().control_release()?;
    for _ in 0..2 {
        let state = f.store().control_inspect()?;
        assert!(!state.frozen && state.released && state.pending_preparations.is_empty());
        assert_eq!(f.refusal()?, None);
        f.reopen()?;
    }
    assert!(f.store().control_release().is_err(), "not frozen");
    // The next epoch needs its own freeze and its own release.
    f.store().control_freeze()?;
    assert!(f.store().control_inspect()?.released);
    assert_eq!(f.refusal()?, Some(Refusal::Maintenance));
    Ok(())
}

#[test]
fn release_requires_the_certified_membership() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("certificate"))?;
    f.install()?;
    f.acknowledge_installations()?;
    // A grant learned from a peer after installation was never agreed.
    store_grant(&f, &issue(&f, 7, f.identity(10)?.id().to_string(), true)?)?;
    assert!(f.store().control_release().is_err());
    assert_eq!(f.refusal()?, Some(Refusal::Maintenance));
    Ok(())
}

#[test]
fn next_epoch_waits_for_every_installation_acknowledgment() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("certificate"))?;
    f.install()?;
    let next = vector("successor");
    let expected = Session {
        coordinator: session().coordinator,
        nonce: [0x77; 32],
    };
    f.store()
        .control_record(&next, &member_proof(), &expected)?;
    let mut ack = root_prepared();
    ack.proposal = next.id()?;
    let prepare = || {
        f.store()
            .control_prepare(ack.clone(), &f.identity(7)?, &expected, &supported())
    };
    assert!(prepare().is_err(), "hosts 8 and 9 never confirmed epoch 1");
    assert!(f.store().control_inspect()?.pending_preparations.is_empty());
    f.acknowledge_installations()?;
    prepare()?;
    Ok(())
}

#[test]
fn another_hosts_preparation_keeps_this_host_frozen() -> anyhow::Result<()> {
    let remote = |f: &Fixture| -> anyhow::Result<Signed> {
        let key = *f.identity(8)?.id().as_bytes();
        let mut ack = root_prepared();
        ack.host = proposal(&vector("proposal"))?
            .hosts
            .iter()
            .find(|h| h.key == key)
            .unwrap()
            .clone();
        f.resign(Body::Prepared(ack), 8)
    };
    let f = Fixture::unfrozen()?;
    f.record(&vector("proposal"))?;
    assert!(f.record(&remote(&f)?).is_err());
    assert_eq!(f.refusal()?, None);

    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    f.record(&remote(&f)?)?;
    let state = f.store().control_inspect()?;
    assert!(state.prepare_locks.is_empty());
    assert_eq!(state.pending_preparations, [vector("proposal").id()?]);
    assert!(f.store().control_release().is_err());
    assert_eq!(f.refusal()?, Some(Refusal::Maintenance));
    Ok(())
}

#[test]
fn abandoned_maintenance_releases_without_a_head() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    f.store().control_release()?;
    let state = f.store().control_inspect()?;
    assert!(!state.frozen && !state.released && state.head.is_none());
    assert_eq!(f.refusal()?, None);
    Ok(())
}

#[test]
fn halted_or_altered_journal_refuses_writes_until_reviewed() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    let mut p = proposal(&vector("proposal"))?.clone();
    p.nonce = [0x99; 32];
    let rival = f.resign(Body::Proposal(Box::new(p)), 7)?;
    assert_eq!(f.record(&rival)?, Outcome::ReviewRequired);
    assert_eq!(f.refusal()?, Some(Refusal::Review));
    assert!(f.store().control_release().is_err());

    for damage in [
        "UPDATE activation_control_state SET epoch=2",
        // Pending activation state without the freeze was altered outside the journal.
        "DELETE FROM activation_control_freeze",
        "DROP TABLE activation_control_freeze",
    ] {
        let f = Fixture::new()?;
        f.record(&vector("proposal"))?;
        f.prepare()?;
        f.sql(damage)?;
        assert_eq!(f.refusal()?, Some(Refusal::Review), "{damage}");
        assert!(f.store().control_inspect().is_err(), "{damage}");
        // Freezing again is always allowed and restores the invariant it guards.
        f.store().control_freeze()?;
        if damage.contains("freeze") {
            assert_eq!(f.refusal()?, Some(Refusal::Maintenance), "{damage}");
        }
    }

    let f = Fixture::new()?;
    f.record(&vector("certificate"))?;
    f.install()?;
    f.acknowledge_installations()?;
    f.sql("DELETE FROM activation_control_freeze")?;
    assert_eq!(
        f.refusal()?,
        Some(Refusal::Review),
        "an installed head without a recorded release must not accept writes"
    );
    Ok(())
}

#[test]
fn input_history_covers_music_and_playlist_records() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    let empty = f.store().control_input_history()?;
    assert_eq!(
        hex::encode(empty),
        vectors()["input_history"].as_str().unwrap()
    );
    f.sql("INSERT INTO shared_records VALUES ('a', X'00')")?;
    let music = f.store().control_input_history()?;
    f.sql("DELETE FROM shared_records; INSERT INTO shared_playlists VALUES ('a', X'00')")?;
    let playlist = f.store().control_input_history()?;
    assert!(empty != music && empty != playlist && music != playlist);
    Ok(())
}

#[test]
fn prepare_and_install_require_this_hosts_input_history() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    f.sql("INSERT INTO shared_records VALUES ('a', X'00')")?;
    assert!(f.prepare().is_err(), "the fixture acknowledges an empty history");
    assert!(f.store().control_inspect()?.prepare_locks.is_empty());
    let mut ack = root_prepared();
    ack.input_history = f.store().control_input_history()?;
    f.store()
        .control_prepare(ack, &f.identity(7)?, &session(), &supported())?;
    // The certificate acknowledges a history this host does not have.
    f.record(&vector("certificate"))?;
    assert!(f.install().is_err());
    assert!(f.store().control_inspect()?.head.is_none());
    Ok(())
}

#[test]
fn prepare_lock_pins_replicated_intake_until_installed() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    intake(&f)?;
    f.prepare()?;
    assert!(intake(&f).is_err());
    f.record(&vector("certificate"))?;
    assert!(intake(&f).is_err());
    f.install()?;
    intake(&f)?;

    // A certificate pins a host that holds no lock of its own as well.
    let f = Fixture::new()?;
    f.record(&vector("certificate"))?;
    assert!(intake(&f).is_err());
    let f = Fixture::new()?;
    f.sql("UPDATE activation_control_state SET epoch=2")?;
    assert!(intake(&f).is_err(), "unreadable journal");
    intake(&Fixture::uninitialized()?)?;
    Ok(())
}

#[test]
fn withdrawal_refuses_preparation_and_a_later_certificate_halts() -> anyhow::Result<()> {
    let mut f = Fixture::new()?;
    let id = vector("proposal").id()?;
    assert!(withdraw(&f).is_err(), "unknown proposal");
    f.record(&vector("proposal"))?;
    assert!(
        f.store()
            .control_withdraw(id, host(&f, 8)?, &f.identity(8)?, &session())
            .is_err(),
        "not this host"
    );
    let signed = withdraw(&f)?;
    assert_eq!(withdraw(&f)?, signed);
    f.reopen()?;
    assert_eq!(f.store().control_inspect()?.withdrawn, [id]);
    assert!(f.prepare().is_err());
    assert!(f.store().control_inspect()?.prepare_locks.is_empty());
    assert_eq!(f.record(&vector("certificate"))?, Outcome::ReviewRequired);
    assert_eq!(f.refusal()?, Some(Refusal::Review));
    f.reopen()?;
    let state = f.store().control_inspect()?;
    assert!(state.halted && state.pending_certificates.is_empty());

    let f = Fixture::new()?;
    f.record(&vector("certificate"))?;
    assert!(withdraw(&f).is_err(), "a stored certificate goes forward");
    Ok(())
}

#[test]
fn abort_needs_every_withdrawal_and_resolves_the_lock() -> anyhow::Result<()> {
    let mut f = Fixture::new()?;
    let id = vector("proposal").id()?;
    f.record(&vector("proposal"))?;
    f.prepare()?;
    assert!(abort(&f).is_err(), "the coordinator has not withdrawn");
    withdraw(&f)?;
    f.record(&withdrawal(&f, 8)?)?;
    assert!(abort(&f).is_err(), "host 9 has not withdrawn");
    assert!(f.store().control_release().is_err());
    assert!(intake(&f).is_err());
    f.record(&withdrawal(&f, 9)?)?;
    assert_eq!(abort(&f)?, vector("aborted"));
    f.reopen()?;
    let state = f.store().control_inspect()?;
    assert_eq!(state.aborted, [id]);
    assert_eq!(state.prepare_locks, [id], "the lock stays as evidence");
    assert!(state.pending_preparations.is_empty() && state.minimum_profiles.is_empty());
    intake(&f)?;
    assert!(f.prepare().is_err());
    f.store().control_release()?;
    assert_eq!(f.refusal()?, None);
    Ok(())
}

#[test]
fn recorded_abort_resolves_a_prepared_host_and_contradicts_a_certificate() -> anyhow::Result<()> {
    let aborted = vector("aborted");
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    f.prepare()?;
    let Body::Aborted(mut partial) = aborted.body.clone() else {
        unreachable!()
    };
    partial.withdrawn.pop();
    assert!(f.record(&f.resign(Body::Aborted(partial), 7)?).is_err());
    assert_eq!(f.record(&aborted)?, Outcome::Stored);
    assert_eq!(f.record(&aborted)?, Outcome::Duplicate);
    let state = f.store().control_inspect()?;
    assert!(state.pending_preparations.is_empty() && state.minimum_profiles.is_empty());
    f.store().control_release()?;
    assert_eq!(f.refusal()?, None);
    assert_eq!(f.record(&vector("certificate"))?, Outcome::ReviewRequired);
    assert_eq!(f.refusal()?, Some(Refusal::Review));

    let mut f = Fixture::new()?;
    f.record(&vector("certificate"))?;
    assert_eq!(f.record(&aborted)?, Outcome::ReviewRequired);
    f.reopen()?;
    let state = f.store().control_inspect()?;
    assert!(state.halted && state.aborted.is_empty());
    assert_eq!(state.pending_certificates, [vector("certificate").id()?]);
    Ok(())
}

#[test]
fn certificate_installs_after_membership_moved_but_release_waits() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    f.prepare()?;
    store_grant(&f, &issue(&f, 7, f.identity(10)?.id().to_string(), true)?)?;
    f.record(&vector("certificate"))?;
    f.install()?;
    f.acknowledge_installations()?;
    assert!(f.store().control_release().is_err());
    assert_eq!(f.refusal()?, Some(Refusal::Maintenance));

    // A host that never prepared holds no evidence for the old revision.
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    store_grant(&f, &issue(&f, 7, f.identity(10)?.id().to_string(), true)?)?;
    assert!(f.record(&vector("certificate")).is_err());
    assert!(f.store().control_inspect()?.pending_certificates.is_empty());
    Ok(())
}

#[test]
fn next_epoch_excuses_only_a_host_the_new_membership_revokes() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("certificate"))?;
    f.install()?;
    revoke_locally(&f, 9)?;
    let proof = f.store().membership()?;
    let mut p = proposal(&vector("successor"))?.clone();
    let (membership, hosts) = membership_revision(p.cluster, &proof)?;
    let revoked = host(&f, 9)?.key;
    assert!(hosts.iter().all(|h| h.key != revoked));
    p.membership = membership;
    p.hosts = hosts;
    let next = f.resign(Body::Proposal(Box::new(p)), 7)?;
    let expected = Session {
        coordinator: session().coordinator,
        nonce: [0x77; 32],
    };
    f.store().control_record(&next, &proof, &expected)?;
    let mut ack = root_prepared();
    ack.proposal = next.id()?;
    let prepare = || {
        f.store()
            .control_prepare(ack.clone(), &f.identity(7)?, &expected, &supported())
    };
    assert!(prepare().is_err(), "host 8 is still authorized and silent");
    f.record(&f.resign(
        Body::Installed(Installed {
            certificate: vector("certificate").id()?,
            host: host(&f, 8)?,
            epoch: 1,
        }),
        8,
    )?)?;
    assert_eq!(f.store().control_inspect()?.unacknowledged, [revoked]);
    prepare()?;
    Ok(())
}

#[test]
fn designation_names_an_authorized_host_and_ends_with_release() -> anyhow::Result<()> {
    let mut f = Fixture::new()?;
    assert!(f.store().control_session()?.is_none());
    let stranger = Session {
        coordinator: Host {
            key: *f.identity(10)?.id().as_bytes(),
            grant: [0; 32],
        },
        nonce: [1; 32],
    };
    assert!(f.store().control_designate(&stranger).is_err());
    assert!(f.store().control_host(stranger.coordinator.key).is_err());
    assert_eq!(
        f.store().control_host(session().coordinator.key)?,
        session().coordinator
    );
    f.store().control_designate(&session())?;
    f.reopen()?;
    let stored = f.store().control_session()?.unwrap();
    assert_eq!(
        (stored.coordinator, stored.nonce),
        (session().coordinator, session().nonce)
    );
    f.record(&vector("proposal"))?;
    f.prepare()?;
    let other = Session {
        coordinator: host(&f, 8)?,
        nonce: [2; 32],
    };
    assert!(
        f.store().control_designate(&other).is_err(),
        "the pending preparation belongs to the first session"
    );
    f.store().control_designate(&session())?;
    f.record(&vector("aborted"))?;
    f.store().control_designate(&other)?;
    f.store().control_release()?;
    assert!(f.store().control_session()?.is_none());
    Ok(())
}

#[test]
fn aborted_proposal_allows_a_new_one_from_the_same_head() -> anyhow::Result<()> {
    let mut f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    f.prepare()?;
    f.record(&vector("aborted"))?;
    let mut p = proposal(&vector("proposal"))?.clone();
    p.nonce = [0x88; 32];
    let retry = f.resign(Body::Proposal(Box::new(p)), 7)?;
    let expected = Session {
        coordinator: session().coordinator,
        nonce: [0x88; 32],
    };
    assert_eq!(
        f.store()
            .control_record(&retry, &member_proof(), &expected)?,
        Outcome::Stored
    );
    let mut ack = root_prepared();
    ack.proposal = retry.id()?;
    f.store()
        .control_prepare(ack, &f.identity(7)?, &expected, &supported())?;
    f.reopen()?;
    let state = f.store().control_inspect()?;
    assert!(!state.halted);
    assert_eq!(state.pending_preparations, [retry.id()?]);
    // Two unresolved proposals from one head are still a fork.
    let mut p = proposal(&vector("proposal"))?.clone();
    p.nonce = [0x99; 32];
    let rival = f.resign(Body::Proposal(Box::new(p)), 7)?;
    assert_eq!(f.record(&rival)?, Outcome::ReviewRequired);
    Ok(())
}

#[test]
fn received_withdrawals_bind_this_host_and_contradict_a_certificate() -> anyhow::Result<()> {
    // The host's own signed promise arrives from a peer after its database
    // was restored to a state before the withdrawal.
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    f.record(&withdrawal(&f, 7)?)?;
    assert_eq!(
        f.store().control_inspect()?.withdrawn,
        [vector("proposal").id()?]
    );
    assert!(f.prepare().is_err());
    f.record(&withdrawal(&f, 8)?)?;
    assert_eq!(f.store().control_inspect()?.withdrawn.len(), 1);

    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    f.record(&withdrawal(&f, 8)?)?;
    assert_eq!(f.record(&vector("certificate"))?, Outcome::ReviewRequired);
    assert!(f.store().control_inspect()?.halted);

    let mut f = Fixture::new()?;
    f.record(&vector("certificate"))?;
    assert_eq!(f.record(&withdrawal(&f, 8)?)?, Outcome::ReviewRequired);
    f.reopen()?;
    assert!(f.store().control_inspect()?.halted);

    // A host revoked here cannot halt the journal with its word alone.
    let f = Fixture::new()?;
    f.record(&vector("certificate"))?;
    revoke_locally(&f, 8)?;
    assert!(f.record(&withdrawal(&f, 8)?).is_err());
    assert!(!f.store().control_inspect()?.halted);
    Ok(())
}

#[test]
fn unreadable_membership_is_not_a_membership_change() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    f.prepare()?;
    f.sql("DELETE FROM cluster_enrollment_grants")?;
    assert!(f.record(&vector("certificate")).is_err());
    assert!(f.store().control_inspect()?.pending_certificates.is_empty());
    Ok(())
}

#[test]
fn contradiction_halts_even_after_the_coordinator_was_revoked() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    f.record(&vector("aborted"))?;
    f.store().control_release()?;
    revoke_coordinator(&f)?;
    assert!(revoked_locally_for_test(&f)?);
    assert_eq!(f.record(&vector("certificate"))?, Outcome::ReviewRequired);
    Ok(())
}

/// Host 8 revokes the coordinator, so the root's own grant chain stays valid.
fn revoke_coordinator(f: &Fixture) -> anyhow::Result<()> {
    let proof = f.store().run(|db, _| crate::enrollment::read_proof(db))?;
    let authority = proof
        .grants
        .iter()
        .find(|g| g.member == f.identity(8).unwrap().id().to_string())
        .unwrap();
    let mut revocation = crate::enrollment::Revocation {
        version: 1,
        id: String::new(),
        cluster: authority.cluster.clone(),
        issuer: authority.member.clone(),
        member: f.identity(7)?.id().to_string(),
        authority: authority.id.clone(),
        observed: proof.grants.iter().map(|g| g.id.clone()).collect(),
        change_heads: vec![],
        signature: String::new(),
    };
    revocation.id = hex::encode(Sha256::digest(revocation.signing_bytes()?));
    revocation.signature = hex::encode(f.identity(8)?.sign(&revocation.signing_bytes()?));
    f.sql(&format!(
        "INSERT INTO cluster_revocations VALUES ('{}', X'{}')",
        revocation.id,
        hex::encode(serde_json::to_vec(&revocation)?)
    ))
}

fn revoked_locally_for_test(f: &Fixture) -> anyhow::Result<bool> {
    f.store()
        .run(|db, _| journal::revoked_locally(db, &session().coordinator, &member_proof()))
}

#[test]
fn aborted_certificate_halts_after_a_retry_and_a_revoked_coordinator() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    f.record(&vector("aborted"))?;
    let mut p = proposal(&vector("proposal"))?.clone();
    p.nonce = [0x88; 32];
    let expected = Session {
        coordinator: session().coordinator,
        nonce: [0x88; 32],
    };
    f.store().control_record(
        &f.resign(Body::Proposal(Box::new(p)), 7)?,
        &member_proof(),
        &expected,
    )?;
    revoke_coordinator(&f)?;
    assert!(revoked_locally_for_test(&f)?);
    // The retry makes the certificate a sibling too; the abort must win.
    assert_eq!(f.record(&vector("certificate"))?, Outcome::ReviewRequired);
    assert!(f.store().control_inspect()?.halted);
    Ok(())
}

#[test]
fn withdrawal_cannot_reopen_a_settled_installation() -> anyhow::Result<()> {
    let installed = |f: &Fixture, seed: u8| -> anyhow::Result<Signed> {
        f.resign(
            Body::Installed(Installed {
                certificate: vector("certificate").id()?,
                host: host(f, seed)?,
                epoch: 1,
            }),
            seed,
        )
    };
    // Host 8 acknowledged the installation; host 9 has not.
    let f = Fixture::new()?;
    f.record(&vector("certificate"))?;
    f.install()?;
    f.record(&installed(&f, 8)?)?;
    assert!(f.record(&withdrawal(&f, 8)?).is_err());
    assert!(!f.store().control_inspect()?.halted);
    assert_eq!(f.record(&withdrawal(&f, 9)?)?, Outcome::ReviewRequired);

    // A released head is settled for every host.
    let f = Fixture::new()?;
    f.record(&vector("certificate"))?;
    f.install()?;
    f.acknowledge_installations()?;
    f.store().control_release()?;
    assert!(f.record(&withdrawal(&f, 9)?).is_err());
    assert!(!f.store().control_inspect()?.halted);
    assert_eq!(f.refusal()?, None);
    Ok(())
}

#[test]
fn evidence_answer_stops_at_its_budget() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("certificate"))?;
    let ids: Vec<Digest> = f.store().run(|db, _| Ok(journal::all(db)?.into_keys().collect()))?;
    assert_eq!(ids.len(), 5);
    let (all, snapshots) = f.store().control_evidence(&ids, usize::MAX)?;
    assert_eq!((all.len(), snapshots.len()), (5, 1));
    // A budget for exactly the first envelope and its membership snapshot.
    let one = all[0].0.canonical()?.len() * 2
        + serde_json::to_vec(snapshots.values().next().unwrap())?.len();
    let (first, snapshots) = f.store().control_evidence(&ids, one)?;
    assert_eq!((first.len(), snapshots.len()), (1, 1));
    assert_eq!(first[0].0.id()?, ids[0]);
    // An envelope that cannot fit alone is not served; smaller ones still are.
    let sizes = all
        .iter()
        .map(|(signed, _)| Ok(signed.canonical()?.len()))
        .collect::<anyhow::Result<Vec<_>>>()?;
    let largest = (0..sizes.len()).max_by_key(|i| sizes[*i]).unwrap();
    let snapshot = serde_json::to_vec(snapshots.values().next().unwrap())?.len();
    // Ask for the largest first: skipping it must not end the answer.
    let mut ordered = vec![ids[largest]];
    ordered.extend(ids.iter().filter(|id| **id != ids[largest]));
    let (rest, _) = f
        .store()
        .control_evidence(&ordered, sizes[largest] * 2 + snapshot - 1)?;
    assert!(!rest.is_empty());
    assert!(
        rest.iter()
            .all(|(signed, _)| signed.id().unwrap() != ids[largest])
    );
    assert!(f.store().control_evidence(&ids, 1)?.0.is_empty());
    let unknown = f.store().control_evidence(&[[9; 32]], usize::MAX)?;
    assert!(unknown.0.is_empty() && unknown.1.is_empty());
    Ok(())
}

fn react(f: &Fixture) -> anyhow::Result<Vec<Reaction>> {
    f.store().control_react(
        &f.identity(7)?,
        &["fixture-build-v1".to_owned()],
        &supported(),
    )
}

fn steps(reactions: &[Reaction]) -> Vec<(Step, bool)> {
    reactions
        .iter()
        .map(|r| (r.step, r.outcome.is_ok()))
        .collect()
}

#[test]
fn designated_host_prepares_and_installs_on_its_own() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.record(&vector("proposal"))?;
    assert!(react(&f)?.is_empty(), "no designation");
    f.store().control_designate(&Session {
        coordinator: session().coordinator,
        nonce: [9; 32],
    })?;
    assert!(react(&f)?.is_empty(), "designated for another session");
    f.store().control_designate(&session())?;

    let reactions = react(&f)?;
    assert_eq!(steps(&reactions), [(Step::Prepare, true)]);
    assert_eq!(reactions[0].subject, vector("proposal").id()?);
    let prepared = reactions.into_iter().next().unwrap().outcome?;
    let Body::Certificate(c) = vector("certificate").body else {
        unreachable!()
    };
    assert!(c.prepared.contains(&prepared));
    assert!(react(&f)?.is_empty(), "already prepared");

    f.record(&vector("certificate"))?;
    let reactions = react(&f)?;
    assert_eq!(steps(&reactions), [(Step::Install, true)]);
    assert_eq!(
        reactions.into_iter().next().unwrap().outcome?,
        vector("installed")
    );
    assert!(react(&f)?.is_empty(), "already installed");
    assert_eq!(f.store().control_inspect()?.epoch, 1);
    Ok(())
}

#[test]
fn host_does_not_react_unfrozen_halted_or_as_another_host() -> anyhow::Result<()> {
    let f = Fixture::unfrozen()?;
    f.store().control_designate(&session())?;
    f.record(&vector("proposal"))?;
    assert!(react(&f)?.is_empty(), "not frozen");

    // A profile this build does not implement is reported and locks nothing.
    let f = Fixture::new()?;
    f.store().control_designate(&session())?;
    f.record(&vector("proposal"))?;
    let reactions = f.store().control_react(
        &f.identity(7)?,
        &["fixture-build-v1".to_owned()],
        &BTreeSet::new(),
    )?;
    assert_eq!(steps(&reactions), [(Step::Prepare, false)]);
    assert!(f.store().control_inspect()?.prepare_locks.is_empty());
    // The journal records one host's grant; another identity is not that host.
    assert!(
        f.store()
            .control_react(
                &f.identity(8)?,
                &["fixture-build-v1".to_owned()],
                &supported()
            )?
            .is_empty()
    );

    let mut p = proposal(&vector("proposal"))?.clone();
    p.nonce = [0x99; 32];
    assert_eq!(
        f.record(&f.resign(Body::Proposal(Box::new(p)), 7)?)?,
        Outcome::ReviewRequired
    );
    assert!(react(&f)?.is_empty(), "halted for review");

    // Release ends the designation, so a later freeze alone answers nothing.
    let f = Fixture::new()?;
    f.store().control_designate(&session())?;
    f.record(&vector("proposal"))?;
    f.store().control_release()?;
    f.store().control_freeze()?;
    assert!(react(&f)?.is_empty(), "frozen again without a designation");
    Ok(())
}

#[test]
fn host_finishes_a_step_interrupted_before_its_signature() -> anyhow::Result<()> {
    let f = Fixture::new()?;
    f.store().control_designate(&session())?;
    f.record(&vector("proposal"))?;
    f.store()
        .run(|db, _| journal::lock_prepare(db, &root_prepared(), &session(), &supported()))?;
    assert_eq!(steps(&react(&f)?), [(Step::Prepare, true)]);
    assert!(
        f.store()
            .control_inspect()?
            .unsigned_preparations
            .is_empty()
    );

    f.record(&vector("certificate"))?;
    let id = vector("certificate").id()?;
    f.store()
        .run(|db, _| journal::install(db, &id, &session().coordinator, &session(), &supported()))?;
    let reactions = react(&f)?;
    assert_eq!(steps(&reactions), [(Step::Install, true)]);
    assert_eq!(
        reactions.into_iter().next().unwrap().outcome?,
        vector("installed")
    );
    assert!(react(&f)?.is_empty());
    Ok(())
}
