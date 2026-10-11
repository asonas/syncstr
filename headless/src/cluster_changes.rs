pub const MAX_CHANGE: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
pub enum Action {
    Import {
        entry: Box<crate::model::Entry>,
        organization: Box<crate::organization::Organization>,
    },
    Delete,
    Restore {
        entry: Box<crate::model::Entry>,
        organization: Box<crate::organization::Organization>,
    },
    Edit {
        entry: Box<crate::model::Entry>,
        organization: Box<crate::organization::Organization>,
    },
    Resolve {
        selected: String,
    },
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Change {
    pub version: u8,
    pub id: String,
    pub cluster: String,
    pub author: String,
    pub grant: String,
    pub previous: Vec<String>,
    pub object: String,
    pub parents: Vec<String>,
    pub action: crate::cluster_changes::Action,
    pub signature: String,
}

impl crate::cluster_changes::Change {
    pub fn signing_bytes(&self) -> anyhow::Result<Vec<u8>> {
        Ok(format!(
            "syncstr-cluster-change-v1\n{}",
            serde_json::to_string(&(
                self.version,
                &self.cluster,
                &self.author,
                &self.grant,
                &self.previous,
                &self.object,
                &self.parents,
                &self.action,
            ))?
        )
        .into_bytes())
    }

    fn validate(&self, proof: &crate::enrollment::Proof) -> anyhow::Result<()> {
        use sha2::Digest as _;
        anyhow::ensure!(
            self.version == 1
                && self.object.len() == 64
                && self
                    .object
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "invalid cluster object"
        );
        anyhow::ensure!(
            self.id == hex::encode(sha2::Sha256::digest(self.signing_bytes()?)),
            "change content identity mismatch"
        );
        let chain = proof.chain(&self.grant)?;
        let grant = chain[0];
        anyhow::ensure!(
            grant.member == self.author && grant.cluster == self.cluster && grant.host,
            "change author is not a library host"
        );
        for parents in [&self.parents, &self.previous] {
            anyhow::ensure!(parents.len() <= 64, "too many revision parents");
            let mut seen = std::collections::HashSet::new();
            for parent in parents {
                anyhow::ensure!(
                    parent.len() == 64 && hex::decode(parent)?.len() == 32,
                    "invalid revision identity"
                );
                anyhow::ensure!(
                    parent != &self.id && seen.insert(parent),
                    "invalid revision parent"
                );
            }
        }
        let bytes = self.signing_bytes()?;
        anyhow::ensure!(
            bytes.len() <= crate::cluster_changes::MAX_CHANGE,
            "change exceeds metadata limit"
        );
        let signature: [u8; 64] = hex::decode(&self.signature)?
            .try_into()
            .map_err(|_| anyhow::anyhow!("invalid change signature"))?;
        self.author
            .parse::<iroh::EndpointId>()?
            .verify(&bytes, &iroh::Signature::from_bytes(&signature))?;
        match &self.action {
            crate::cluster_changes::Action::Import {
                entry,
                organization,
            }
            | crate::cluster_changes::Action::Restore {
                entry,
                organization,
            }
            | crate::cluster_changes::Action::Edit {
                entry,
                organization,
            } => {
                entry.validate()?;
                organization.validate()?;
                anyhow::ensure!(
                    organization
                        .tracks
                        .iter()
                        .all(|track| track.sha256 == self.object),
                    "unrelated object metadata"
                );
                anyhow::ensure!(
                    entry.sha256 == self.object && !entry.track.id.is_empty(),
                    "object metadata mismatch"
                );
            }
            crate::cluster_changes::Action::Delete => {}
            crate::cluster_changes::Action::Resolve { selected } => {
                anyhow::ensure!(
                    self.parents.contains(selected),
                    "resolution must choose a competing head"
                );
            }
        }
        Ok(())
    }

    fn authorized(
        &self,
        proof: &crate::enrollment::Proof,
        records: &[crate::cluster_changes::Change],
    ) -> anyhow::Result<bool> {
        if proof.verify(&self.grant).is_ok() {
            return Ok(true);
        }
        let (active, disputed) = proof.revocation_state()?;
        if disputed.contains(&self.author) {
            return Ok(false);
        }
        let boundaries: Vec<_> = active
            .into_iter()
            .map(|index| &proof.revocations[index])
            .filter(|record| record.member == self.author)
            .collect();
        if boundaries.is_empty() {
            return Ok(false);
        }
        let by_id: std::collections::HashMap<_, _> = records
            .iter()
            .map(|record| (record.id.as_str(), record))
            .collect();
        for boundary in boundaries {
            let mut pending: Vec<_> = boundary.change_heads.iter().map(String::as_str).collect();
            let mut visited = std::collections::HashSet::new();
            let mut observed = false;
            while let Some(id) = pending.pop() {
                if !visited.insert(id) {
                    continue;
                }
                if id == self.id {
                    observed = true;
                    break;
                }
                if let Some(record) = by_id.get(id)
                    && record.author == self.author
                {
                    pending.extend(record.previous.iter().map(String::as_str));
                }
            }
            if !observed {
                return Ok(false);
            }
        }
        Ok(true)
    }
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct ObjectState {
    pub object: String,
    pub heads: Vec<crate::cluster_changes::Change>,
}

impl crate::cluster_changes::ObjectState {
    pub fn conflicted(&self) -> bool {
        self.heads.len() > 1
    }
}

pub(crate) fn migrate(connection: &rusqlite::Connection) -> anyhow::Result<()> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS cluster_changes (
        id TEXT PRIMARY KEY, author TEXT NOT NULL, object TEXT NOT NULL, payload BLOB NOT NULL);
        CREATE INDEX IF NOT EXISTS cluster_changes_object ON cluster_changes(object);
        CREATE INDEX IF NOT EXISTS cluster_changes_author ON cluster_changes(author);",
    )?;
    connection.execute_batch("CREATE TABLE IF NOT EXISTS cluster_change_inbox (id TEXT PRIMARY KEY, payload BLOB NOT NULL);")?;
    Ok(())
}

pub(crate) fn records(
    connection: &rusqlite::Connection,
) -> anyhow::Result<Vec<crate::cluster_changes::Change>> {
    let mut statement = connection.prepare("SELECT payload FROM cluster_changes ORDER BY rowid")?;
    statement
        .query_map([], |row| row.get::<_, Vec<u8>>(0))?
        .map(|row| Ok(serde_json::from_slice(&row?)?))
        .collect()
}

pub(crate) fn object_heads(
    records: &[crate::cluster_changes::Change],
    object: &str,
) -> Vec<crate::cluster_changes::Change> {
    let superseded: std::collections::HashSet<_> =
        records.iter().flat_map(|record| &record.parents).collect();
    let explicit_change = records.iter().any(|record| {
        record.object == object
            && !matches!(record.action, crate::cluster_changes::Action::Import { .. })
    });
    let mut heads: Vec<_> = records
        .iter()
        .filter(|record| {
            record.object == object
                && !superseded.contains(&record.id)
                && !(explicit_change
                    && matches!(record.action, crate::cluster_changes::Action::Import { .. }))
        })
        .cloned()
        .collect();
    heads.sort_by(|a, b| a.id.cmp(&b.id));
    heads
}

pub(crate) fn projected_records(
    connection: &rusqlite::Connection,
) -> anyhow::Result<Vec<crate::cluster_changes::Change>> {
    let records = crate::cluster_changes::records(connection)?;
    let proof = crate::enrollment::read_proof(connection)?;
    records
        .iter()
        .filter_map(|record| match record.authorized(&proof, &records) {
            Ok(true) => Some(Ok(record.clone())),
            Ok(false) => None,
            Err(error) => Some(Err(error)),
        })
        .collect()
}

fn insert(
    connection: &rusqlite::Connection,
    record: &crate::cluster_changes::Change,
) -> anyhow::Result<()> {
    use rusqlite::OptionalExtension as _;
    let payload = serde_json::to_vec(record)?;
    let existing: Option<Vec<u8>> = connection
        .query_row(
            "SELECT payload FROM cluster_changes WHERE id = ?",
            [&record.id],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(existing) = existing {
        anyhow::ensure!(existing == payload, "inconsistent change replay");
        return Ok(());
    }
    for parent in &record.parents {
        let object: String = connection.query_row(
            "SELECT object FROM cluster_changes WHERE id = ?",
            [parent],
            |row| row.get(0),
        )?;
        anyhow::ensure!(object == record.object, "cross-object parent");
    }
    for previous in &record.previous {
        let author: String = connection.query_row(
            "SELECT author FROM cluster_changes WHERE id = ?",
            [previous],
            |row| row.get(0),
        )?;
        anyhow::ensure!(author == record.author, "cross-author history");
    }
    connection.execute(
        "INSERT INTO cluster_changes VALUES (?, ?, ?, ?)",
        rusqlite::params![record.id, record.author, record.object, payload],
    )?;
    Ok(())
}

impl crate::store::Store {
    pub async fn cluster_changes(&self) -> anyhow::Result<Vec<crate::cluster_changes::Change>> {
        self.run(|connection, _| crate::cluster_changes::records(connection))
            .await
    }

    pub async fn cluster_active_changes(
        &self,
    ) -> anyhow::Result<Vec<crate::cluster_changes::Change>> {
        self.run(|connection, _| crate::cluster_changes::projected_records(connection))
            .await
    }

    pub async fn cluster_object_states(
        &self,
    ) -> anyhow::Result<Vec<crate::cluster_changes::ObjectState>> {
        let records = self.cluster_active_changes().await?;
        let objects: std::collections::BTreeSet<_> =
            records.iter().map(|record| &record.object).collect();
        Ok(objects
            .into_iter()
            .map(|object| crate::cluster_changes::ObjectState {
                object: object.clone(),
                heads: crate::cluster_changes::object_heads(&records, object),
            })
            .collect())
    }

    pub async fn publish_cluster_change(
        &self,
        identity: &crate::peer::Identity,
        object: String,
        action: crate::cluster_changes::Action,
    ) -> anyhow::Result<crate::cluster_changes::Change> {
        self.local_cluster_grant(identity).await?;
        let heads =
            crate::cluster_changes::object_heads(&self.cluster_active_changes().await?, &object);
        if matches!(action, crate::cluster_changes::Action::Import { .. }) {
            anyhow::ensure!(
                heads.is_empty(),
                "object already known; explicit restoration or resolution required"
            );
        }
        self.publish_observed_cluster_change(identity, object, action, heads.into_iter().map(|record| record.id).collect()).await
    }

    pub async fn publish_observed_cluster_change(
        &self,
        identity: &crate::peer::Identity,
        object: String,
        action: crate::cluster_changes::Action,
        parents: Vec<String>,
    ) -> anyhow::Result<crate::cluster_changes::Change> {
        use sha2::Digest as _;
        let authority = self.local_cluster_grant(identity).await?;
        let proof = self.cluster_membership_proof().await?;
        let records = self.cluster_changes().await?;
        let superseded: std::collections::HashSet<_> =
            records.iter().flat_map(|record| &record.previous).collect();
        let previous: Vec<_> = records
            .iter()
            .filter(|record| record.author == authority.member && !superseded.contains(&record.id))
            .map(|record| record.id.clone())
            .collect();
        let mut record = crate::cluster_changes::Change {
            version: 1,
            id: String::new(),
            cluster: authority.cluster,
            author: authority.member,
            grant: authority.id,
            previous,
            object,
            parents,
            action,
            signature: String::new(),
        };
        record.id = hex::encode(sha2::Sha256::digest(record.signing_bytes()?));
        record.signature = hex::encode(identity.sign(&record.signing_bytes()?));
        record.validate(&proof)?;
        self.apply_cluster_changes(identity.id().to_string(), vec![record.clone()])
            .await?;
        Ok(record)
    }

    pub async fn apply_cluster_changes(
        &self,
        presenter: String,
        changes: Vec<crate::cluster_changes::Change>,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(changes.len() <= 64, "change batch too large");
        self.run(move |connection, _| {
            use rusqlite::OptionalExtension as _;
            let transaction = connection.transaction()?;
            let proof = crate::enrollment::read_proof(&transaction)?;
            anyhow::ensure!(
                proof.grants.iter().any(|grant| grant.member == presenter
                    && grant.host
                    && proof.verify(&grant.id).is_ok()),
                "presenter is not an authorized library host"
            );
            let cluster: String = transaction.query_row(
                "SELECT id FROM cluster_identity WHERE singleton = 1",
                [],
                |row| row.get(0),
            )?;
            for record in changes {
                anyhow::ensure!(record.cluster == cluster, "cross-cluster change");
                let existing: Option<Vec<u8>> = transaction
                    .query_row(
                        "SELECT payload FROM cluster_changes WHERE id = ?",
                        [&record.id],
                        |row| row.get(0),
                    )
                    .optional()?;
                if let Some(existing) = existing {
                    anyhow::ensure!(
                        existing == serde_json::to_vec(&record)?,
                        "inconsistent change replay"
                    );
                    continue;
                }
                record.validate(&proof)?;
                let known = crate::cluster_changes::records(&transaction)?;
                anyhow::ensure!(
                    record.authorized(&proof, &known)?,
                    "change outside authorization boundary"
                );
                crate::cluster_changes::insert(&transaction, &record)?;
            }
            transaction.commit()?;
            Ok(())
        })
        .await
    }

    /// Unresolved ancestry stays durable but does not enter the library projection.
    pub async fn receive_cluster_changes(
        &self,
        presenter: String,
        changes: Vec<crate::cluster_changes::Change>,
    ) -> anyhow::Result<usize> {
        anyhow::ensure!(changes.len() <= 64, "change batch too large");
        self.run(move |connection, _| {
            use rusqlite::OptionalExtension as _;
            let transaction = connection.transaction()?;
            let proof = crate::enrollment::read_proof(&transaction)?;
            anyhow::ensure!(
                proof.grants.iter().any(|grant| grant.member == presenter
                    && grant.host
                    && proof.verify(&grant.id).is_ok()),
                "presenter is not an authorized library host"
            );
            let mut accepted = crate::cluster_changes::records(&transaction)?;
            for record in changes {
                anyhow::ensure!(
                    record.cluster == proof.grants[0].cluster,
                    "cross-cluster change"
                );
                if let Some(existing) = accepted.iter().find(|existing| existing.id == record.id) {
                    anyhow::ensure!(*existing == record, "inconsistent change replay");
                    continue;
                }
                record.validate(&proof)?;
                let payload = serde_json::to_vec(&record)?;
                let existing: Option<Vec<u8>> = transaction
                    .query_row(
                        "SELECT payload FROM cluster_change_inbox WHERE id = ?",
                        [&record.id],
                        |row| row.get(0),
                    )
                    .optional()?;
                if let Some(existing) = existing {
                    anyhow::ensure!(existing == payload, "inconsistent pending replay");
                } else {
                    transaction.execute(
                        "INSERT INTO cluster_change_inbox VALUES (?, ?)",
                        rusqlite::params![record.id, payload],
                    )?;
                }
            }
            let bytes: i64 = transaction.query_row(
                "SELECT COALESCE(SUM(length(payload)), 0) FROM cluster_change_inbox",
                [],
                |row| row.get(0),
            )?;
            anyhow::ensure!(
                bytes <= 128 * 1024 * 1024,
                "pending history exceeds storage limit"
            );
            let mut pending: Vec<crate::cluster_changes::Change> = {
                let mut statement = transaction
                    .prepare("SELECT payload FROM cluster_change_inbox ORDER BY rowid")?;
                statement
                    .query_map([], |row| row.get::<_, Vec<u8>>(0))?
                    .map(|row| Ok(serde_json::from_slice(&row?)?))
                    .collect::<anyhow::Result<_>>()?
            };
            let mut all = accepted.clone();
            all.extend(pending.iter().cloned());
            loop {
                let before = pending.len();
                let mut deferred = Vec::new();
                for record in pending {
                    let ready = record.parents.iter().all(|id| {
                        accepted
                            .iter()
                            .any(|parent| parent.id == *id && parent.object == record.object)
                    }) && record.previous.iter().all(|id| {
                        accepted
                            .iter()
                            .any(|parent| parent.id == *id && parent.author == record.author)
                    });
                    if ready && record.authorized(&proof, &all)? {
                        crate::cluster_changes::insert(&transaction, &record)?;
                        transaction.execute(
                            "DELETE FROM cluster_change_inbox WHERE id = ?",
                            [&record.id],
                        )?;
                        accepted.push(record);
                    } else {
                        deferred.push(record);
                    }
                }
                pending = deferred;
                if pending.len() == before {
                    break;
                }
            }
            transaction.commit()?;
            Ok(pending.len())
        })
        .await
    }
}
