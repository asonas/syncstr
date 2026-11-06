pub const MAX_DOCUMENT: usize = 8 * 1024 * 1024;
const PREFIX: &str = "syncstr-playlist-v1\n";

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Item {
    pub id: String,
    pub source_track: String,
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub track_id: Option<String>,
    pub sha256: Option<String>,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Document {
    pub id: String,
    pub source_library: String,
    pub source_playlist: String,
    pub source_fingerprint: String,
    pub name: String,
    pub kind: String,
    pub parent: Option<String>,
    pub definition: std::collections::BTreeMap<String, String>,
    pub items: Vec<crate::playlists::Item>,
}

impl crate::playlists::Document {
    pub fn validate(&self) -> anyhow::Result<()> {
        let identity = |value: &str| {
            !value.is_empty() && value.len() <= 256 && !value.chars().any(char::is_control)
        };
        anyhow::ensure!(
            identity(&self.source_library)
                && identity(&self.source_playlist)
                && !self.source_library.contains(':')
                && !self.source_playlist.contains(':')
                && self.id == format!("{}:{}", self.source_library, self.source_playlist),
            "invalid playlist identity"
        );
        anyhow::ensure!(
            self.source_fingerprint.len() == 64
                && self
                    .source_fingerprint
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                && hex::decode(&self.source_fingerprint)?.len() == 32,
            "invalid source fingerprint"
        );
        anyhow::ensure!(
            matches!(self.kind.as_str(), "folder" | "manual" | "snapshot")
                && !self.name.trim().is_empty()
                && self.name.len() <= 4096
                && self.items.len() <= 100_000,
            "invalid playlist"
        );
        anyhow::ensure!(
            self.parent
                .as_ref()
                .is_none_or(|p| identity(p) && p != &self.id),
            "invalid playlist parent"
        );
        anyhow::ensure!(
            self.kind != "folder" || self.items.is_empty(),
            "folder contains tracks"
        );
        let mut ids = std::collections::HashSet::new();
        for item in &self.items {
            anyhow::ensure!(
                identity(&item.id)
                    && identity(&item.source_track)
                    && ids.insert(&item.id)
                    && item.title.len() <= 4096
                    && item.artist.as_ref().is_none_or(|s| s.len() <= 4096)
                    && item.album.as_ref().is_none_or(|s| s.len() <= 4096),
                "invalid playlist occurrence"
            );
            anyhow::ensure!(
                item.track_id.is_some() == item.sha256.is_some(),
                "incomplete track reference"
            );
            if let (Some(track), Some(hash)) = (&item.track_id, &item.sha256) {
                anyhow::ensure!(
                    identity(track)
                        && hash.len() == 64
                        && hash
                            .bytes()
                            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                        && hex::decode(hash)?.len() == 32,
                    "invalid track reference"
                );
            }
        }
        anyhow::ensure!(
            serde_json::to_vec(self)?.len() <= crate::playlists::MAX_DOCUMENT,
            "playlist too large"
        );
        Ok(())
    }
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Body {
    pub version: u8,
    pub cluster: String,
    pub author: String,
    pub grant: String,
    pub document: crate::playlists::Document,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub parents: Vec<String>,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Signed {
    pub id: String,
    pub payload: String,
    pub signature: String,
}

impl crate::playlists::Signed {
    pub fn decode(
        &self,
        proof: &crate::enrollment::Proof,
    ) -> anyhow::Result<crate::playlists::Body> {
        use sha2::Digest as _;
        anyhow::ensure!(
            self.payload.len() <= crate::playlists::MAX_DOCUMENT + 4096,
            "playlist record too large"
        );
        let json = self
            .payload
            .strip_prefix(crate::playlists::PREFIX)
            .ok_or_else(|| anyhow::anyhow!("invalid playlist payload"))?;
        let body: crate::playlists::Body = serde_json::from_str(json)?;
        anyhow::ensure!(
            ((body.version == 1 && body.parents.is_empty())
                || (body.version == 2 && !body.parents.is_empty()))
                && self.id == hex::encode(sha2::Sha256::digest(self.payload.as_bytes())),
            "invalid playlist record identity"
        );
        let grant = proof.verify(&body.grant)?;
        anyhow::ensure!(
            grant.host && grant.cluster == body.cluster && grant.member == body.author,
            "unauthorized playlist author"
        );
        let signature: [u8; 64] = hex::decode(&self.signature)?
            .try_into()
            .map_err(|_| anyhow::anyhow!("invalid signature"))?;
        body.author.parse::<iroh::EndpointId>()?.verify(
            self.payload.as_bytes(),
            &iroh::Signature::from_bytes(&signature),
        )?;
        body.document.validate()?;
        Ok(body)
    }
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub struct Snapshot {
    pub document: crate::playlists::Document,
    pub revisions: Vec<String>,
}

pub fn project(
    records: &[crate::playlists::Signed],
    proof: &crate::enrollment::Proof,
) -> anyhow::Result<std::collections::BTreeMap<String, crate::playlists::Snapshot>> {
    let bodies = records
        .iter()
        .map(|record| Ok((record.id.clone(), record.decode(proof)?)))
        .collect::<anyhow::Result<std::collections::BTreeMap<_, _>>>()?;
    let mut superseded = std::collections::HashSet::new();
    for body in bodies.values() {
        for parent in &body.parents {
            let previous = bodies
                .get(parent)
                .ok_or_else(|| anyhow::anyhow!("incomplete playlist history"))?;
            anyhow::ensure!(
                previous.cluster == body.cluster && previous.document.id == body.document.id,
                "invalid playlist revision parent"
            );
            anyhow::ensure!(
                crate::playlists::reconciled(&body.document, &previous.document)? == body.document,
                "invalid playlist revision"
            );
            superseded.insert(parent);
        }
    }
    let mut result: std::collections::BTreeMap<String, crate::playlists::Snapshot> =
        std::collections::BTreeMap::new();
    for (id, body) in &bodies {
        if superseded.contains(id) {
            continue;
        }
        let snapshot =
            result
                .entry(body.document.id.clone())
                .or_insert_with(|| crate::playlists::Snapshot {
                    document: body.document.clone(),
                    revisions: Vec::new(),
                });
        anyhow::ensure!(
            snapshot.document == body.document,
            "playlist conflict requires resolution"
        );
        snapshot.revisions.push(id.clone());
    }
    Ok(result)
}

pub(crate) fn reconciled(
    incoming: &crate::playlists::Document,
    previous: &crate::playlists::Document,
) -> anyhow::Result<crate::playlists::Document> {
    let mut structure = incoming.clone();
    let mut merged = incoming.clone();
    anyhow::ensure!(
        incoming.items.len() == previous.items.len(),
        "playlist source changed; use the original XML"
    );
    for ((item, original), result) in structure
        .items
        .iter_mut()
        .zip(&previous.items)
        .zip(&mut merged.items)
    {
        item.track_id.clone_from(&original.track_id);
        item.sha256.clone_from(&original.sha256);
        if result.track_id.is_none() {
            result.track_id.clone_from(&original.track_id);
            result.sha256.clone_from(&original.sha256);
        }
    }
    anyhow::ensure!(
        structure == *previous,
        "playlist source changed; use the original XML"
    );
    Ok(merged)
}

pub(crate) fn migrate(connection: &rusqlite::Connection) -> anyhow::Result<()> {
    connection.execute_batch("CREATE TABLE IF NOT EXISTS playlist_records (id TEXT PRIMARY KEY, playlist_id TEXT NOT NULL, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS playlist_cursors (peer TEXT PRIMARY KEY, sequence INTEGER NOT NULL);")?;
    Ok(())
}

fn records(connection: &rusqlite::Connection) -> anyhow::Result<Vec<crate::playlists::Signed>> {
    let mut statement =
        connection.prepare("SELECT payload FROM playlist_records ORDER BY rowid")?;
    statement
        .query_map([], |row| row.get::<_, Vec<u8>>(0))?
        .map(|row| Ok(serde_json::from_slice(&row?)?))
        .collect()
}

impl crate::store::Store {
    pub async fn playlist_records(&self) -> anyhow::Result<Vec<crate::playlists::Signed>> {
        self.run(|connection, _| crate::playlists::records(connection))
            .await
    }

    pub async fn import_playlists(
        &self,
        identity: &crate::peer::Identity,
        cluster: String,
        documents: Vec<crate::playlists::Document>,
    ) -> anyhow::Result<usize> {
        self.save_playlists(identity, cluster, documents, None)
            .await
    }

    pub async fn reconcile_playlists(
        &self,
        identity: &crate::peer::Identity,
        cluster: String,
        documents: Vec<crate::playlists::Document>,
        expected: std::collections::BTreeMap<String, Vec<String>>,
    ) -> anyhow::Result<usize> {
        self.save_playlists(identity, cluster, documents, Some(expected))
            .await
    }

    async fn save_playlists(
        &self,
        identity: &crate::peer::Identity,
        cluster: String,
        documents: Vec<crate::playlists::Document>,
        expected: Option<std::collections::BTreeMap<String, Vec<String>>>,
    ) -> anyhow::Result<usize> {
        use sha2::Digest as _;
        anyhow::ensure!(
            !documents.is_empty() && documents.len() <= 1000,
            "invalid selection size"
        );
        let authority = self.local_cluster_grant(identity).await?;
        anyhow::ensure!(cluster == authority.cluster, "wrong destination library");
        let records = self.playlist_records().await?;
        let proof = self.cluster_membership_proof().await?;
        if let Some(expected) = &expected {
            anyhow::ensure!(
                expected.len() == documents.len(),
                "invalid playlist preview"
            );
        }
        let mut signed = Vec::new();
        for mut document in documents {
            document.validate()?;
            let parents = match &expected {
                Some(expected) => expected
                    .get(&document.id)
                    .ok_or_else(|| anyhow::anyhow!("missing playlist preview"))?
                    .clone(),
                None => Vec::new(),
            };
            anyhow::ensure!(
                parents.windows(2).all(|pair| pair[0] < pair[1]),
                "invalid playlist preview"
            );
            for parent in &parents {
                let previous = records
                    .iter()
                    .find(|record| &record.id == parent)
                    .ok_or_else(|| {
                        anyhow::anyhow!("playlist preview is stale; refresh the preview")
                    })?
                    .decode(&proof)?;
                anyhow::ensure!(previous.cluster == cluster, "wrong playlist library");
                document = crate::playlists::reconciled(&document, &previous.document)?;
            }
            let body = crate::playlists::Body {
                version: if parents.is_empty() { 1 } else { 2 },
                cluster: cluster.clone(),
                author: authority.member.clone(),
                grant: authority.id.clone(),
                document,
                parents,
            };
            let payload = format!(
                "{}{}",
                crate::playlists::PREFIX,
                serde_json::to_string(&body)?
            );
            signed.push(crate::playlists::Signed {
                id: hex::encode(sha2::Sha256::digest(payload.as_bytes())),
                signature: hex::encode(identity.sign(payload.as_bytes())),
                payload,
            });
        }
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            let proof = crate::enrollment::read_proof(&transaction)?;
            let records = crate::playlists::records(&transaction)?;
            let snapshots = crate::playlists::project(&records, &proof)?;
            let existing: std::collections::BTreeMap<_, _> = snapshots.iter().map(|(id, snapshot)| (id.clone(), snapshot.document.clone())).collect();
            let mut incoming = std::collections::BTreeMap::new();
            for record in &signed {
                let body = record.decode(&proof)?;
                if expected.is_some() && !records.iter().any(|saved| saved.id == record.id) {
                    let current = snapshots.get(&body.document.id).map(|snapshot| snapshot.revisions.as_slice()).unwrap_or_default();
                    anyhow::ensure!(current == body.parents, "playlist preview is stale; refresh the preview");
                }
                anyhow::ensure!(incoming.insert(body.document.id.clone(), body.document).is_none(), "duplicate playlist selection");
            }
            let organization = crate::store::read_organization(&transaction)?;
            let mut audio = std::collections::HashSet::new();
            {
                let mut statement = transaction.prepare("SELECT payload FROM tracks")?;
                for row in statement.query_map([], |row| row.get::<_, Vec<u8>>(0))? {
                    let entry: crate::model::Entry = serde_json::from_slice(&row?)?;
                    audio.insert((organization.canonical_track(&entry.track.id), entry.sha256));
                }
            }
            for document in incoming.values() {
                if let Some(previous) = existing.get(&document.id).filter(|_| expected.is_none()) {
                    anyhow::ensure!(previous == document, "playlist already exists with different content; explicit reconciliation required");
                }
                for item in &document.items {
                    if let (Some(track), Some(hash)) = (&item.track_id, &item.sha256) {
                        anyhow::ensure!(audio.contains(&(organization.canonical_track(track), hash.clone())), "destination track changed; refresh the preview");
                    }
                }
                let mut parent = document.parent.as_ref();
                let mut seen = std::collections::HashSet::from([&document.id]);
                while let Some(id) = parent {
                    anyhow::ensure!(seen.insert(id), "playlist folder cycle");
                    let folder = incoming.get(id).or_else(|| existing.get(id)).ok_or_else(|| anyhow::anyhow!("missing playlist folder"))?;
                    anyhow::ensure!(folder.kind == "folder", "parent is not a folder");
                    parent = folder.parent.as_ref();
                }
            }
            let mut added = 0;
            for record in signed {
                let body = record.decode(&proof)?;
                if records.iter().any(|saved| saved.id == record.id)
                    || existing.get(&body.document.id) == Some(&body.document) { continue; }
                transaction.execute("INSERT INTO playlist_records VALUES (?, ?, ?)", rusqlite::params![record.id, body.document.id, serde_json::to_vec(&record)?])?;
                added += 1;
            }
            transaction.commit()?;
            Ok(added)
        }).await
    }

    pub async fn playlist_page(
        &self,
        after: i64,
    ) -> anyhow::Result<Option<(i64, crate::playlists::Signed)>> {
        anyhow::ensure!(after >= 0, "invalid playlist cursor");
        self.run(move |connection, _| {
            use rusqlite::OptionalExtension as _;
            let row: Option<(i64, Vec<u8>)> = connection.query_row("SELECT rowid, payload FROM playlist_records WHERE rowid > ? ORDER BY rowid LIMIT 1", [after], |row| Ok((row.get(0)?, row.get(1)?))).optional()?;
            row.map(|(sequence, bytes)| Ok((sequence, serde_json::from_slice(&bytes)?))).transpose()
        }).await
    }

    pub async fn playlist_cursor(&self, peer: String) -> anyhow::Result<i64> {
        self.run(move |connection, _| {
            use rusqlite::OptionalExtension as _;
            Ok(connection
                .query_row(
                    "SELECT sequence FROM playlist_cursors WHERE peer = ?",
                    [peer],
                    |row| row.get(0),
                )
                .optional()?
                .unwrap_or(0))
        })
        .await
    }

    pub async fn receive_playlist(
        &self,
        peer: String,
        sequence: i64,
        record: crate::playlists::Signed,
    ) -> anyhow::Result<()> {
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            let proof = crate::enrollment::read_proof(&transaction)?;
            anyhow::ensure!(sequence > 0 && proof.grants.iter().any(|g| g.member == peer && g.host && proof.verify(&g.id).is_ok()), "unauthorized playlist peer");
            let body = record.decode(&proof)?;
            let cluster: String = transaction.query_row("SELECT id FROM cluster_identity WHERE singleton = 1", [], |row| row.get(0))?;
            anyhow::ensure!(body.cluster == cluster, "wrong playlist library");
            transaction.execute("INSERT OR IGNORE INTO playlist_records VALUES (?, ?, ?)", rusqlite::params![record.id, body.document.id, serde_json::to_vec(&record)?])?;
            transaction.execute("INSERT INTO playlist_cursors VALUES (?, ?) ON CONFLICT(peer) DO UPDATE SET sequence = MAX(sequence, excluded.sequence)", rusqlite::params![peer, sequence])?;
            transaction.commit()?;
            Ok(())
        }).await
    }
}
