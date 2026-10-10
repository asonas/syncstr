#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, serde::Serialize, serde::Deserialize)]
pub struct Release {
    pub source: String,
    pub value: String,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Imported {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artist: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    pub compilation_values: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub release: Option<crate::organization::Release>,
    #[serde(default, rename = "tagValues", skip_serializing_if = "Option::is_none")]
    pub tag_values: Option<std::collections::BTreeMap<String, Vec<String>>>,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Album {
    pub id: String,
    pub title: String,
    pub releases: Vec<crate::organization::Release>,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    pub id: String,
    pub sha256: String,
    pub imported: crate::organization::Imported,
    #[serde(rename = "importedAlbumID")]
    pub imported_album_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(
        default,
        rename = "folderEvidence",
        skip_serializing_if = "Option::is_none"
    )]
    pub folder_evidence: Option<String>,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Choice {
    pub id: String,
    pub subject: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    pub parents: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Organization {
    pub albums: Vec<crate::organization::Album>,
    pub tracks: Vec<crate::organization::Track>,
    pub aliases: std::collections::BTreeMap<String, String>,
    pub choices: Vec<crate::organization::Choice>,
    pub preferred: std::collections::BTreeMap<String, String>,
    #[serde(
        default,
        rename = "trackAliases",
        skip_serializing_if = "Option::is_none"
    )]
    pub track_aliases: Option<std::collections::BTreeMap<String, String>>,
}

impl crate::organization::Organization {
    fn canonical_track(&self, id: &str) -> String {
        let mut cursor = id.to_owned();
        let mut seen = std::collections::BTreeSet::new();
        while let Some(next) = self.track_aliases.as_ref().and_then(|a| a.get(&cursor)) {
            if !seen.insert(cursor.clone()) {
                break;
            }
            cursor = next.clone();
        }
        cursor
    }

    fn subject(&self, choice: &crate::organization::Choice) -> String {
        match choice.kind.as_str() {
            "membership" => self.canonical_track(&choice.subject),
            "classification" => self
                .canonical(&choice.subject)
                .unwrap_or(&choice.subject)
                .to_owned(),
            _ => choice.subject.clone(),
        }
    }

    pub fn canonical<'a>(&'a self, id: &'a str) -> anyhow::Result<&'a str> {
        let mut cursor = id;
        let mut seen = std::collections::BTreeSet::new();
        while let Some(next) = self.aliases.get(cursor) {
            anyhow::ensure!(seen.insert(cursor), "album alias cycle");
            cursor = next;
        }
        Ok(cursor)
    }

    pub fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.albums.len() <= 100000
                && self.tracks.len() <= 100000
                && self.choices.len() <= 200000,
            "organization too large"
        );
        let albums: std::collections::BTreeSet<_> =
            self.albums.iter().map(|a| a.id.as_str()).collect();
        let tracks: std::collections::BTreeSet<_> =
            self.tracks.iter().map(|t| t.id.as_str()).collect();
        let choices: std::collections::BTreeMap<_, _> =
            self.choices.iter().map(|c| (c.id.as_str(), c)).collect();
        anyhow::ensure!(
            albums.len() == self.albums.len()
                && tracks.len() == self.tracks.len()
                && choices.len() == self.choices.len(),
            "duplicate organization ID"
        );
        for alias in self.aliases.keys() {
            anyhow::ensure!(
                albums.contains(self.canonical(alias)?),
                "unknown album alias target"
            );
        }
        for track in &self.tracks {
            anyhow::ensure!(
                albums.contains(self.canonical(&track.imported_album_id)?),
                "unknown imported album"
            );
        }
        if let Some(aliases) = &self.track_aliases {
            for former in aliases.keys() {
                let mut cursor = former;
                let mut seen = std::collections::BTreeSet::new();
                while let Some(next) = aliases.get(cursor) {
                    anyhow::ensure!(seen.insert(cursor), "track alias cycle");
                    cursor = next;
                }
                anyhow::ensure!(
                    tracks.contains(cursor.as_str()),
                    "unknown track alias target"
                );
            }
        }
        let mut remaining = std::collections::BTreeMap::new();
        let mut children: std::collections::BTreeMap<&str, Vec<&str>> =
            std::collections::BTreeMap::new();
        for choice in &self.choices {
            anyhow::ensure!(
                choice.id.len() <= 128 && choice.parents.len() <= 10000,
                "invalid choice"
            );
            match choice.kind.as_str() {
                "membership" => {
                    anyhow::ensure!(tracks.contains(choice.subject.as_str()), "unknown member");
                    if let Some(value) = &choice.value {
                        anyhow::ensure!(
                            albums.contains(self.canonical(value)?),
                            "unknown chosen album"
                        );
                    }
                }
                "classification" => {
                    anyhow::ensure!(
                        albums.contains(self.canonical(&choice.subject)?),
                        "unknown classification album"
                    );
                    anyhow::ensure!(
                        choice
                            .value
                            .as_deref()
                            .is_none_or(|v| v == "true" || v == "false"),
                        "invalid classification"
                    );
                }
                "proposal" => {}
                _ => anyhow::bail!("unknown choice kind"),
            }
            let parents: std::collections::BTreeSet<_> = choice.parents.iter().collect();
            anyhow::ensure!(
                parents.len() == choice.parents.len(),
                "duplicate revision parent"
            );
            remaining.insert(choice.id.as_str(), choice.parents.len());
            for parent in &choice.parents {
                let ancestor = choices
                    .get(parent.as_str())
                    .ok_or_else(|| anyhow::anyhow!("unknown revision parent"))?;
                anyhow::ensure!(
                    ancestor.kind == choice.kind && self.subject(ancestor) == self.subject(choice),
                    "invalid revision parent"
                );
                children.entry(parent).or_default().push(&choice.id);
            }
        }
        let mut ready: Vec<_> = self
            .choices
            .iter()
            .filter(|c| c.parents.is_empty())
            .map(|c| c.id.as_str())
            .collect();
        let mut index = 0;
        while index < ready.len() {
            let id = ready[index];
            index += 1;
            for child in children.get(id).into_iter().flatten() {
                let count = remaining.get_mut(child).expect("validated revision child");
                *count -= 1;
                if *count == 0 {
                    ready.push(child);
                }
            }
        }
        anyhow::ensure!(ready.len() == self.choices.len(), "choice revision cycle");
        Ok(())
    }

    pub fn merge(&mut self, incoming: &Self) -> anyhow::Result<()> {
        incoming.validate()?;
        for album in &incoming.albums {
            if let Some(existing) = self.albums.iter_mut().find(|a| a.id == album.id) {
                for release in &album.releases {
                    if !existing.releases.contains(release) {
                        existing.releases.push(release.clone());
                    }
                }
            } else {
                self.albums.push(album.clone());
            }
        }
        for track in &incoming.tracks {
            if let Some(existing) = self.tracks.iter_mut().find(|t| t.id == track.id) {
                *existing = track.clone();
            } else {
                let matches: Vec<_> = self
                    .tracks
                    .iter()
                    .filter(|t| t.sha256 == track.sha256 && self.canonical_track(&t.id) == t.id)
                    .collect();
                if matches.len() == 1
                    && incoming
                        .tracks
                        .iter()
                        .filter(|t| t.sha256 == track.sha256)
                        .count()
                        == 1
                {
                    self.track_aliases
                        .get_or_insert_with(Default::default)
                        .insert(track.id.clone(), matches[0].id.clone());
                }
                self.tracks.push(track.clone());
            }
        }
        for choice in &incoming.choices {
            if let Some(existing) = self.choices.iter().find(|c| c.id == choice.id) {
                anyhow::ensure!(existing == choice, "conflicting revision ID");
            } else {
                self.choices.push(choice.clone());
            }
        }
        for (former, survivor) in &incoming.aliases {
            if let Some(existing) = self.aliases.get(former)
                && self.canonical(existing)? != self.canonical(survivor)?
            {
                continue;
            }
            if !self.can_alias(former, survivor)? || self.canonical(survivor)? == former {
                continue;
            }
            self.aliases.insert(former.clone(), survivor.clone());
        }
        if let Some(aliases) = &incoming.track_aliases {
            for (former, survivor) in aliases {
                if let Some(existing) = self.track_aliases.as_ref().and_then(|a| a.get(former)) {
                    anyhow::ensure!(
                        self.canonical_track(existing)
                            == self.canonical_track(&incoming.canonical_track(survivor)),
                        "conflicting track aliases"
                    );
                }
                self.track_aliases
                    .get_or_insert_with(Default::default)
                    .insert(former.clone(), survivor.clone());
            }
        }
        for choice in &incoming.choices {
            let key = format!("{}:{}", choice.kind, self.subject(choice));
            let superseded: std::collections::BTreeSet<_> =
                self.choices.iter().flat_map(|c| &c.parents).collect();
            if self
                .preferred
                .get(&key)
                .is_none_or(|id| superseded.contains(id))
            {
                let head = self
                    .choices
                    .iter()
                    .filter(|c| {
                        c.kind == choice.kind
                            && self.subject(c) == self.subject(choice)
                            && !superseded.contains(&c.id)
                    })
                    .min_by_key(|c| &c.id);
                if let Some(head) = head {
                    self.preferred.insert(key, head.id.clone());
                }
            }
        }
        self.reconcile_releases()?;
        self.validate()
    }

    fn can_alias(&self, former: &str, survivor: &str) -> anyhow::Result<bool> {
        let superseded: std::collections::BTreeSet<_> =
            self.choices.iter().flat_map(|c| &c.parents).collect();
        let active: Vec<_> = self
            .choices
            .iter()
            .filter(|c| !superseded.contains(&c.id))
            .collect();
        let ids = [self.canonical(former)?, self.canonical(survivor)?];
        let classifications: std::collections::BTreeSet<_> = active
            .iter()
            .filter(|c| c.kind == "classification" && ids.contains(&self.subject(c).as_str()))
            .map(|c| &c.value)
            .collect();
        if classifications.len() > 1 {
            return Ok(false);
        }
        for track in &self.tracks {
            if !ids.contains(&self.canonical(&track.imported_album_id)?) {
                continue;
            }
            let values: std::collections::BTreeSet<_> = active
                .iter()
                .filter(|c| {
                    c.kind == "membership" && self.subject(c) == self.canonical_track(&track.id)
                })
                .map(|c| &c.value)
                .collect();
            if values.len() > 1 {
                return Ok(false);
            }
        }
        Ok(true)
    }

    pub fn import(&mut self, entry: &crate::model::Entry) {
        let imported = entry
            .imported_album
            .clone()
            .unwrap_or(crate::organization::Imported {
                title: entry.track.album.clone(),
                artist: entry.track.artist.clone(),
                album_artist: None,
                compilation_values: Vec::new(),
                release: None,
                tag_values: None,
            });
        let id = self.canonical_track(&entry.track.id);
        if let Some(track) = self.tracks.iter_mut().find(|t| t.id == id) {
            track.imported = imported;
            track.sha256 = entry.sha256.clone();
            return;
        }
        let album = self
            .albums
            .iter()
            .find(|a| {
                imported
                    .release
                    .as_ref()
                    .is_some_and(|r| a.releases.contains(r))
                    || entry.track.album_id.as_ref().is_some_and(|id| &a.id == id)
            })
            .map(|a| a.id.clone())
            .unwrap_or_else(|| {
                let id = entry
                    .track
                    .album_id
                    .clone()
                    .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
                self.albums.push(crate::organization::Album {
                    id: id.clone(),
                    title: entry.track.album.clone().unwrap_or_default(),
                    releases: imported.release.clone().into_iter().collect(),
                });
                id
            });
        self.tracks.push(crate::organization::Track {
            id: entry.track.id.clone(),
            sha256: entry.sha256.clone(),
            imported,
            imported_album_id: album,
            title: Some(entry.track.title.clone()),
            folder_evidence: None,
        });
    }

    fn reconcile_releases(&mut self) -> anyhow::Result<()> {
        let releases: std::collections::BTreeSet<_> = self
            .albums
            .iter()
            .flat_map(|a| a.releases.clone())
            .collect();
        for release in releases {
            let ids: std::collections::BTreeSet<_> = self
                .albums
                .iter()
                .filter(|a| a.releases.contains(&release))
                .map(|a| self.canonical(&a.id).map(str::to_owned))
                .collect::<anyhow::Result<_>>()?;
            let Some(survivor) = ids.first() else {
                continue;
            };
            if ids.len() < 2 {
                continue;
            }
            let superseded: std::collections::BTreeSet<_> =
                self.choices.iter().flat_map(|c| c.parents.iter()).collect();
            let active: Vec<_> = self
                .choices
                .iter()
                .filter(|c| !superseded.contains(&c.id))
                .collect();
            let classifications: std::collections::BTreeSet<_> = active
                .iter()
                .filter(|c| c.kind == "classification" && ids.contains(&self.subject(c)))
                .map(|c| c.value.clone())
                .collect();
            let memberships: std::collections::BTreeSet<_> = active
                .iter()
                .filter(|c| {
                    c.kind == "membership"
                        && self.tracks.iter().any(|t| {
                            t.id == self.subject(c)
                                && ids.contains(
                                    self.canonical(&t.imported_album_id)
                                        .unwrap_or(&t.imported_album_id),
                                )
                        })
                })
                .filter_map(|c| c.value.clone())
                .collect();
            if classifications.len() > 1 || memberships.len() > 1 {
                continue;
            }
            for id in ids.iter().skip(1) {
                self.aliases.insert(id.clone(), survivor.clone());
                let key = format!("classification:{survivor}");
                if !self.preferred.contains_key(&key)
                    && let Some(preferred) =
                        self.preferred.get(&format!("classification:{id}")).cloned()
                {
                    self.preferred.insert(key, preferred);
                }
            }
        }
        Ok(())
    }
}
