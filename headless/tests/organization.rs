fn fixture() -> syncstr_headless::organization::Organization {
    serde_json::from_str(include_str!("../fixtures/album-organization.json")).unwrap()
}

#[test]
fn shared_membership_cases_and_reordered_evidence() {
    #[derive(serde::Deserialize)]
    struct Fixture {
        name: String,
        organization: syncstr_headless::organization::Organization,
        groups: Vec<Vec<String>>,
    }
    let cases: Vec<Fixture> =
        serde_json::from_str(include_str!("../fixtures/compilation-membership.json")).unwrap();
    for case in cases {
        for reversed in [false, true] {
            let mut organization = case.organization.clone();
            if reversed {
                organization.tracks.reverse();
                organization.albums.reverse();
            }
            organization.repair_membership().unwrap();
            organization.validate().unwrap();
            let mut groups = std::collections::BTreeMap::<_, Vec<_>>::new();
            for track in &organization.tracks {
                groups
                    .entry(organization.canonical(&track.imported_album_id).unwrap())
                    .or_default()
                    .push(track.id.clone());
            }
            let actual: std::collections::BTreeSet<_> = groups
                .into_values()
                .map(|mut v| {
                    v.sort();
                    v
                })
                .collect();
            let expected: std::collections::BTreeSet<_> = case
                .groups
                .iter()
                .cloned()
                .map(|mut v| {
                    v.sort();
                    v
                })
                .collect();
            assert_eq!(actual, expected, "{}", case.name);
            assert_eq!(organization.choices, case.organization.choices);
            let repaired = organization.clone();
            organization.repair_membership().unwrap();
            assert_eq!(organization, repaired, "{}", case.name);
        }
    }
}

#[tokio::test]
async fn later_disc_merge_keeps_identity_and_repair_survives_restart_and_failure() {
    let cases: serde_json::Value =
        serde_json::from_str(include_str!("../fixtures/compilation-membership.json")).unwrap();
    let case = cases
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == "sibling discs")
        .unwrap();
    let incoming: syncstr_headless::organization::Organization =
        serde_json::from_value(case["organization"].clone()).unwrap();
    let mut local = incoming.clone();
    local.albums.remove(0);
    local.tracks.remove(0);
    local.merge(&incoming).unwrap();
    assert_eq!(local.canonical("album-01").unwrap(), "album-02");
    assert!(local.choices.is_empty());
    let root = tempfile::tempdir().unwrap();
    let store = syncstr_headless::store::Store::open(root.path()).unwrap();
    store.merge_organization(local.clone()).await.unwrap();
    drop(store);
    let reopened = syncstr_headless::store::Store::open(root.path()).unwrap();
    assert_eq!(reopened.catalog().await.unwrap().organization, local);
    let connection = rusqlite::Connection::open(root.path().join("node.sqlite")).unwrap();
    connection.execute_batch("CREATE TRIGGER reject_repair BEFORE UPDATE ON organization BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;").unwrap();
    let mut contradictory = incoming;
    contradictory.tracks[1].imported.compilation_values = vec!["0".into()];
    assert!(
        reopened
            .merge_organization(contradictory.clone())
            .await
            .is_err()
    );
    assert_eq!(reopened.catalog().await.unwrap().organization, local);
    connection
        .execute_batch("DROP TRIGGER reject_repair;")
        .unwrap();
    reopened.merge_organization(contradictory).await.unwrap();
    let repaired = reopened.catalog().await.unwrap().organization;
    assert_eq!(repaired.canonical("album-01").unwrap(), "album-01");
    assert_eq!(repaired.canonical("album-02").unwrap(), "album-02");
}

#[test]
fn long_serial_choice_history_remains_valid() {
    let mut organization = crate::fixture();
    let mut parent = "revision-b".to_owned();
    for index in 0..256 {
        let id = format!("revision-{index}");
        organization
            .choices
            .push(syncstr_headless::organization::Choice {
                id: id.clone(),
                subject: "album-a".into(),
                kind: "classification".into(),
                value: None,
                parents: vec![parent],
            });
        parent = id;
    }
    organization.validate().unwrap();
}

#[test]
fn concurrent_choices_keep_local_preference_and_old_clear_does_not_win() {
    let mut local = crate::fixture();
    let mut peer = local.clone();
    let old = local.clone();
    local.choices.push(syncstr_headless::organization::Choice {
        id: "local-revision".into(),
        subject: "album-a".into(),
        kind: "classification".into(),
        value: Some("true".into()),
        parents: vec!["revision-b".into()],
    });
    local
        .preferred
        .insert("classification:album-a".into(), "local-revision".into());
    peer.choices.push(syncstr_headless::organization::Choice {
        id: "peer-revision".into(),
        subject: "album-a".into(),
        kind: "classification".into(),
        value: Some("false".into()),
        parents: vec!["revision-b".into()],
    });
    local.merge(&peer).unwrap();
    local.merge(&old).unwrap();
    assert_eq!(local.preferred["classification:album-a"], "local-revision");
    assert_eq!(local.choices.len(), 4);
    assert!(
        local
            .choices
            .iter()
            .any(|c| c.id == "peer-revision" && c.value.as_deref() == Some("false"))
    );
}

#[test]
fn incoming_manual_album_alias_cannot_overwrite_competing_local_membership() {
    let mut local = crate::fixture();
    local.choices.clear();
    local.preferred.clear();
    let mut peer = local.clone();
    local.choices.push(syncstr_headless::organization::Choice {
        id: "local-membership".into(),
        subject: "track-a".into(),
        kind: "membership".into(),
        value: Some("album-a".into()),
        parents: vec![],
    });
    local
        .preferred
        .insert("membership:track-a".into(), "local-membership".into());
    peer.albums.push(syncstr_headless::organization::Album {
        id: "album-b".into(),
        title: "Collection".into(),
        releases: vec![],
    });
    peer.choices.push(syncstr_headless::organization::Choice {
        id: "peer-membership".into(),
        subject: "track-a".into(),
        kind: "membership".into(),
        value: Some("album-b".into()),
        parents: vec![],
    });
    peer.aliases.insert("album-a".into(), "album-b".into());
    local.merge(&peer).unwrap();
    assert_eq!(local.canonical("album-a").unwrap(), "album-a");
    assert_eq!(local.preferred["membership:track-a"], "local-membership");
    assert_eq!(local.choices.len(), 2);
}

#[tokio::test]
async fn unavailable_organization_survives_restart_and_invalid_merge_rolls_back() {
    let root = tempfile::tempdir().unwrap();
    let store = syncstr_headless::store::Store::open(root.path()).unwrap();
    let organization = crate::fixture();
    store
        .merge_organization(organization.clone())
        .await
        .unwrap();
    assert!(store.catalog().await.unwrap().entries.is_empty());
    let mut invalid = organization.clone();
    invalid.aliases.insert("album-a".into(), "album-a".into());
    assert!(store.merge_organization(invalid).await.is_err());
    drop(store);
    let reopened = syncstr_headless::store::Store::open(root.path())
        .unwrap()
        .catalog()
        .await
        .unwrap();
    assert_eq!(reopened.organization, organization);
}

#[test]
fn matching_edition_ids_reconcile_but_classification_conflicts_prevent_merge() {
    let mut local = crate::fixture();
    local.choices.clear();
    local.preferred.clear();
    let release = syncstr_headless::organization::Release {
        source: "musicbrainz-release".into(),
        value: "edition-a".into(),
    };
    local.albums[0].releases.push(release);
    let mut peer = local.clone();
    peer.albums[0].id = "album-b".into();
    peer.tracks[0].id = "track-b".into();
    peer.tracks[0].sha256 = "b".repeat(64);
    peer.tracks[0].imported_album_id = "album-b".into();
    let original = local.clone();
    local.merge(&peer).unwrap();
    assert_eq!(local.canonical("album-b").unwrap(), "album-a");

    let mut local = original;
    local.choices.push(syncstr_headless::organization::Choice {
        id: "local".into(),
        subject: "album-a".into(),
        kind: "classification".into(),
        value: Some("true".into()),
        parents: vec![],
    });
    peer.choices.push(syncstr_headless::organization::Choice {
        id: "peer".into(),
        subject: "album-b".into(),
        kind: "classification".into(),
        value: Some("false".into()),
        parents: vec![],
    });
    local.merge(&peer).unwrap();
    assert_eq!(local.canonical("album-b").unwrap(), "album-b");
}
