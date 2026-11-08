#[derive(Clone, Debug, Default, PartialEq)]
pub struct CatalogView {
    pub library: Option<String>,
    pub tracks: std::collections::BTreeMap<String, crate::catalog_client::Track>,
    pub aliases: std::collections::BTreeMap<String, String>,
    pub albums: std::collections::BTreeMap<String, crate::catalog_client::Album>,
    pub album_aliases: std::collections::BTreeMap<String, String>,
    pub organization_choices: Vec<crate::catalog_client::OrganizationChoice>,
    pub organization_preferred: std::collections::BTreeMap<String, String>,
    pub artwork_assets: std::collections::BTreeMap<String, Vec<u8>>,
    pub artwork_candidates: Vec<crate::catalog_client::ArtworkCandidate>,
    pub artwork_preferred: std::collections::BTreeMap<String, String>,
    pub playlists: std::collections::BTreeMap<String, crate::catalog_client::Playlist>,
    pub conflicts: std::collections::BTreeSet<String>,
    pub incomplete_records: Vec<String>,
    pins: std::collections::BTreeMap<String, std::collections::BTreeSet<String>>,
    objects: std::collections::BTreeMap<String, Option<u64>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExactTrack {
    pub track_id: String,
    pub sha256: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct OrganizationChoice {
    pub id: String,
    pub subject: String,
    pub kind: String,
    pub value: Option<String>,
    pub parents: Vec<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ArtworkCandidate {
    pub id: String,
    pub track: String,
    pub source: String,
    pub context: String,
    pub asset: String,
    pub parents: Vec<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Track {
    pub id: String,
    pub title: String,
    pub artist: Option<String>,
    pub album_id: String,
    pub album: String,
    pub album_artist: Option<String>,
    pub compilation_values: Vec<String>,
    pub release: Option<(String, String)>,
    pub imported_tags: std::collections::BTreeMap<String, Vec<String>>,
    pub disc_number: Option<i64>,
    pub track_number: Option<i64>,
    pub duration: Option<f64>,
    pub suffix: Option<String>,
    pub added_at: Option<i64>,
    pub preferred: Option<crate::catalog_client::ExactTrack>,
    pub retired: bool,
    pub conflicted: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Album {
    pub id: String,
    pub title: String,
    pub releases: Vec<(String, String)>,
    pub hidden: bool,
    pub conflicted: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Occurrence {
    pub id: String,
    pub source_track: String,
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub pin: Option<crate::catalog_client::ExactTrack>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Playlist {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub parent: Option<String>,
    pub definition: std::collections::BTreeMap<String, String>,
    pub revisions: Vec<String>,
    pub conflicted: bool,
    pub items: Vec<crate::catalog_client::Occurrence>,
}

impl crate::catalog_client::CatalogView {
    /// Resolves aliases while retaining the requested ID and exact historical hash.
    pub fn exact_track(
        &self,
        pin: &crate::catalog_client::ExactTrack,
    ) -> Option<&crate::catalog_client::Track> {
        let id = self.aliases.get(&pin.track_id).unwrap_or(&pin.track_id);
        self.pins
            .get(id)?
            .contains(&pin.sha256)
            .then(|| self.tracks.get(id))
            .flatten()
    }

    pub fn audio_bytes(&self, pin: &crate::catalog_client::ExactTrack) -> Option<u64> {
        let track = self.exact_track(pin)?;
        if track.retired || track.conflicted {
            return None;
        }
        self.objects.get(&pin.sha256).copied().flatten()
    }
}

pub(super) fn hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub(super) fn project(
    snapshot: &crate::shared_audio_net::Snapshot,
    proof: &crate::enrollment::Proof,
) -> Result<crate::catalog_client::CatalogView, crate::catalog_client::Error> {
    let invalid = crate::catalog_client::Error::InvalidCatalog;
    let catalog = &snapshot.catalog;
    if proof
        .grants
        .iter()
        .any(|grant| grant.cluster != catalog.cluster)
    {
        return Err(crate::catalog_client::Error::MembershipMismatch);
    }
    let mut organization: crate::organization::Organization =
        serde_json::from_value(catalog.legacy_organization.clone()).map_err(|_| invalid)?;
    scrub_artwork_references(&mut organization).map_err(|_| invalid)?;
    organization.validate().map_err(|_| invalid)?;
    if catalog.version != 1
        || !catalog.incomplete.is_empty()
        || !hash(&catalog.baseline)
        || catalog.tracks.len() > 100_000
        || catalog
            .addresses
            .values()
            .any(|id| !catalog.tracks.contains_key(id))
    {
        return Err(invalid);
    }
    let mut view = crate::catalog_client::CatalogView {
        library: Some(catalog.library.clone()),
        aliases: catalog.addresses.clone(),
        pins: catalog.pins.clone(),
        conflicts: catalog.conflicts.clone(),
        ..Default::default()
    };
    view.organization_choices = organization
        .choices
        .iter()
        .map(|choice| crate::catalog_client::OrganizationChoice {
            id: choice.id.clone(),
            subject: choice.subject.clone(),
            kind: choice.kind.clone(),
            value: choice.value.clone(),
            parents: choice.parents.clone(),
        })
        .collect();
    view.organization_preferred = organization.preferred.clone();
    if let Some(artwork) = &organization.artwork {
        view.artwork_assets = artwork.assets.clone();
        view.artwork_preferred = artwork.preferred.clone();
        view.artwork_candidates = artwork
            .candidates
            .iter()
            .map(|candidate| crate::catalog_client::ArtworkCandidate {
                id: candidate.id.clone(),
                track: candidate.track.clone(),
                source: candidate.source.clone(),
                context: candidate.context.clone(),
                asset: candidate.asset.clone(),
                parents: candidate.parents.clone(),
            })
            .collect();
    }
    for (key, object) in &catalog.objects {
        if !hash(key)
            || key != &object.sha256
            || object
                .bytes
                .is_some_and(|size| size == 0 || size > crate::model::MAX_AUDIO)
        {
            return Err(invalid);
        }
        view.objects.insert(key.clone(), object.bytes);
    }
    for (id, pins) in &catalog.pins {
        if !catalog.tracks.contains_key(id) || pins.iter().any(|pin| !hash(pin)) {
            return Err(invalid);
        }
    }
    for album in &organization.albums {
        let canonical = organization.canonical(&album.id).map_err(|_| invalid)?;
        view.album_aliases
            .insert(album.id.clone(), canonical.to_owned());
        let record = organization
            .albums
            .iter()
            .find(|a| a.id == canonical)
            .ok_or(invalid)?;
        let conflicted = catalog
            .conflicts
            .contains(&format!("album-visibility:{canonical}"));
        view.albums.insert(
            canonical.to_owned(),
            crate::catalog_client::Album {
                id: canonical.to_owned(),
                title: record.title.clone(),
                releases: record
                    .releases
                    .iter()
                    .map(|r| (r.source.clone(), r.value.clone()))
                    .collect(),
                hidden: if conflicted {
                    organization.is_hidden(canonical)
                } else {
                    catalog
                        .album_visibility
                        .get(canonical)
                        .map_or_else(|| organization.is_hidden(canonical), |v| v.hidden)
                },
                conflicted,
            },
        );
    }
    for alias in organization
        .aliases
        .keys()
        .chain(organization.automatic_aliases.iter().flat_map(|a| a.keys()))
    {
        view.album_aliases.insert(
            alias.clone(),
            organization
                .canonical(alias)
                .map_err(|_| invalid)?
                .to_owned(),
        );
    }
    for (id, track) in &catalog.tracks {
        if id != &track.id
            || catalog.addresses.get(id).is_some_and(|target| target != id)
            || track.audio.iter().any(|h| !hash(h))
            || track
                .preferred
                .as_ref()
                .is_some_and(|h| !catalog.pins.get(id).is_some_and(|pins| pins.contains(h)))
        {
            return Err(invalid);
        }
        let metadata = |key: &str| {
            track
                .metadata
                .get(key)
                .and_then(|v| v.as_str())
                .map(str::to_owned)
        };
        let legacy = track
            .metadata
            .get("legacyEntry")
            .map(|v| serde_json::from_value::<crate::model::Track>(v.clone()))
            .transpose()
            .map_err(|_| invalid)?;
        let imported = track
            .metadata
            .get("organization")
            .map(|v| serde_json::from_value::<crate::organization::Track>(v.clone()))
            .transpose()
            .map_err(|_| invalid)?;
        let record = imported
            .as_ref()
            .or_else(|| organization.tracks.iter().find(|t| &t.id == id));
        let album_id = track
            .album_id
            .clone()
            .or_else(|| record.map(|r| r.imported_album_id.clone()))
            .unwrap_or_else(|| format!("v5-unassigned:{id}"));
        let album_id = organization
            .canonical(&album_id)
            .map_err(|_| invalid)?
            .to_owned();
        if organization
            .album_id_for_track(id)
            .map_err(|_| invalid)?
            .is_some_and(|previous| previous != album_id)
        {
            view.organization_choices
                .retain(|choice| choice.kind != "membership" || choice.subject != *id);
            view.organization_preferred
                .remove(&format!("membership:{id}"));
        }
        let title = metadata("title")
            .or_else(|| legacy.as_ref().map(|t| t.title.clone()))
            .or_else(|| record.and_then(|r| r.title.clone()))
            .unwrap_or_default();
        let album = metadata("album")
            .or_else(|| view.albums.get(&album_id).map(|a| a.title.clone()))
            .or_else(|| legacy.as_ref().and_then(|t| t.album.clone()))
            .or_else(|| record.and_then(|r| r.imported.title.clone()))
            .unwrap_or_default();
        view.albums
            .entry(album_id.clone())
            .or_insert_with(|| crate::catalog_client::Album {
                id: album_id.clone(),
                title: album.clone(),
                releases: record
                    .and_then(|r| r.imported.release.as_ref())
                    .map(|r| vec![(r.source.clone(), r.value.clone())])
                    .unwrap_or_default(),
                hidden: false,
                conflicted: false,
            });
        view.tracks.insert(
            id.clone(),
            crate::catalog_client::Track {
                id: id.clone(),
                title,
                artist: metadata("artist")
                    .or_else(|| legacy.as_ref().and_then(|t| t.artist.clone()))
                    .or_else(|| record.and_then(|r| r.imported.artist.clone())),
                album_id,
                album,
                album_artist: record.and_then(|r| r.imported.album_artist.clone()),
                compilation_values: record
                    .map(|r| r.imported.compilation_values.clone())
                    .unwrap_or_default(),
                release: record
                    .and_then(|r| r.imported.release.as_ref())
                    .map(|r| (r.source.clone(), r.value.clone())),
                imported_tags: record
                    .and_then(|r| r.imported.tag_values.clone())
                    .unwrap_or_default(),
                disc_number: track
                    .metadata
                    .get("discNumber")
                    .and_then(|v| v.as_i64())
                    .or_else(|| legacy.as_ref().and_then(|t| t.disc_number))
                    .or_else(|| record.and_then(|r| r.disc_number)),
                track_number: track
                    .metadata
                    .get("track")
                    .and_then(|v| v.as_i64())
                    .or_else(|| legacy.as_ref().and_then(|t| t.track))
                    .or_else(|| record.and_then(|r| r.track_number)),
                duration: track
                    .metadata
                    .get("duration")
                    .and_then(|v| v.as_f64())
                    .or_else(|| legacy.as_ref().and_then(|t| t.duration)),
                suffix: metadata("suffix").or_else(|| legacy.as_ref().map(|t| t.suffix.clone())),
                added_at: track.added_at,
                preferred: track
                    .preferred
                    .as_ref()
                    .map(|h| crate::catalog_client::ExactTrack {
                        track_id: id.clone(),
                        sha256: h.clone(),
                    }),
                retired: track.retired,
                conflicted: catalog.conflicts.contains(&format!("track:{id}")),
            },
        );
    }
    let projected =
        crate::playlists::project(&snapshot.playlist_history, proof).map_err(|_| invalid)?;
    if projected.len() != snapshot.playlists.len() {
        return Err(invalid);
    }
    for record in &snapshot.playlist_history {
        if record.decode(proof).map_err(|_| invalid)?.cluster != catalog.cluster {
            return Err(invalid);
        }
    }
    for playlist in &snapshot.playlists {
        let expected = projected.get(&playlist.document.id).ok_or(invalid)?;
        if expected.document != playlist.document
            || expected.revisions != playlist.revisions
            || expected.conflicted != playlist.conflicted
        {
            return Err(invalid);
        }
        if view.playlists.contains_key(&playlist.document.id) {
            return Err(invalid);
        }
        view.playlists.insert(
            playlist.document.id.clone(),
            crate::catalog_client::Playlist {
                id: playlist.document.id.clone(),
                name: playlist.document.name.clone(),
                kind: playlist.document.kind.clone(),
                parent: playlist.document.parent.clone(),
                definition: playlist.document.definition.clone(),
                revisions: playlist.revisions.clone(),
                conflicted: playlist.conflicted,
                items: playlist
                    .document
                    .items
                    .iter()
                    .map(|item| crate::catalog_client::Occurrence {
                        id: item.id.clone(),
                        source_track: item.source_track.clone(),
                        title: item.title.clone(),
                        artist: item.artist.clone(),
                        album: item.album.clone(),
                        pin: item
                            .track_id
                            .as_ref()
                            .zip(item.sha256.as_ref())
                            .map(|(id, hash)| crate::catalog_client::ExactTrack {
                                track_id: id.clone(),
                                sha256: hash.clone(),
                            }),
                    })
                    .collect(),
            },
        );
    }
    Ok(view)
}

fn scrub_artwork_references(
    organization: &mut crate::organization::Organization,
) -> anyhow::Result<()> {
    let Some(mut artwork) = organization.artwork.take() else {
        return Ok(());
    };
    let missing: std::collections::BTreeSet<_> = artwork
        .assets
        .iter()
        .filter(|(_, bytes)| bytes.is_empty())
        .map(|(id, _)| id.clone())
        .collect();
    if !missing.is_empty() {
        // A v5 baseline can carry empty asset references rather than JPEG bytes.
        let mut albums = std::collections::BTreeSet::new();
        for candidate in &artwork.candidates {
            if missing.contains(&candidate.asset) {
                albums.extend(organization.album_id_for_track(&candidate.track)?);
            }
        }
        for choice in &organization.choices {
            if choice.kind == "artwork"
                && choice
                    .value
                    .as_ref()
                    .is_some_and(|value| missing.contains(value))
            {
                albums.insert(organization.canonical(&choice.subject)?.to_owned());
            }
        }
        let removed: std::collections::BTreeSet<_> = organization
            .choices
            .iter()
            .filter(|choice| {
                choice.kind == "artwork"
                    && organization
                        .canonical(&choice.subject)
                        .is_ok_and(|album| albums.contains(album))
            })
            .map(|choice| choice.id.clone())
            .collect();
        organization
            .choices
            .retain(|choice| !removed.contains(&choice.id));
        organization
            .preferred
            .retain(|_, choice| !removed.contains(choice));
        artwork.assets.retain(|id, _| !missing.contains(id));
        let mut retained = Vec::new();
        for candidate in artwork.candidates {
            if !organization
                .album_id_for_track(&candidate.track)?
                .is_some_and(|album| albums.contains(&album))
            {
                retained.push(candidate);
            }
        }
        artwork.candidates = retained;
        artwork
            .preferred
            .retain(|_, asset| !missing.contains(asset));
    }
    organization.artwork = Some(artwork);
    Ok(())
}
