pub(crate) fn migrate(connection: &rusqlite::Connection) -> anyhow::Result<()> {
    connection.execute_batch("CREATE TABLE IF NOT EXISTS cluster_receipts (object TEXT PRIMARY KEY, member TEXT NOT NULL, bytes INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS cluster_cursors (peer TEXT PRIMARY KEY, sequence INTEGER NOT NULL);")?;
    Ok(())
}

pub async fn verify_file(
    path: std::path::PathBuf,
    entry: crate::model::Entry,
) -> anyhow::Result<()> {
    entry.validate()?;
    tokio::task::spawn_blocking(move || {
        use sha2::Digest as _;
        use std::io::Read as _;
        let mut file = std::fs::File::open(path)?;
        anyhow::ensure!(
            file.metadata()?.len() == entry.track.size,
            "audio length mismatch"
        );
        let mut digest = sha2::Sha256::new();
        let mut bytes = 0u64;
        let mut buffer = [0; 65536];
        loop {
            let size = file.read(&mut buffer)?;
            if size == 0 {
                break;
            }
            bytes += size as u64;
            anyhow::ensure!(bytes <= entry.track.size, "audio grew during verification");
            digest.update(&buffer[..size]);
        }
        anyhow::ensure!(
            bytes == entry.track.size && hex::encode(digest.finalize()) == entry.sha256,
            "audio integrity mismatch"
        );
        Ok(())
    })
    .await?
}

fn selected(
    records: &[crate::cluster_changes::Change],
    object: &str,
) -> anyhow::Result<Option<crate::cluster_changes::Change>> {
    let heads = crate::cluster_changes::object_heads(records, object);
    anyhow::ensure!(heads.len() <= 1, "object conflict requires user resolution");
    let Some(mut selected) = heads.first().cloned() else {
        return Ok(None);
    };
    for _ in 0..=records.len() {
        match &selected.action {
            crate::cluster_changes::Action::Delete => return Ok(None),
            crate::cluster_changes::Action::Import { .. }
            | crate::cluster_changes::Action::Restore { .. }
            | crate::cluster_changes::Action::Edit { .. } => return Ok(Some(selected)),
            crate::cluster_changes::Action::Resolve { selected: id } => {
                selected = records
                    .iter()
                    .find(|record| record.id == *id)
                    .ok_or_else(|| anyhow::anyhow!("missing resolution parent"))?
                    .clone();
            }
        }
    }
    anyhow::bail!("cyclic object resolution")
}

impl crate::store::Store {
    pub async fn import_cluster_file(
        &self,
        identity: &crate::peer::Identity,
        mut entry: crate::model::Entry,
        organization: Option<crate::organization::Organization>,
        path: &std::path::Path,
        restore: bool,
    ) -> anyhow::Result<()> {
        self.local_cluster_grant(identity).await?;
        if entry.track.id.is_empty() {
            entry.track.id = uuid::Uuid::new_v4().to_string();
        }
        let temporary = self.stage().await?;
        tokio::fs::copy(path, temporary.path()).await?;
        crate::cluster_replica::verify_file(temporary.path().to_owned(), entry.clone()).await?;
        temporary.as_file().sync_all()?;
        let known = self
            .cluster_changes()
            .await?
            .iter()
            .any(|state| state.object == entry.sha256);
        let mut organization = organization;
        if known && !restore {
            let selected = self
                .cluster_selected_change(&entry.sha256)
                .await?
                .ok_or_else(|| anyhow::anyhow!("deleted object requires explicit restoration"))?;
            let (previous, metadata) = match &selected.action {
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
                } => (entry, organization),
                _ => unreachable!(),
            };
            let mut comparable = entry.clone();
            comparable.track.id = previous.track.id.clone();
            comparable.track.cover_art = previous.track.cover_art.clone();
            if comparable == **previous
                && organization
                    .as_ref()
                    .is_none_or(|incoming| incoming == metadata.as_ref())
            {
                return self
                    .commit_cluster_replica(identity, selected, temporary, None)
                    .await;
            }
            if organization.is_none() {
                entry.track.id = previous.track.id.clone();
                let mut updated = metadata.as_ref().clone();
                updated.import(&entry);
                let canonical = updated.canonical_track(&entry.track.id);
                if let Some(track) = updated
                    .tracks
                    .iter_mut()
                    .find(|track| track.id == canonical)
                {
                    track.title = Some(entry.track.title.clone());
                }
                organization = Some(updated);
            }
        }
        let mut metadata = organization.unwrap_or_else(|| {
            let mut metadata = crate::organization::Organization::default();
            metadata.import(&entry);
            metadata
        });
        metadata = metadata.for_object(&entry.sha256)?;
        let action = if restore {
            crate::cluster_changes::Action::Restore {
                entry: Box::new(entry.clone()),
                organization: Box::new(metadata),
            }
        } else if known {
            crate::cluster_changes::Action::Edit {
                entry: Box::new(entry.clone()),
                organization: Box::new(metadata),
            }
        } else {
            crate::cluster_changes::Action::Import {
                entry: Box::new(entry.clone()),
                organization: Box::new(metadata),
            }
        };
        let change = self
            .publish_cluster_change(identity, entry.sha256, action)
            .await?;
        self.commit_cluster_replica(identity, change, temporary, None)
            .await
    }

    pub async fn cluster_selected_change(
        &self,
        object: &str,
    ) -> anyhow::Result<Option<crate::cluster_changes::Change>> {
        let records = self.cluster_active_changes().await?;
        crate::cluster_replica::selected(&records, object)
    }

    pub async fn project_cluster_metadata(&self, object: String) -> anyhow::Result<()> {
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            let records = crate::cluster_changes::projected_records(&transaction)?;
            let Some(selected) = crate::cluster_replica::selected(&records, &object)? else {
                return Ok(());
            };
            let (entry, incoming) = match selected.action {
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
                } => (*entry, *organization),
                _ => unreachable!(),
            };
            let stored: Vec<crate::model::Entry> = {
                let mut statement =
                    transaction.prepare("SELECT payload FROM tracks WHERE sha256 = ?")?;
                statement
                    .query_map([&object], |row| row.get::<_, Vec<u8>>(0))?
                    .map(|row| Ok(serde_json::from_slice(&row?)?))
                    .collect::<anyhow::Result<_>>()?
            };
            if stored.is_empty() {
                return Ok(());
            }
            let mut organization = crate::store::read_organization(&transaction)?;
            organization.merge(&incoming)?;
            for previous in stored {
                let mut projected = entry.clone();
                projected.track.id = previous.track.id.clone();
                projected.track.suffix = previous.track.suffix;
                projected.track.cover_art = projected
                    .artwork
                    .as_ref()
                    .map(|_| previous.track.id.clone());
                let canonical = organization.canonical_track(&entry.track.id);
                if organization.canonical_track(&previous.track.id) != canonical
                    && organization
                        .tracks
                        .iter()
                        .any(|track| track.id == canonical)
                {
                    organization
                        .track_aliases
                        .get_or_insert_with(Default::default)
                        .insert(previous.track.id.clone(), canonical);
                }
                transaction.execute(
                    "UPDATE tracks SET payload = ? WHERE id = ?",
                    rusqlite::params![serde_json::to_vec(&projected)?, previous.track.id],
                )?;
            }
            organization.validate()?;
            transaction.execute(
                "UPDATE organization SET payload = ? WHERE singleton = 1",
                [serde_json::to_vec(&organization)?],
            )?;
            transaction.commit()?;
            Ok(())
        })
        .await
    }

    pub async fn cluster_local_file(
        &self,
        object: &str,
    ) -> anyhow::Result<Option<crate::model::Entry>> {
        if self.cluster_selected_change(object).await?.is_none() {
            return Ok(None);
        }
        let catalog = self.catalog().await?;
        for entry in catalog
            .entries
            .into_iter()
            .filter(|entry| entry.sha256 == object)
        {
            if crate::cluster_replica::verify_file(self.path(&entry), entry.clone())
                .await
                .is_ok()
            {
                return Ok(Some(entry));
            }
        }
        let object = object.to_owned();
        self.run(move |connection, _| {
            connection.execute("DELETE FROM cluster_receipts WHERE object = ?", [object])?;
            Ok(())
        })
        .await?;
        Ok(None)
    }

    pub async fn has_cluster_replica(&self, object: &str) -> anyhow::Result<bool> {
        let hash = object.to_owned();
        let receipted = self
            .run(move |connection, _| {
                Ok(connection.query_row(
                    "SELECT EXISTS(SELECT 1 FROM cluster_receipts WHERE object = ?)",
                    [hash],
                    |row| row.get::<_, bool>(0),
                )?)
            })
            .await?;
        if !receipted {
            return Ok(false);
        }
        for entry in self
            .catalog()
            .await?
            .entries
            .into_iter()
            .filter(|entry| entry.sha256 == object)
        {
            if tokio::fs::metadata(self.path(&entry))
                .await
                .is_ok_and(|metadata| metadata.is_file() && metadata.len() == entry.track.size)
            {
                return Ok(true);
            }
        }
        let hash = object.to_owned();
        self.run(move |connection, _| {
            connection.execute("DELETE FROM cluster_receipts WHERE object = ?", [hash])?;
            Ok(())
        })
        .await?;
        Ok(false)
    }

    pub async fn commit_cluster_replica(
        &self,
        identity: &crate::peer::Identity,
        change: crate::cluster_changes::Change,
        temporary: tempfile::NamedTempFile,
        job: Option<String>,
    ) -> anyhow::Result<()> {
        let (entry, organization) = match change.action {
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
            } => (*entry, *organization),
            _ => anyhow::bail!("change has no audio"),
        };
        anyhow::ensure!(
            self.cluster_selected_change(&entry.sha256)
                .await?
                .is_some_and(|selected| selected.id == change.id),
            "object changed during transfer"
        );
        crate::cluster_replica::verify_file(temporary.path().to_owned(), entry.clone()).await?;
        temporary.as_file().sync_all()?;
        let saved = self
            .commit_organized(entry, temporary, true, Some(organization))
            .await?;
        let member = identity.id().to_string();
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            let records = crate::cluster_changes::projected_records(&transaction)?;
            anyhow::ensure!(crate::cluster_replica::selected(&records, &saved.sha256)?.is_some_and(|selected| selected.id == change.id), "object changed before receipt commit");
            transaction.execute("INSERT INTO cluster_receipts VALUES (?, ?, ?) ON CONFLICT(object) DO UPDATE SET member = excluded.member, bytes = excluded.bytes", rusqlite::params![saved.sha256, member, saved.track.size as i64])?;
            if let Some(job) = job {
                let count = transaction.execute("UPDATE cluster_jobs SET state = 'complete' WHERE id = ? AND sha256 = ? AND destination = ? AND state = 'running'", rusqlite::params![job, saved.sha256, member])?;
                anyhow::ensure!(count == 1, "transfer job mismatch");
            }
            transaction.commit()?;
            Ok(())
        }).await
    }

    pub async fn cluster_receipts(&self) -> anyhow::Result<Vec<String>> {
        self.run(|connection, _| {
            let mut statement =
                connection.prepare("SELECT object FROM cluster_receipts ORDER BY object")?;
            Ok(statement
                .query_map([], |row| row.get(0))?
                .collect::<rusqlite::Result<_>>()?)
        })
        .await
    }

    pub async fn prepare_cluster_download(
        &self,
        source: String,
        destination: String,
        entry: crate::model::Entry,
    ) -> anyhow::Result<String> {
        entry.validate()?;
        let _: iroh::EndpointId = source.parse()?;
        let _: iroh::EndpointId = destination.parse()?;
        anyhow::ensure!(source != destination, "self transfer");
        self.run(move |connection, _| {
            use rusqlite::OptionalExtension as _;
            let transaction = connection.transaction()?;
            transaction.execute("INSERT OR IGNORE INTO cluster_objects VALUES (?, ?)", rusqlite::params![entry.sha256, entry.track.size as i64])?;
            let size: i64 = transaction.query_row("SELECT bytes FROM cluster_objects WHERE sha256 = ?", [&entry.sha256], |row| row.get(0))?;
            anyhow::ensure!(size as u64 == entry.track.size, "inconsistent object size");
            let previous: Option<String> = transaction.query_row("SELECT id FROM cluster_jobs WHERE sha256 = ? AND source = ? AND destination = ? AND state = 'queued' LIMIT 1", rusqlite::params![entry.sha256, source, destination], |row| row.get(0)).optional()?;
            let id = previous.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
            transaction.execute("INSERT OR IGNORE INTO cluster_jobs VALUES (?, ?, ?, ?, 'queued')", rusqlite::params![id, entry.sha256, source, destination])?;
            transaction.execute("UPDATE cluster_jobs SET state = 'running' WHERE id = ?", [&id])?;
            transaction.commit()?;
            Ok(id)
        }).await
    }

    pub async fn retry_cluster_download(&self, job: String) -> anyhow::Result<()> {
        self.run(move |connection, _| {
            connection.execute(
                "UPDATE cluster_jobs SET state = 'queued' WHERE id = ? AND state = 'running'",
                [job],
            )?;
            Ok(())
        })
        .await
    }

    pub async fn cluster_change_page(
        &self,
        after: i64,
    ) -> anyhow::Result<Option<(i64, crate::cluster_changes::Change)>> {
        anyhow::ensure!(after >= 0, "invalid history cursor");
        self.run(move |connection, _| {
            use rusqlite::OptionalExtension as _;
            let row: Option<(i64, Vec<u8>)> = connection.query_row("SELECT rowid, payload FROM cluster_changes WHERE rowid > ? ORDER BY rowid LIMIT 1", [after], |row| Ok((row.get(0)?,row.get(1)?))).optional()?;
            row.map(|(sequence, payload)| Ok((sequence, serde_json::from_slice(&payload)?))).transpose()
        }).await
    }
}
