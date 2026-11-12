//! Local signed activation evidence only. No transport, freeze or writer release.
use anyhow::ensure;
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use std::collections::BTreeSet;

mod encoding;
mod journal;
#[cfg(test)]
mod tests;

pub use journal::{Inspection, Outcome, Session};
pub type Digest = [u8; 32];
pub type Key = [u8; 32];
const MAX_BYTES: usize = 32 * 1024 * 1024;
const MAX_HOSTS: usize = 64;

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Host {
    pub key: Key,
    pub grant: Digest,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Proposal {
    pub cluster: [u8; 16],
    pub root: Key,
    pub baseline: Digest,
    pub previous: Option<Digest>,
    pub epoch: u64,
    pub membership: Digest,
    pub hosts: Vec<Host>,
    pub profiles: Vec<String>,
    pub inventory: Digest,
    pub backup: Digest,
    pub coordinator: Host,
    pub nonce: Digest,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Prepared {
    pub proposal: Digest,
    pub host: Host,
    pub implementations: Vec<String>,
    pub implemented_profiles: Vec<String>,
    pub input_history: Digest,
    pub baseline: Digest,
    pub write_frozen: bool,
    pub admission_frozen: bool,
    pub minimum_profiles: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Certificate {
    pub proposal: Box<Signed>,
    pub prepared: Vec<Signed>,
    pub coordinator: Host,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Installed {
    pub certificate: Digest,
    pub host: Host,
    pub epoch: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Body {
    Proposal(Box<Proposal>),
    Prepared(Prepared),
    Certificate(Certificate),
    Installed(Installed),
}

impl Body {
    pub fn signing_bytes(&self) -> anyhow::Result<Vec<u8>> {
        encoding::encode(self)
    }

    fn signer(&self) -> &Host {
        match self {
            Self::Proposal(p) => &p.coordinator,
            Self::Prepared(p) => &p.host,
            Self::Certificate(c) => &c.coordinator,
            Self::Installed(i) => &i.host,
        }
    }

    fn kind(&self) -> &'static str {
        match self {
            Self::Proposal(_) => "proposal",
            Self::Prepared(_) => "prepared",
            Self::Certificate(_) => "certificate",
            Self::Installed(_) => "installed",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Signed {
    pub body: Body,
    pub signature: [u8; 64],
}

impl Signed {
    pub fn sign(body: Body, identity: &crate::peer::Identity) -> anyhow::Result<Self> {
        let signature = identity.sign(&body.signing_bytes()?);
        let signed = Self {
            body,
            signature: signature
                .try_into()
                .map_err(|_| anyhow::anyhow!("invalid signature length"))?,
        };
        signed.verify()?;
        Ok(signed)
    }

    pub fn verify(&self) -> anyhow::Result<()> {
        let key = iroh::EndpointId::from_bytes(&self.body.signer().key)?;
        key.verify(
            &self.body.signing_bytes()?,
            &iroh::Signature::from_bytes(&self.signature),
        )?;
        if let Body::Certificate(c) = &self.body {
            ensure!(
                matches!(c.proposal.body, Body::Proposal(_)),
                "certificate proposal kind"
            );
            c.proposal.verify()?;
            for ack in &c.prepared {
                ensure!(
                    matches!(ack.body, Body::Prepared(_)),
                    "certificate acknowledgment kind"
                );
                ack.verify()?;
            }
        }
        Ok(())
    }

    pub fn canonical(&self) -> anyhow::Result<Vec<u8>> {
        let mut output = Vec::new();
        encoding::blob(&mut output, &self.body.signing_bytes()?)?;
        output.extend(self.signature);
        ensure!(output.len() <= MAX_BYTES, "control envelope too large");
        Ok(output)
    }

    pub fn decode(bytes: &[u8]) -> anyhow::Result<Self> {
        encoding::decode(bytes)
    }

    pub fn id(&self) -> anyhow::Result<Digest> {
        let mut hash = Sha256::new();
        hash.update(b"syncstr-activation-envelope-id-v1\n");
        hash.update(self.canonical()?);
        Ok(hash.finalize().into())
    }
}

pub(crate) fn digest(value: &str) -> anyhow::Result<Digest> {
    ensure!(
        value.len() == 64
            && value
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "noncanonical digest"
    );
    hex::decode(value)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("invalid digest"))
}

pub(crate) fn key(value: &str) -> anyhow::Result<Key> {
    Ok(*value.parse::<iroh::EndpointId>()?.as_bytes())
}

/// Hash exact existing membership signing inputs and signatures, never JSON order.
pub fn membership_revision(
    cluster: [u8; 16],
    proof: &crate::enrollment::Proof,
) -> anyhow::Result<(Digest, Vec<Host>)> {
    ensure!(
        proof.grants.len() <= 4096 && proof.revocations.len() <= 256,
        "membership proof too large"
    );
    let cluster_text = uuid::Uuid::from_bytes(cluster).to_string();
    let root = key(&proof.root)?;
    ensure!(
        proof.membership_conflicts()?.is_empty(),
        "disputed membership authority"
    );
    let mut ids = BTreeSet::new();
    let mut hosts = BTreeSet::new();
    let mut grants = Vec::new();
    for grant in &proof.grants {
        ensure!(grant.cluster == cluster_text, "wrong membership cluster");
        proof.chain(&grant.id)?;
        let id = digest(&grant.id)?;
        ensure!(ids.insert(id), "duplicate membership identity");
        if grant.host && proof.verify(&grant.id).is_ok() {
            hosts.insert(Host {
                key: key(&grant.member)?,
                grant: id,
            });
        }
        grants.push((id, grant.signing_bytes()?, hex::decode(&grant.signature)?));
    }
    let mut revocations = Vec::new();
    for revocation in &proof.revocations {
        ensure!(
            revocation.cluster == cluster_text,
            "wrong revocation cluster"
        );
        let id = digest(&revocation.id)?;
        ensure!(ids.insert(id), "duplicate membership identity");
        revocations.push((
            id,
            revocation.signing_bytes()?,
            hex::decode(&revocation.signature)?,
        ));
    }
    ensure!(
        !hosts.is_empty()
            && hosts.iter().map(|h| h.key).collect::<BTreeSet<_>>().len() <= MAX_HOSTS,
        "invalid authorized host count"
    );
    ensure!(
        proof
            .grants
            .iter()
            .any(|g| g.authority.is_none() && key(&g.member).ok() == Some(root)),
        "missing root grant"
    );
    let mut bytes = b"syncstr-activation-membership-v1\n".to_vec();
    bytes.push(1);
    bytes.extend(cluster);
    bytes.extend(root);
    for mut records in [grants, revocations] {
        records.sort_by_key(|r| r.0);
        encoding::count(&mut bytes, records.len())?;
        for (id, signing, signature) in records {
            ensure!(signature.len() == 64, "invalid membership signature");
            bytes.extend(id);
            encoding::blob(&mut bytes, &signing)?;
            bytes.extend(signature);
            ensure!(bytes.len() <= MAX_BYTES, "membership proof too large");
        }
    }
    Ok((Sha256::digest(&bytes).into(), hosts.into_iter().collect()))
}

fn proposal(signed: &Signed) -> anyhow::Result<&Proposal> {
    match &signed.body {
        Body::Proposal(p) => Ok(p),
        _ => anyhow::bail!("expected proposal"),
    }
}

fn certificate(signed: &Signed) -> anyhow::Result<&Certificate> {
    match &signed.body {
        Body::Certificate(c) => Ok(c),
        _ => anyhow::bail!("expected certificate"),
    }
}

fn verify_proposal(signed: &Signed, proof: &crate::enrollment::Proof) -> anyhow::Result<()> {
    signed.verify()?;
    let p = proposal(signed)?;
    let (revision, hosts) = membership_revision(p.cluster, proof)?;
    ensure!(
        p.root == key(&proof.root)? && p.membership == revision && p.hosts == hosts,
        "proposal membership mismatch"
    );
    ensure!(
        p.hosts.contains(&p.coordinator),
        "coordinator is not authorized"
    );
    ensure!(p.epoch > 0 && p.epoch <= i64::MAX as u64, "invalid epoch");
    Ok(())
}

fn verify_prepared(signed: &Signed, proposed: &Signed) -> anyhow::Result<()> {
    signed.verify()?;
    let p = proposal(proposed)?;
    let Body::Prepared(a) = &signed.body else {
        anyhow::bail!("expected prepared acknowledgment")
    };
    ensure!(
        a.proposal == proposed.id()? && p.hosts.contains(&a.host),
        "prepared proposal/host mismatch"
    );
    ensure!(
        a.baseline == p.baseline && a.write_frozen && a.admission_frozen,
        "prepared baseline/freeze mismatch"
    );
    ensure!(
        p.profiles.iter().all(|v| a.minimum_profiles.contains(v))
            && a.minimum_profiles
                .iter()
                .all(|v| a.implemented_profiles.contains(v)),
        "prepared profile floor mismatch"
    );
    ensure!(
        !a.implementations.is_empty(),
        "missing installed implementation evidence"
    );
    Ok(())
}

fn verify_certificate(signed: &Signed, proof: &crate::enrollment::Proof) -> anyhow::Result<()> {
    signed.verify()?;
    let c = certificate(signed)?;
    verify_proposal(&c.proposal, proof)?;
    let p = proposal(&c.proposal)?;
    ensure!(
        c.coordinator == p.coordinator,
        "certificate coordinator mismatch"
    );
    let expected: BTreeSet<_> = p.hosts.iter().map(|h| h.key).collect();
    let mut actual = BTreeSet::new();
    let mut history = None;
    for signed in &c.prepared {
        verify_prepared(signed, &c.proposal)?;
        let Body::Prepared(a) = &signed.body else {
            unreachable!()
        };
        ensure!(actual.insert(a.host.key), "duplicate prepared host");
        ensure!(
            history.is_none_or(|h| h == a.input_history),
            "input histories differ"
        );
        history = Some(a.input_history);
    }
    ensure!(actual == expected, "missing or extra prepared host");
    Ok(())
}
