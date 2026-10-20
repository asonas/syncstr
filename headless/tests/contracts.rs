#[test]
fn native_entry_fixture_round_trips_without_changing_field_names_or_base64() {
    let data = include_bytes!("../fixtures/local-entry.json");
    let entry: syncstr_headless::model::Entry = serde_json::from_slice(data).unwrap();
    entry.validate().unwrap();
    assert_eq!(entry.track.id, "fixture-track");
    assert_eq!(entry.track.title, "夜の音楽");
    assert_eq!(entry.track.album_id.as_deref(), Some("fixture-album"));
    assert_eq!(entry.track.duration, Some(1.25));
    assert_eq!(entry.track.disc_number, Some(1));
    assert_eq!(entry.artwork, Some(vec![1, 2, 3]));
    assert_eq!(
        serde_json::to_value(entry).unwrap(),
        serde_json::from_slice::<serde_json::Value>(data).unwrap()
    );
}

#[test]
fn organization_fixture_round_trips_with_native_field_names_and_clear_revision() {
    let data = include_bytes!("../fixtures/album-organization.json");
    let organization: syncstr_headless::organization::Organization =
        serde_json::from_slice(data).unwrap();
    organization.validate().unwrap();
    assert_eq!(organization.tracks[0].imported_album_id, "album-a");
    assert_eq!(organization.choices[1].value, None);
    assert_eq!(
        serde_json::to_value(organization).unwrap(),
        serde_json::from_slice::<serde_json::Value>(data).unwrap()
    );
}

#[test]
fn album_membership_preserves_aliases_and_exposes_concurrent_choices() {
    let mut organization: syncstr_headless::organization::Organization =
        serde_json::from_slice(include_bytes!("../fixtures/album-organization.json")).unwrap();
    organization
        .albums
        .push(syncstr_headless::organization::Album {
            id: "album-b".into(),
            title: "Collection".into(),
            releases: vec![],
        });
    organization
        .aliases
        .insert("former-album".into(), "album-b".into());
    organization.track_aliases = Some(std::collections::BTreeMap::from([(
        "former-track".into(),
        "track-a".into(),
    )]));
    let choice = |id: &str, value: Option<&str>, parents: Vec<String>| {
        syncstr_headless::organization::Choice {
            id: id.into(),
            subject: "track-a".into(),
            kind: "membership".into(),
            value: value.map(str::to_owned),
            parents,
        }
    };
    organization
        .choices
        .push(choice("move", Some("former-album"), vec![]));
    organization.validate().unwrap();
    assert_eq!(
        organization
            .album_id_for_track("former-track")
            .unwrap()
            .as_deref(),
        Some("album-b")
    );
    organization
        .choices
        .push(choice("other", Some("album-a"), vec![]));
    assert_eq!(organization.album_id_for_track("track-a").unwrap(), None);
    organization
        .choices
        .push(choice("resolve", None, vec!["move".into(), "other".into()]));
    assert_eq!(
        organization
            .album_id_for_track("track-a")
            .unwrap()
            .as_deref(),
        Some("album-a")
    );
}

#[test]
fn cluster_persistence_fixture_matches_native_identities_locations_and_pending_state()
-> anyhow::Result<()> {
    let fixture: serde_json::Value =
        serde_json::from_slice(include_bytes!("../fixtures/cluster-state.json"))?;
    let inventory: syncstr_headless::cluster::Inventory =
        serde_json::from_value(fixture["inventory"].clone())?;
    let change: syncstr_headless::cluster::PendingChange =
        serde_json::from_value(fixture["change"].clone())?;
    let job: syncstr_headless::cluster::TransferJob =
        serde_json::from_value(fixture["job"].clone())?;
    let capabilities: syncstr_headless::cluster::Capabilities =
        serde_json::from_value(fixture["capabilities"].clone())?;
    assert_eq!(inventory.objects.len(), 1);
    assert_eq!(inventory.objects[0].locations.len(), 2);
    assert_eq!(inventory.objects[0].bytes, 3);
    assert_eq!(job.state, syncstr_headless::cluster::JobState::Queued);
    assert!(!capabilities.allows_automatic_writer());
    assert_eq!(serde_json::to_value(inventory)?, fixture["inventory"]);
    assert_eq!(serde_json::to_value(change)?, fixture["change"]);
    assert_eq!(serde_json::to_value(job)?, fixture["job"]);
    assert_eq!(serde_json::to_value(capabilities)?, fixture["capabilities"]);
    Ok(())
}
#[cfg(feature = "p2p")]
#[tokio::test]
async fn signed_addition_time_survives_replay_and_restart() -> anyhow::Result<()> {
    let fixture: serde_json::Value =
        serde_json::from_slice(include_bytes!("../fixtures/cluster-signed.json"))?;
    let proof: syncstr_headless::enrollment::Proof =
        serde_json::from_value(fixture["membership"].clone())?;
    for (case, expected) in [
        (&fixture, None),
        (&fixture["addedAtChange"], Some(1_700_000_000_123)),
    ] {
        let root = tempfile::tempdir()?;
        let client =
            syncstr_headless::peer::Identity::from_secret(&root.path().join("identity"), [9; 32])?;
        let grant = proof
            .grants
            .iter()
            .find(|grant| grant.member == client.id().to_string())
            .unwrap();
        let change: syncstr_headless::cluster_changes::Change =
            serde_json::from_value(case["change"].clone())?;
        assert_eq!(
            String::from_utf8(change.signing_bytes()?)?,
            case["signingPayload"].as_str().unwrap()
        );
        let path = root.path().join("data");
        let store = syncstr_headless::store::Store::open(&path)?;
        store
            .join_cluster(
                &client,
                grant.issuer.parse()?,
                grant.id.clone(),
                proof.clone(),
            )
            .await?;
        let mut tampered = change.clone();
        let syncstr_headless::cluster_changes::Action::Import { entry, .. } = &mut tampered.action
        else {
            unreachable!()
        };
        entry.track.added_at = Some(1);
        assert!(
            store
                .apply_cluster_changes(change.author.clone(), vec![tampered])
                .await
                .is_err()
        );
        store
            .apply_cluster_changes(change.author.clone(), vec![change.clone()])
            .await?;
        store
            .project_cluster_metadata(change.object.clone())
            .await?;
        drop(store);
        let reopened = syncstr_headless::store::Store::open(&path)?;
        reopened
            .apply_cluster_changes(change.author.clone(), vec![change.clone()])
            .await?;
        assert_eq!(reopened.cluster_changes().await?, vec![change]);
        assert_eq!(
            reopened.catalog().await?.entries[0].track.added_at,
            expected
        );
    }
    Ok(())
}
