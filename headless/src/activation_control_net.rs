//! Control protocol between hosts: each side authorizes the other as a host,
//! the server reports its control journal, and the client fetches the signed
//! envelopes it lacks. Nothing is signed in answer to a request.
use crate::activation_control::{Digest, Journal, Session as Designation, Signed, Summary};
use anyhow::Context as _;

pub const ALPN: &[u8] = b"syncstr/control/1";
const MAX_FETCH: usize = 32;
/// How the QUIC stack reports a peer that offers none of the requested protocols.
const NO_PROTOCOL: &str = "known protocol";
const MAX_HELLO: usize = 4 * 1024 * 1024;
/// An answer stops growing here; the client asks again for the rest.
const MAX_ANSWER: usize = 16 * 1024 * 1024;

/// The peer does not offer the control protocol.
#[derive(Debug)]
pub struct Unsupported;

impl std::fmt::Display for Unsupported {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("peer does not offer the control protocol")
    }
}

impl std::error::Error for Unsupported {}

/// Journal inspection verifies signatures and waits on the store; keep it off
/// the async workers.
async fn blocking<T: Send + 'static>(
    store: &crate::shared_audio::Store,
    work: impl FnOnce(&crate::shared_audio::Store) -> anyhow::Result<T> + Send + 'static,
) -> anyhow::Result<T> {
    let store = store.clone();
    tokio::task::spawn_blocking(move || work(&store)).await?
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Hello {
    pub version: u8,
    pub proof: crate::enrollment::Proof,
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Welcome {
    pub version: u8,
    pub proof: crate::enrollment::Proof,
    pub journal: Journal,
}

#[derive(Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "operation", rename_all = "kebab-case", deny_unknown_fields)]
pub enum Request {
    Fetch { envelopes: Vec<Digest> },
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fetched {
    pub envelopes: Vec<Envelope>,
    /// Membership snapshots the envelopes were verified under.
    pub memberships: Vec<crate::enrollment::Proof>,
}

#[derive(Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    /// Canonical signed bytes, hexadecimal.
    pub canonical: String,
    /// Index into `memberships`.
    pub membership: usize,
}

pub(crate) async fn serve_connection(
    connection: iroh::endpoint::Connection,
    store: crate::shared_audio::Store,
    signer: std::sync::Arc<crate::peer::Identity>,
) -> anyhow::Result<()> {
    let own = signer.id().to_string();
    let peer = connection.remote_id().to_string();
    let (mut output, mut input) = connection.accept_bi().await?;
    let hello: Hello = crate::cluster_net::receive(&mut input, MAX_HELLO).await?;
    anyhow::ensure!(hello.version == 1, "unsupported control protocol version");
    let (presenter, host) = (peer.clone(), own.clone());
    let proof = blocking(&store, move |store| {
        store.merge_membership_from(hello.proof, Some((&presenter, &host)), false)
    })
    .await?;
    crate::shared_audio_net::authorize(&proof, &peer, true)?;
    let journal = blocking(&store, |store| store.control_journal()).await?;
    crate::cluster_net::send(
        &mut output,
        &Welcome {
            version: 1,
            proof,
            journal,
        },
    )
    .await?;
    output.finish()?;
    while let Ok((mut output, mut input)) = connection.accept_bi().await {
        let request: Request = crate::cluster_net::receive(&mut input, 64 * 1024).await?;
        let proof = store.membership()?;
        crate::shared_audio_net::authorize(&proof, &peer, true)?;
        crate::shared_audio_net::authorize(&proof, &own, true)?;
        match request {
            Request::Fetch { envelopes } => {
                anyhow::ensure!(envelopes.len() <= MAX_FETCH, "control fetch too large");
                let (found, snapshots) = blocking(&store, move |store| {
                    store.control_evidence(&envelopes, MAX_ANSWER)
                })
                .await?;
                let revisions: Vec<Digest> = snapshots.keys().copied().collect();
                let mut reply = Fetched {
                    envelopes: Vec::new(),
                    memberships: snapshots.into_values().collect(),
                };
                for (signed, revision) in found {
                    reply.envelopes.push(Envelope {
                        canonical: hex::encode(signed.canonical()?),
                        membership: revisions
                            .iter()
                            .position(|r| *r == revision)
                            .context("membership snapshot missing")?,
                    });
                }
                crate::cluster_net::send(&mut output, &reply).await?;
            }
        }
        output.finish()?;
    }
    Ok(())
}

/// What decided the last refusal of an envelope. It is fetched again only
/// after this host's journal changed.
type Seen = (
    u64,
    Option<Digest>,
    bool,
    Option<Designation>,
    Option<Digest>,
    usize,
);

fn seen(summary: &Summary) -> Seen {
    (
        summary.epoch,
        summary.head,
        summary.frozen,
        summary.session.clone(),
        summary.membership,
        summary.envelopes.len(),
    )
}

/// Envelopes this host refused, so that a peer's unusable record is not
/// fetched on every synchronization tick.
#[derive(Default)]
pub struct Refused(std::collections::BTreeMap<Digest, Seen>);

pub struct Session {
    connection: iroh::endpoint::Connection,
    /// The peer's journal when the session opened.
    pub journal: Journal,
}

impl Session {
    /// Fails with `Unsupported` when the peer does not offer the control
    /// protocol, and otherwise when the exchange fails or the two hosts do not
    /// authorize each other.
    pub async fn connect(
        endpoint: &iroh::Endpoint,
        address: iroh::EndpointAddr,
        store: &crate::shared_audio::Store,
    ) -> anyhow::Result<Self> {
        let peer = address.id.to_string();
        let connection = match tokio::time::timeout(
            std::time::Duration::from_secs(10),
            endpoint.connect(address, ALPN),
        )
        .await?
        {
            Ok(connection) => connection,
            // TLS alert 120, no_application_protocol: the peer listens but
            // does not offer this protocol. Anything else is not that answer.
            Err(error) if format!("{error:?}").contains(NO_PROTOCOL) => {
                return Err(Unsupported.into());
            }
            Err(error) => return Err(error.into()),
        };
        let (mut output, mut input) = connection.open_bi().await?;
        crate::cluster_net::send(
            &mut output,
            &Hello {
                version: 1,
                proof: store.membership()?,
            },
        )
        .await?;
        output.finish()?;
        let welcome: Welcome = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            crate::cluster_net::receive(&mut input, MAX_HELLO),
        )
        .await??;
        anyhow::ensure!(welcome.version == 1, "unsupported control protocol version");
        blocking(store, move |store| store.merge_membership(welcome.proof)).await?;
        let proof = store.membership()?;
        crate::shared_audio_net::authorize(&proof, &peer, true)?;
        crate::shared_audio_net::authorize(&proof, &endpoint.id().to_string(), true)?;
        Ok(Self {
            connection,
            journal: welcome.journal,
        })
    }

    async fn fetch(&self, envelopes: &[Digest]) -> anyhow::Result<Fetched> {
        let (mut output, mut input) = self.connection.open_bi().await?;
        crate::cluster_net::send(
            &mut output,
            &Request::Fetch {
                envelopes: envelopes.to_vec(),
            },
        )
        .await?;
        output.finish()?;
        tokio::time::timeout(
            std::time::Duration::from_secs(30),
            crate::cluster_net::receive(&mut input, crate::cluster_net::MAX_FRAME),
        )
        .await?
    }

    /// Take in the envelopes the peer holds and this host lacks. Returns how
    /// many were stored. A host without a designated session, or with a
    /// journal that is absent, unreadable or halted, takes in nothing.
    pub async fn pull(
        &self,
        store: &crate::shared_audio::Store,
        refused: &mut Refused,
    ) -> anyhow::Result<usize> {
        let Journal::Readable { summary: remote } = &self.journal else {
            return Ok(0);
        };
        let Journal::Readable { summary: local } =
            blocking(store, |store| store.control_journal()).await?
        else {
            return Ok(0);
        };
        if local.halted || local.session.is_none() {
            return Ok(0);
        }
        let before = seen(&local);
        let missing: Vec<Digest> = remote
            .envelopes
            .iter()
            .filter(|id| !local.envelopes.contains(id) && refused.0.get(*id) != Some(&before))
            .copied()
            .collect();
        let mut evidence = Vec::new();
        for chunk in missing.chunks(MAX_FETCH) {
            let fetched = self.fetch(chunk).await?;
            for envelope in fetched.envelopes {
                let signed = Signed::decode(&hex::decode(&envelope.canonical)?)?;
                anyhow::ensure!(
                    chunk.contains(&signed.id()?),
                    "unrequested control envelope"
                );
                let membership = fetched
                    .memberships
                    .get(envelope.membership)
                    .context("membership snapshot missing")?
                    .clone();
                evidence.push((signed, membership));
            }
        }
        let outcomes = blocking(store, move |store| store.control_accept(evidence)).await?;
        let Journal::Readable { summary: local } =
            blocking(store, |store| store.control_journal()).await?
        else {
            return Ok(0);
        };
        let after = seen(&local);
        let mut stored = 0;
        for (id, outcome) in outcomes {
            match outcome {
                Ok(_) => stored += 1,
                // Whatever was refused may become acceptable once the journal moves.
                Err(_) if after == before => {
                    refused.0.insert(id, after.clone());
                }
                Err(_) => {}
            }
        }
        Ok(stored)
    }
}

/// Data flows only between hosts whose control journals agree: both without
/// one, or both readable, not halted, at the same installed head. A peer
/// without a journal is acceptable only until this host has a head or
/// anything pending.
fn gate(local: &Journal, remote: &Journal) -> anyhow::Result<()> {
    let Journal::Readable { summary: local } = local else {
        anyhow::bail!("control journal requires review");
    };
    anyhow::ensure!(!local.halted, "control journal is halted for review");
    match remote {
        Journal::Readable { summary } => {
            anyhow::ensure!(
                !summary.halted,
                "peer control journal is halted for review"
            );
            anyhow::ensure!(
                summary.head == local.head,
                "peer is at another activation epoch"
            );
        }
        Journal::Unreadable => anyhow::bail!("peer control journal requires review"),
        Journal::Absent => anyhow::ensure!(
            local.head.is_none() && !local.pending,
            "peer has no control journal"
        ),
    }
    Ok(())
}

/// A host that pushes records cannot show its journal on the data protocol,
/// so a push is accepted only where a peer without a journal would be.
pub(crate) fn admit_push(store: &crate::shared_audio::Store) -> anyhow::Result<()> {
    match store.control_journal()? {
        Journal::Absent => Ok(()),
        local => gate(&local, &Journal::Absent),
    }
}

/// Synchronize control records with a host peer, then data if the journals
/// agree. A host that never initialized control storage reconciles as before.
pub async fn reconcile(
    endpoint: &iroh::Endpoint,
    store: &crate::shared_audio::Store,
    address: iroh::EndpointAddr,
    refused: &mut Refused,
) -> anyhow::Result<()> {
    let peer = address.id.to_string();
    if blocking(store, |store| store.control_journal()).await? != Journal::Absent {
        let remote = match Session::connect(endpoint, address.clone(), store).await {
            Ok(session) => {
                session.pull(store, refused).await?;
                session.journal
            }
            // Only a peer that does not offer the protocol counts as having no
            // journal. After any other failure its journal is unknown.
            Err(error) if error.is::<Unsupported>() => Journal::Absent,
            Err(error) => return Err(error.context("control exchange failed; data deferred")),
        };
        gate(&blocking(store, |store| store.control_journal()).await?, &remote)?;
    }
    let session =
        crate::shared_audio_net::Session::connect(endpoint, address, store.membership()?).await?;
    session.reconcile(store, &peer).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn summary(head: Option<Digest>, pending: bool) -> Journal {
        Journal::Readable {
            summary: Box::new(Summary {
                epoch: u64::from(head.is_some()),
                head,
                frozen: pending,
                released: false,
                halted: false,
                pending,
                session: None,
                membership: None,
                input_history: [3; 32],
                envelopes: vec![],
            }),
        }
    }

    #[test]
    fn data_needs_agreeing_journals() {
        let none = summary(None, false);
        let pending = summary(None, true);
        let one = summary(Some([1; 32]), false);
        let two = summary(Some([2; 32]), false);
        assert!(gate(&none, &none).is_ok());
        assert!(gate(&one, &one).is_ok());
        assert!(gate(&pending, &none).is_ok());
        assert!(gate(&one, &two).is_err());
        assert!(gate(&none, &one).is_err());
        assert!(gate(&one, &none).is_err());
        // A peer without a journal is acceptable only before any activation.
        assert!(gate(&none, &Journal::Absent).is_ok());
        assert!(gate(&pending, &Journal::Absent).is_err());
        assert!(gate(&one, &Journal::Absent).is_err());
        assert!(gate(&none, &Journal::Unreadable).is_err());
        assert!(gate(&Journal::Unreadable, &none).is_err());
        // A halted journal on either side waits for review.
        let mut halted = summary(Some([1; 32]), false);
        if let Journal::Readable { summary } = &mut halted {
            summary.halted = true;
        }
        assert!(gate(&halted, &one).is_err());
        assert!(gate(&one, &halted).is_err());
    }

    #[test]
    fn a_corrected_designation_retries_refused_envelopes() {
        let designated = |key: u8| {
            let Journal::Readable { mut summary } = summary(None, true) else {
                unreachable!()
            };
            summary.session = Some(Designation {
                coordinator: crate::activation_control::Host {
                    key: [key; 32],
                    grant: [5; 32],
                },
                nonce: [6; 32],
            });
            seen(&summary)
        };
        assert_eq!(designated(1), designated(1));
        // The same nonce under another coordinator is another session.
        assert_ne!(designated(1), designated(2));
    }

    #[test]
    fn wire_shapes() -> anyhow::Result<()> {
        let digits = |n: u8| vec![n.to_string(); 32].join(",");
        let request = format!(r#"{{"operation":"fetch","envelopes":[[{}]]}}"#, digits(7));
        assert_eq!(
            serde_json::to_string(&Request::Fetch {
                envelopes: vec![[7; 32]]
            })?,
            request
        );
        assert_eq!(
            serde_json::from_str::<Request>(&request)?,
            Request::Fetch {
                envelopes: vec![[7; 32]]
            }
        );
        assert!(serde_json::from_str::<Request>(r#"{"operation":"prepare"}"#).is_err());
        assert_eq!(
            serde_json::to_string(&Journal::Absent)?,
            r#"{"state":"absent"}"#
        );
        assert_eq!(
            serde_json::to_string(&Journal::Unreadable)?,
            r#"{"state":"unreadable"}"#
        );
        let readable = format!(
            concat!(
                r#"{{"state":"readable","summary":{{"epoch":1,"head":[{}],"frozen":false,"#,
                r#""released":false,"halted":false,"pending":false,"session":null,"#,
                r#""membership":null,"input_history":[{}],"envelopes":[]}}}}"#
            ),
            digits(1),
            digits(3)
        );
        assert_eq!(
            serde_json::to_string(&summary(Some([1; 32]), false))?,
            readable
        );
        assert_eq!(
            serde_json::from_str::<Journal>(&readable)?,
            summary(Some([1; 32]), false)
        );
        assert_eq!(
            serde_json::to_string(&Envelope {
                canonical: "00ff".into(),
                membership: 0
            })?,
            r#"{"canonical":"00ff","membership":0}"#
        );
        Ok(())
    }
}
