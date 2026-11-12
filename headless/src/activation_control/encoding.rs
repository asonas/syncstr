use super::*;
use anyhow::Context as _;

const PROPOSAL: &[u8] = b"syncstr-activation-proposal-v1\n";
const PREPARED: &[u8] = b"syncstr-activation-prepared-v1\n";
const CERTIFICATE: &[u8] = b"syncstr-activation-certificate-v1\n";
const INSTALLED: &[u8] = b"syncstr-activation-installed-v1\n";

pub(super) fn count(out: &mut Vec<u8>, size: usize) -> anyhow::Result<()> {
    out.extend(u32::try_from(size)?.to_be_bytes());
    Ok(())
}

pub(super) fn blob(out: &mut Vec<u8>, value: &[u8]) -> anyhow::Result<()> {
    ensure!(
        out.len()
            .checked_add(value.len())
            .is_some_and(|n| n <= MAX_BYTES - 4),
        "control encoding too large"
    );
    count(out, value.len())?;
    out.extend(value);
    Ok(())
}

fn host(out: &mut Vec<u8>, value: &Host) {
    out.extend(value.key);
    out.extend(value.grant);
}

fn ordered<T: Ord>(values: &[T], max: usize) -> anyhow::Result<()> {
    ensure!(
        values.len() <= max && values.windows(2).all(|v| v[0] < v[1]),
        "unordered, duplicate or oversized set"
    );
    Ok(())
}

fn texts(out: &mut Vec<u8>, values: &[String]) -> anyhow::Result<()> {
    ordered(values, 128)?;
    count(out, values.len())?;
    for value in values {
        ensure!(
            !value.is_empty()
                && value.len() <= 128
                && value.is_ascii()
                && !value.bytes().any(|b| b.is_ascii_control()),
            "invalid profile/implementation ID"
        );
        blob(out, value.as_bytes())?;
    }
    Ok(())
}

pub(super) fn encode(body: &Body) -> anyhow::Result<Vec<u8>> {
    let domain = match body {
        Body::Proposal(_) => PROPOSAL,
        Body::Prepared(_) => PREPARED,
        Body::Certificate(_) => CERTIFICATE,
        Body::Installed(_) => INSTALLED,
    };
    let mut out = domain.to_vec();
    out.push(1);
    match body {
        Body::Proposal(p) => {
            out.extend(p.cluster);
            out.extend(p.root);
            out.extend(p.baseline);
            match p.previous {
                None => out.push(0),
                Some(id) => {
                    out.push(1);
                    out.extend(id);
                }
            }
            out.extend(p.epoch.to_be_bytes());
            out.extend(p.membership);
            ordered(&p.hosts, 4096)?;
            ensure!(
                !p.hosts.is_empty()
                    && p.hosts.iter().map(|h| h.key).collect::<BTreeSet<_>>().len() <= MAX_HOSTS,
                "invalid host count"
            );
            count(&mut out, p.hosts.len())?;
            for h in &p.hosts {
                host(&mut out, h);
            }
            texts(&mut out, &p.profiles)?;
            out.extend(p.inventory);
            out.extend(p.backup);
            host(&mut out, &p.coordinator);
            out.extend(p.nonce);
        }
        Body::Prepared(a) => {
            out.extend(a.proposal);
            host(&mut out, &a.host);
            texts(&mut out, &a.implementations)?;
            texts(&mut out, &a.implemented_profiles)?;
            out.extend(a.input_history);
            out.extend(a.baseline);
            out.push(u8::from(a.write_frozen));
            out.push(u8::from(a.admission_frozen));
            texts(&mut out, &a.minimum_profiles)?;
        }
        Body::Certificate(c) => {
            ensure!(
                matches!(c.proposal.body, Body::Proposal(_)),
                "nested proposal kind"
            );
            blob(&mut out, &c.proposal.canonical()?)?;
            ensure!(c.prepared.len() <= MAX_HOSTS, "too many acknowledgments");
            count(&mut out, c.prepared.len())?;
            let mut previous = None;
            for signed in &c.prepared {
                let Body::Prepared(a) = &signed.body else {
                    anyhow::bail!("nested acknowledgment kind")
                };
                ensure!(
                    previous.is_none_or(|k| k < a.host.key),
                    "unordered prepared hosts"
                );
                previous = Some(a.host.key);
                blob(&mut out, &signed.canonical()?)?;
            }
            host(&mut out, &c.coordinator);
        }
        Body::Installed(i) => {
            out.extend(i.certificate);
            host(&mut out, &i.host);
            out.extend(i.epoch.to_be_bytes());
        }
    }
    ensure!(out.len() <= MAX_BYTES - 68, "control encoding too large");
    Ok(out)
}

struct Reader<'a>(&'a [u8]);
impl<'a> Reader<'a> {
    fn take(&mut self, size: usize) -> anyhow::Result<&'a [u8]> {
        ensure!(size <= self.0.len(), "truncated control envelope");
        let (head, tail) = self.0.split_at(size);
        self.0 = tail;
        Ok(head)
    }
    fn array<const N: usize>(&mut self) -> anyhow::Result<[u8; N]> {
        Ok(self.take(N)?.try_into()?)
    }
    fn byte(&mut self) -> anyhow::Result<u8> {
        Ok(self.array::<1>()?[0])
    }
    fn number(&mut self) -> anyhow::Result<u64> {
        Ok(u64::from_be_bytes(self.array()?))
    }
    fn count(&mut self, max: usize) -> anyhow::Result<usize> {
        let count = u32::from_be_bytes(self.array()?) as usize;
        ensure!(count <= max, "control count exceeds bound");
        Ok(count)
    }
    fn blob(&mut self, max: usize) -> anyhow::Result<&'a [u8]> {
        let count = self.count(max)?;
        self.take(count)
    }
    fn host(&mut self) -> anyhow::Result<Host> {
        Ok(Host {
            key: self.array()?,
            grant: self.array()?,
        })
    }
    fn texts(&mut self) -> anyhow::Result<Vec<String>> {
        let count = self.count(128)?;
        (0..count)
            .map(|_| Ok(std::str::from_utf8(self.blob(128)?)?.to_owned()))
            .collect()
    }
    fn flag(&mut self) -> anyhow::Result<bool> {
        match self.byte()? {
            0 => Ok(false),
            1 => Ok(true),
            _ => anyhow::bail!("invalid control flag"),
        }
    }
    fn done(&self) -> anyhow::Result<()> {
        ensure!(self.0.is_empty(), "trailing control bytes");
        Ok(())
    }
}

pub(super) fn decode(bytes: &[u8]) -> anyhow::Result<Signed> {
    decode_kind(bytes, None)
}

fn decode_kind(bytes: &[u8], expected: Option<&[u8]>) -> anyhow::Result<Signed> {
    ensure!(bytes.len() <= MAX_BYTES, "control envelope too large");
    let mut outer = Reader(bytes);
    let signing = outer.blob(MAX_BYTES)?;
    let signature = outer.array()?;
    outer.done()?;
    let domain = [PROPOSAL, PREPARED, CERTIFICATE, INSTALLED]
        .into_iter()
        .find(|d| signing.starts_with(d))
        .context("unknown control domain")?;
    ensure!(
        expected.is_none_or(|e| e == domain),
        "unexpected nested envelope"
    );
    let mut r = Reader(&signing[domain.len()..]);
    ensure!(r.byte()? == 1, "unsupported control version");
    let body = if domain == PROPOSAL {
        let cluster = r.array()?;
        let root = r.array()?;
        let baseline = r.array()?;
        let previous = if r.flag()? { Some(r.array()?) } else { None };
        let epoch = r.number()?;
        let membership = r.array()?;
        let count = r.count(4096)?;
        let hosts = (0..count)
            .map(|_| r.host())
            .collect::<anyhow::Result<_>>()?;
        Body::Proposal(Box::new(Proposal {
            cluster,
            root,
            baseline,
            previous,
            epoch,
            membership,
            hosts,
            profiles: r.texts()?,
            inventory: r.array()?,
            backup: r.array()?,
            coordinator: r.host()?,
            nonce: r.array()?,
        }))
    } else if domain == PREPARED {
        Body::Prepared(Prepared {
            proposal: r.array()?,
            host: r.host()?,
            implementations: r.texts()?,
            implemented_profiles: r.texts()?,
            input_history: r.array()?,
            baseline: r.array()?,
            write_frozen: r.flag()?,
            admission_frozen: r.flag()?,
            minimum_profiles: r.texts()?,
        })
    } else if domain == CERTIFICATE {
        let proposal = Box::new(decode_kind(r.blob(MAX_BYTES)?, Some(PROPOSAL))?);
        let count = r.count(MAX_HOSTS)?;
        let prepared = (0..count)
            .map(|_| decode_kind(r.blob(MAX_BYTES)?, Some(PREPARED)))
            .collect::<anyhow::Result<_>>()?;
        Body::Certificate(Certificate {
            proposal,
            prepared,
            coordinator: r.host()?,
        })
    } else {
        Body::Installed(Installed {
            certificate: r.array()?,
            host: r.host()?,
            epoch: r.number()?,
        })
    };
    r.done()?;
    let signed = Signed { body, signature };
    ensure!(
        signed.canonical()? == bytes,
        "noncanonical control envelope"
    );
    signed.verify()?;
    Ok(signed)
}
