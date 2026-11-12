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
    let issuer_key = f.identity(issuer)?.id().to_string();
    let authority = member_proof()
        .grants
        .into_iter()
        .find(|g| g.member == issuer_key)
        .unwrap();
    let mut grant = crate::enrollment::Grant {
        version: 1,
        id: String::new(),
        cluster: authority.cluster,
        issuer: issuer_key,
        member,
        host,
        authority: Some(authority.id),
        signature: String::new(),
    };
    grant.id = hex::encode(Sha256::digest(grant.signing_bytes()?));
    grant.signature = hex::encode(f.identity(issuer)?.sign(&grant.signing_bytes()?));
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
    for i in 0..(4096 - local.grants.len()) as u32 {
        let mut secret = [0u8; 32];
        secret[..4].copy_from_slice(&i.to_le_bytes());
        secret[31] = 0xa5;
        let member = iroh::SecretKey::from_bytes(&secret).public().to_string();
        let grant = issue(&f, 7, member, false)?;
        store_grant(&f, &grant)?;
        local.grants.push(grant);
    }
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
