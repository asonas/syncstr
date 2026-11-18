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
    pub async fn recover_cluster_evidence(&self, identity: &crate::peer::Identity, object: &str) -> anyhow::Result<bool> {
        let records = self.cluster_active_changes().await?;
        if crate::cluster_changes::object_heads(&records, object).len() != 1 { return Ok(false); }
        let Some(selected) = self.cluster_selected_change(object).await? else { return Ok(false); };
        let (mut entry, mut organization) = match selected.action {
            crate::cluster_changes::Action::Import { entry, organization }
            | crate::cluster_changes::Action::Edit { entry, organization }
            | crate::cluster_changes::Action::Restore { entry, organization } => (*entry, *organization),
            _ => return Ok(false),
        };
        if !organization.tracks.iter().any(|track| track.sha256 == object && track.imported.tag_values.is_none()) { return Ok(false); }
        let Some(local) = self.cluster_local_file(object).await? else { return Ok(false); };
        let path = self.path(&local);
        let values = tokio::task::spawn_blocking(move || -> anyhow::Result<std::collections::BTreeMap<String, Vec<String>>> {
            use lofty::file::TaggedFileExt as _;
            lofty::config::apply_global_options(lofty::config::GlobalOptions::new().allocation_limit(crate::model::MAX_METADATA));
            let tagged = lofty::probe::Probe::open(path)?.guess_file_type()?.options(
                lofty::config::ParseOptions::new().read_properties(false).read_cover_art(false)
                    .parsing_mode(lofty::config::ParsingMode::BestAttempt)
            ).read()?;
            let mut values = std::collections::BTreeMap::new();
            for (name, key) in [("TITLE", lofty::tag::ItemKey::TrackTitle), ("ALBUM", lofty::tag::ItemKey::AlbumTitle), ("ARTIST", lofty::tag::ItemKey::TrackArtist),
                ("ALBUMARTIST", lofty::tag::ItemKey::AlbumArtist), ("COMPILATION", lofty::tag::ItemKey::FlagCompilation),
                ("MUSICBRAINZ_ALBUMID", lofty::tag::ItemKey::MusicBrainzReleaseId), ("DISCNUMBER", lofty::tag::ItemKey::DiscNumber),
                ("TRACKNUMBER", lofty::tag::ItemKey::TrackNumber)] {
                let items: Vec<_> = tagged.tags().iter().flat_map(|tag| tag.get_strings(key)).map(str::to_owned).collect();
                if !items.is_empty() { values.insert(name.to_owned(), items); }
            }
            anyhow::ensure!(serde_json::to_vec(&values)?.len() <= crate::model::MAX_METADATA, "embedded metadata too large");
            Ok(values)
        }).await?;
        let Ok(values) = values else { return Ok(false); };
        if crate::cluster_replica::verify_file(self.path(&local), local).await.is_err() { return Ok(false); }
        let first = |key: &str| values.get(key).and_then(|items| items.first()).cloned();
        let releases: std::collections::BTreeSet<_> = values.get("MUSICBRAINZ_ALBUMID").into_iter().flatten()
            .filter_map(|value| uuid::Uuid::parse_str(value).ok()).map(|id| id.to_string()).collect();
        let imported = crate::organization::Imported {
            title: first("ALBUM"), artist: first("ARTIST"), album_artist: first("ALBUMARTIST"),
            compilation_values: values.get("COMPILATION").cloned().unwrap_or_default(),
            release: (releases.len() == 1 && values.get("MUSICBRAINZ_ALBUMID").into_iter().flatten().all(|value| uuid::Uuid::parse_str(value).is_ok()))
                .then(|| crate::organization::Release { source: "musicbrainz-release".into(), value: releases.first().unwrap().clone() }),
            tag_values: Some(values.clone()),
        };
        let number = |key: &str| first(key).and_then(|value| value.split('/').next()?.parse::<i64>().ok());
        entry.imported_album = Some(imported.clone());
        entry.track.disc_number = entry.track.disc_number.or_else(|| number("DISCNUMBER"));
        entry.track.track = entry.track.track.or_else(|| number("TRACKNUMBER"));
        for track in &mut organization.tracks {
            if track.sha256 == object && track.imported.tag_values.is_none() {
                track.imported = imported.clone();
                track.disc_number = track.disc_number.or(entry.track.disc_number);
                track.track_number = track.track_number.or(entry.track.track);
            }
        }
        for album in &mut organization.albums {
            let titles: Vec<_> = organization.tracks.iter().filter(|track| track.imported_album_id == album.id)
                .filter_map(|track| track.imported.title.as_deref()).collect();
            if let Some(title) = titles.first().filter(|title| !title.is_empty() && titles.iter().all(|other| other == *title)) {
                album.title = (*title).to_owned();
            }
        }
        organization.repair_membership()?;
        self.publish_observed_cluster_change(identity, object.to_owned(), crate::cluster_changes::Action::Edit {
            entry: Box::new(entry), organization: Box::new(organization),
        }, vec![selected.id]).await?;
        self.project_cluster_metadata(object.to_owned()).await?;
        Ok(true)
    }

    pub async fn reconcile_cluster_organization(&self, identity: &crate::peer::Identity) -> anyhow::Result<()> {
        let records = self.cluster_active_changes().await?;
        let objects: std::collections::BTreeSet<_> = records.iter().map(|record| record.object.clone()).collect();
        for object in objects {
            let heads = crate::cluster_changes::object_heads(&records, &object);
            if heads.len() < 2 || heads.len() > 64 { continue; }
            let mut entry = None;
            let mut baseline = None;
            let mut merged = crate::organization::Organization::default();
            let mut compatible = true;
            for head in &heads {
                let (incoming_entry, organization) = match &head.action {
                    crate::cluster_changes::Action::Import { entry, organization }
                    | crate::cluster_changes::Action::Edit { entry, organization } => (entry, organization),
                    _ => { compatible = false; break; }
                };
                let mut metadata = organization.as_ref().clone();
                metadata.artwork = None;
                metadata.choices.clear();
                metadata.preferred.clear();
                if entry.as_ref().is_some_and(|entry| entry != incoming_entry)
                    || baseline.as_ref().is_some_and(|baseline| baseline != &metadata) {
                    compatible = false; break;
                }
                entry = Some(incoming_entry.clone());
                baseline = Some(metadata);
                if merged.merge(organization).is_err() { compatible = false; break; }
            }
            if compatible {
                self.publish_observed_cluster_change(identity, object, crate::cluster_changes::Action::Edit {
                    entry: entry.expect("nonempty heads"), organization: Box::new(merged),
                }, heads.into_iter().map(|head| head.id).collect()).await?;
            }
        }
        Ok(())
    }

    pub async fn receive_cluster_metadata(
        &self,
        identity: &crate::peer::Identity,
        mut entry: crate::model::Entry,
        organization: crate::organization::Organization,
        parents: Vec<String>,
    ) -> anyhow::Result<String> {
        entry.validate()?;
        let organization = organization.for_object(&entry.sha256)?;
        let records = self.cluster_active_changes().await?;
        entry.track.added_at = original_addition_time(&records, &entry.sha256);
        anyhow::ensure!(!parents.is_empty() && parents.len() <= 64, "metadata needs observed object history");
        for id in &parents {
            let mut parent = records.iter().find(|record| record.id == *id && record.object == entry.sha256)
                .ok_or_else(|| anyhow::anyhow!("unknown metadata parent"))?;
            for _ in 0..records.len() {
                let crate::cluster_changes::Action::Resolve { selected } = &parent.action else { break; };
                parent = records.iter().find(|record| record.id == *selected)
                    .ok_or_else(|| anyhow::anyhow!("unknown metadata history"))?;
            }
            anyhow::ensure!(!matches!(parent.action, crate::cluster_changes::Action::Delete), "metadata cannot restore a deletion");
        }
        let action = crate::cluster_changes::Action::Edit { entry: Box::new(entry.clone()), organization: Box::new(organization) };
        if let Some(existing) = records.iter().find(|record| record.object == entry.sha256 && record.parents == parents && record.action == action) {
            return Ok(existing.id.clone());
        }
        Ok(self.publish_observed_cluster_change(identity, entry.sha256, action, parents).await?.id)
    }

    pub async fn resolve_cluster_album_title(
        &self,
        identity: &crate::peer::Identity,
        album: &str,
        title: &str,
        observed: std::collections::BTreeMap<String, String>,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(!observed.is_empty() && observed.len() <= 1024, "invalid album resolution size");
        let records = self.cluster_active_changes().await?;
        let mut organization = self.catalog().await?.organization;
        let mut selected = Vec::new();
        for object in observed.keys() {
            let change = crate::cluster_replica::selected(&records, object)?
                .ok_or_else(|| anyhow::anyhow!("album object was deleted"))?;
            let metadata = match &change.action {
                crate::cluster_changes::Action::Import { organization, .. }
                | crate::cluster_changes::Action::Edit { organization, .. }
                | crate::cluster_changes::Action::Restore { organization, .. } => organization,
                _ => unreachable!(),
            };
            organization.merge(metadata)?;
            selected.push(change);
        }
        let album = organization.canonical(album)?.to_owned();
        let mut alternatives = std::collections::BTreeSet::new();
        let mut updates = Vec::new();
        for change in selected {
            let heads = crate::cluster_changes::object_heads(&records, &change.object);
            anyhow::ensure!(heads.len() == 1 && observed.get(&change.object) == Some(&heads[0].id), "album changed; refresh before resolving");
            let (entry, mut metadata) = match change.action {
                crate::cluster_changes::Action::Import { entry, organization }
                | crate::cluster_changes::Action::Edit { entry, organization }
                | crate::cluster_changes::Action::Restore { entry, organization } => (entry, organization),
                _ => unreachable!(),
            };
            let mut affected = false;
            for item in &mut metadata.albums {
                if organization.canonical(&item.id)? == album {
                    alternatives.insert(item.title.clone());
                    item.title = title.to_owned();
                    affected = true;
                }
            }
            anyhow::ensure!(affected, "object does not belong to this album");
            updates.push((change.object, entry, metadata, vec![heads[0].id.clone()]));
        }
        anyhow::ensure!(alternatives.contains(title), "select an observed album title");
        for (object, entry, organization, parents) in updates {
            self.publish_observed_cluster_change(identity, object, crate::cluster_changes::Action::Edit { entry, organization }, parents).await?;
        }
        Ok(())
    }

    pub async fn receive_cluster_import(
        &self,
        identity: &crate::peer::Identity,
        mut entry: crate::model::Entry,
        organization: crate::organization::Organization,
        parents: Vec<String>,
        restore: bool,
        temporary: tempfile::NamedTempFile,
    ) -> anyhow::Result<()> {
        crate::cluster_replica::verify_file(temporary.path().to_owned(), entry.clone()).await?;
        let organization = organization.for_object(&entry.sha256)?;
        let records = self.cluster_active_changes().await?;
        // Addition time belongs to the library host, not the uploading device.
        entry.track.added_at = original_addition_time(&records, &entry.sha256);
        if !records.iter().any(|record| record.object == entry.sha256) {
            entry.track.added_at = Some(crate::model::addition_time());
        }
        anyhow::ensure!(parents.len() <= 64, "too many import parents");
        let mut observed_deletion = false;
        for id in &parents {
            let mut parent = records.iter().find(|record| record.id == *id && record.object == entry.sha256)
                .ok_or_else(|| anyhow::anyhow!("unknown import history"))?;
            for _ in 0..records.len() {
                let crate::cluster_changes::Action::Resolve { selected } = &parent.action else { break; };
                parent = records.iter().find(|record| record.id == *selected && record.object == entry.sha256)
                    .ok_or_else(|| anyhow::anyhow!("unknown resolution history"))?;
            }
            observed_deletion |= matches!(parent.action, crate::cluster_changes::Action::Delete);
        }
        anyhow::ensure!(restore == observed_deletion, "restoration requires explicit confirmation and observed deletion");
        if let Ok(Some(selected)) = self.cluster_selected_change(&entry.sha256).await
            && let crate::cluster_changes::Action::Import { entry: previous, organization: metadata }
                | crate::cluster_changes::Action::Edit { entry: previous, organization: metadata }
                | crate::cluster_changes::Action::Restore { entry: previous, organization: metadata } = &selected.action {
                let mut comparable = entry.clone();
                comparable.track.id = previous.track.id.clone();
                comparable.track.cover_art = previous.track.cover_art.clone();
                if comparable == **previous && organization == **metadata {
                    return self.commit_cluster_replica(identity, selected, temporary, None).await;
                }
        }
        let known = records.iter().any(|record| record.object == entry.sha256);
        anyhow::ensure!(!known || !parents.is_empty(), "refresh before editing an existing object");
        let action = if restore {
            crate::cluster_changes::Action::Restore { entry: Box::new(entry.clone()), organization: Box::new(organization) }
        } else if known {
            crate::cluster_changes::Action::Edit { entry: Box::new(entry.clone()), organization: Box::new(organization) }
        } else {
            crate::cluster_changes::Action::Import { entry: Box::new(entry.clone()), organization: Box::new(organization) }
        };
        let change = self.publish_observed_cluster_change(identity, entry.sha256.clone(), action, parents).await?;
        self.commit_cluster_replica(identity, change, temporary, None).await
    }

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
        entry.track.added_at = if known {
            original_addition_time(&self.cluster_changes().await?, &entry.sha256)
        } else { Some(crate::model::addition_time()) };
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
                let mut organization = crate::store::read_organization(&transaction)?;
                organization.exclude_objects(&std::collections::BTreeSet::from([object.clone()]))?;
                transaction.execute("DELETE FROM tracks WHERE sha256 = ?", [&object])?;
                transaction.execute("DELETE FROM cluster_receipts WHERE object = ?", [&object])?;
                transaction.execute("UPDATE organization SET payload = ? WHERE singleton = 1", [serde_json::to_vec(&organization)?])?;
                transaction.commit()?;
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
            let mut organization = crate::store::read_organization(&transaction)?;
            organization.merge(&incoming)?;
            for album in &incoming.albums {
                let canonical = organization.canonical(&album.id)?.to_owned();
                let objects: std::collections::BTreeSet<_> = records
                    .iter()
                    .map(|record| record.object.as_str())
                    .collect();
                for other in objects {
                    if other == object {
                        continue;
                    }
                    'heads: for mut candidate in
                        crate::cluster_changes::object_heads(&records, other)
                    {
                        while let crate::cluster_changes::Action::Resolve { selected } =
                            &candidate.action
                        {
                            let Some(parent) = records.iter().find(|record| record.id == *selected)
                            else {
                                continue 'heads;
                            };
                            candidate = parent.clone();
                        }
                        let metadata = match &candidate.action {
                            crate::cluster_changes::Action::Import { organization, .. }
                            | crate::cluster_changes::Action::Restore { organization, .. }
                            | crate::cluster_changes::Action::Edit { organization, .. } => {
                                organization
                            }
                            _ => continue,
                        };
                        for other_album in &metadata.albums {
                            if organization.canonical(&other_album.id)? == canonical
                                && other_album.title != album.title {
                                return Err(crate::cluster_replica::AlbumMetadataConflict(canonical.clone()).into());
                            }
                        }
                    }
                }
                if let Some(existing) = organization
                    .albums
                    .iter_mut()
                    .find(|existing| existing.id == canonical)
                {
                    existing.title = album.title.clone();
                }
            }
            let stored = if stored.is_empty() { vec![entry.clone()] } else { stored };
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
                    "INSERT INTO tracks (id, sha256, suffix, payload) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                    rusqlite::params![previous.track.id, projected.sha256, projected.track.suffix, serde_json::to_vec(&projected)?],
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
        let object = saved.sha256.clone();
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
        }).await?;
        self.project_cluster_metadata(object).await
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
#[derive(Debug)]
pub struct AlbumMetadataConflict(pub String);

impl std::fmt::Display for crate::cluster_replica::AlbumMetadataConflict {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "album metadata conflict requires user resolution: {}", self.0)
    }
}

impl std::error::Error for crate::cluster_replica::AlbumMetadataConflict {}

fn original_addition_time(records: &[crate::cluster_changes::Change], object: &str) -> Option<i64> {
    records.iter().filter(|record| record.object == object).filter_map(|record| {
        match &record.action {
            crate::cluster_changes::Action::Import { entry, .. }
            | crate::cluster_changes::Action::Restore { entry, .. }
            | crate::cluster_changes::Action::Edit { entry, .. } => entry.track.added_at,
            _ => None,
        }
    }).min()
}
