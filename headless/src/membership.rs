#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, serde::Serialize, serde::Deserialize)]
pub struct ImportContext {
    #[serde(rename = "sourceID")]
    pub source_id: String,
    pub folder: String,
}

impl crate::membership::ImportContext {
    pub fn is_valid(&self) -> bool {
        !self.source_id.is_empty()
            && self.source_id.len() <= 1024
            && self.folder.len() <= 4096
            && !self.folder.starts_with('/')
            && !self.folder.contains('\0')
            && !self.folder.split('/').any(|p| p == "." || p == "..")
    }

    fn parent(&self) -> String {
        let mut parts: Vec<_> = self.folder.split('/').filter(|p| !p.is_empty()).collect();
        parts.pop();
        parts.join("/")
    }
}

fn positive_compilation(members: &[crate::organization::Track]) -> bool {
    let values: Vec<_> = members
        .iter()
        .flat_map(|t| &t.imported.compilation_values)
        .collect();
    !values.is_empty()
        && values
            .iter()
            .all(|v| matches!(v.trim().to_lowercase().as_str(), "1" | "true"))
}

impl crate::organization::Organization {
    pub fn repair_membership(&mut self) -> anyhow::Result<()> {
        let established: std::collections::BTreeSet<_> = self
            .albums
            .iter()
            .map(|a| self.canonical(&a.id).map(str::to_owned))
            .collect::<anyhow::Result<_>>()?;
        self.repair_membership_with_established(established)
    }

    pub(crate) fn repair_membership_with_established(
        &mut self,
        established: std::collections::BTreeSet<String>,
    ) -> anyhow::Result<()> {
        let previous = self.automatic_aliases.clone().unwrap_or_default();
        self.automatic_aliases = None;
        let records: Vec<_> = self
            .tracks
            .iter()
            .filter(|t| self.canonical_track(&t.id) == t.id)
            .cloned()
            .collect();
        let mut releases = std::collections::BTreeMap::<_, Vec<_>>::new();
        let mut directories = std::collections::BTreeMap::<_, Vec<_>>::new();
        let mut parents = std::collections::BTreeMap::<_, Vec<_>>::new();
        for record in &records {
            if let Some(release) = &record.imported.release {
                releases
                    .entry(release.clone())
                    .or_default()
                    .push(record.clone());
            }
            if let Some(context) = &record.import_context
                && let Some(title) = &record.imported.title
                && !title.is_empty()
            {
                directories
                    .entry((
                        context.source_id.clone(),
                        context.folder.clone(),
                        title.clone(),
                    ))
                    .or_default()
                    .push(record.clone());
                if !context.folder.is_empty() {
                    parents
                        .entry((context.source_id.clone(), context.parent(), title.clone()))
                        .or_default()
                        .push(record.clone());
                }
            }
        }
        for members in releases.values() {
            self.infer_membership(members, &records, &established, &previous)?;
        }
        for members in directories.values() {
            if crate::membership::positive_compilation(members) {
                self.infer_membership(members, &records, &established, &previous)?;
            }
        }
        for members in parents.values() {
            let mut folders = std::collections::BTreeMap::<_, Vec<_>>::new();
            for member in members {
                folders
                    .entry(&member.import_context.as_ref().expect("scoped track").folder)
                    .or_default()
                    .push(member);
            }
            if folders.len() < 2 {
                continue;
            }
            let mut discs = std::collections::BTreeSet::new();
            let numbered = folders.values().all(|tracks| {
                let Some(number) = tracks[0].disc_number.filter(|n| *n > 0) else {
                    return false;
                };
                tracks.iter().all(|t| t.disc_number == Some(number)) && discs.insert(number)
            });
            let credits: Vec<_> = members
                .iter()
                .filter_map(|t| t.imported.album_artist.as_ref())
                .collect();
            let shared_credit = credits.len() == members.len()
                && credits.first().is_some_and(|first| {
                    !first.trim().is_empty()
                        && first.to_lowercase() != "various artists"
                        && credits.iter().all(|v| v == first)
                });
            if numbered && (shared_credit || crate::membership::positive_compilation(members)) {
                self.infer_membership(members, &records, &established, &previous)?;
            }
        }
        Ok(())
    }

    fn infer_membership(
        &mut self,
        members: &[crate::organization::Track],
        records: &[crate::organization::Track],
        established: &std::collections::BTreeSet<String>,
        previous: &std::collections::BTreeMap<String, String>,
    ) -> anyhow::Result<()> {
        let ids: std::collections::BTreeSet<_> = members
            .iter()
            .map(|t| self.canonical(&t.imported_album_id).map(str::to_owned))
            .collect::<anyhow::Result<_>>()?;
        if ids.len() < 2 {
            return Ok(());
        }
        let member_ids: std::collections::BTreeSet<_> = members.iter().map(|t| &t.id).collect();
        if records.iter().any(|t| {
            ids.contains(
                self.canonical(&t.imported_album_id)
                    .unwrap_or(&t.imported_album_id),
            ) && !member_ids.contains(&t.id)
        }) {
            return Ok(());
        }
        let releases: std::collections::BTreeSet<_> = members
            .iter()
            .filter_map(|t| t.imported.release.as_ref())
            .collect();
        let raw: Vec<_> = members
            .iter()
            .flat_map(|t| {
                t.imported
                    .tag_values
                    .as_ref()
                    .and_then(|v| v.get("MUSICBRAINZ_ALBUMID"))
                    .into_iter()
                    .flatten()
            })
            .collect();
        if releases.len() > 1
            || raw.iter().any(|v| uuid::Uuid::parse_str(v).is_err())
            || raw
                .iter()
                .map(|v| v.to_lowercase())
                .collect::<std::collections::BTreeSet<_>>()
                .len()
                > 1
        {
            return Ok(());
        }
        let superseded: std::collections::BTreeSet<_> =
            self.choices.iter().flat_map(|c| &c.parents).collect();
        let active: Vec<_> = self
            .choices
            .iter()
            .filter(|c| !superseded.contains(&c.id))
            .collect();
        for member in members {
            if active.iter().any(|c| {
                c.kind == "membership"
                    && self.subject(c) == self.canonical_track(&member.id)
                    && c.value.is_some()
            }) {
                return Ok(());
            }
        }
        let classifications: std::collections::BTreeSet<_> = active
            .iter()
            .filter(|c| c.kind == "classification" && ids.contains(&self.subject(c)))
            .map(|c| &c.value)
            .collect();
        if classifications.len() > 1 {
            return Ok(());
        }
        if active.iter().any(|c| {
            c.kind == "proposal"
                && c.value.is_some()
                && c.subject
                    .split(',')
                    .filter_map(|id| self.canonical(id).ok())
                    .filter(|id| ids.contains(*id))
                    .collect::<std::collections::BTreeSet<_>>()
                    .len()
                    > 1
        }) {
            return Ok(());
        }
        let former: std::collections::BTreeSet<_> = previous
            .values()
            .filter(|v| ids.contains(*v))
            .cloned()
            .collect();
        let survivor = former
            .first()
            .or_else(|| established.intersection(&ids).next())
            .or_else(|| ids.first())
            .expect("nonempty group")
            .clone();
        for id in ids {
            if id != survivor {
                self.automatic_aliases
                    .get_or_insert_with(Default::default)
                    .insert(id, survivor.clone());
            }
        }
        Ok(())
    }
}
