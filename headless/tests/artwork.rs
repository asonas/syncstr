fn fixture() -> (syncstr_headless::organization::Organization, String, String) {
    let value: serde_json::Value =
        serde_json::from_str(include_str!("../fixtures/album-artwork.json")).unwrap();
    (
        serde_json::from_value(value["organization"].clone()).unwrap(),
        value["blue"].as_str().unwrap().into(),
        value["red"].as_str().unwrap().into(),
    )
}

#[cfg(feature = "p2p")]
#[test]
fn object_subset_keeps_cover_choices_and_excludes_unrelated_images() {
    let (mut organization, blue, red) = crate::fixture();
    organization.choices.push(syncstr_headless::organization::Choice {
        id: "manual-cover".into(), subject: "album-a".into(), kind: "artwork".into(),
        value: Some(red.clone()), parents: vec![],
    });
    let subset = organization.for_object(&"a".repeat(64)).unwrap();
    assert_eq!(subset.choices, organization.choices);
    let artwork = subset.artwork.unwrap();
    assert!(artwork.assets.contains_key(&blue));
    assert!(artwork.assets.contains_key(&red));
    assert_eq!(artwork.candidates.len(), 1);
    let unrelated = organization.for_object(&"b".repeat(64)).unwrap();
    assert!(unrelated.choices.is_empty());
    let artwork = unrelated.artwork.unwrap();
    assert!(artwork.assets.is_empty());
    assert!(artwork.candidates.is_empty());
    assert!(artwork.preferred.is_empty());
}

#[tokio::test]
async fn images_and_choice_history_survive_without_audio_and_invalid_delivery_rolls_back() {
    let (mut organization, blue, red) = crate::fixture();
    organization.validate().unwrap();
    organization
        .choices
        .push(syncstr_headless::organization::Choice {
            id: "choose-red".into(),
            subject: "album-a".into(),
            kind: "artwork".into(),
            value: Some(red),
            parents: vec![],
        });
    let root = tempfile::tempdir().unwrap();
    let store = syncstr_headless::store::Store::open(root.path()).unwrap();
    store
        .merge_organization(organization.clone())
        .await
        .unwrap();
    let saved = store.catalog().await.unwrap().organization;
    assert_eq!(saved.artwork, organization.artwork);
    assert_eq!(saved.choices, organization.choices);
    let mut invalid = organization.clone();
    invalid
        .artwork
        .as_mut()
        .unwrap()
        .assets
        .insert(blue.clone(), vec![0, 1, 2]);
    assert!(store.merge_organization(invalid).await.is_err());
    assert_eq!(store.catalog().await.unwrap().organization, saved);
    organization
        .choices
        .push(syncstr_headless::organization::Choice {
            id: "clear".into(),
            subject: "album-a".into(),
            kind: "artwork".into(),
            value: None,
            parents: vec!["choose-red".into()],
        });
    store
        .merge_organization(organization.clone())
        .await
        .unwrap();
    store.merge_organization(crate::fixture().0).await.unwrap();
    drop(store);
    let reopened = syncstr_headless::store::Store::open(root.path())
        .unwrap()
        .catalog()
        .await
        .unwrap();
    assert!(reopened.entries.is_empty());
    assert_eq!(
        reopened.organization.artwork.unwrap().assets,
        organization.artwork.unwrap().assets
    );
    assert!(
        reopened
            .organization
            .choices
            .iter()
            .any(|c| c.id == "clear")
    );
    assert_eq!(reopened.organization.preferred["artwork:album-a"], "clear");
}

#[test]
fn malformed_asset_and_revision_graphs_are_rejected() {
    use sha2::Digest as _;
    let (original, blue, _) = crate::fixture();
    let mut invalid = original.clone();
    let bytes = vec![
        0xff, 0xd8, 0xff, 0xc0, 0, 8, 8, 0, 1, 0, 1, 0, 0xff, 0xda, 0, 2, 0xff, 0xd9,
    ];
    invalid
        .artwork
        .as_mut()
        .unwrap()
        .assets
        .insert(hex::encode(sha2::Sha256::digest(&bytes)), bytes);
    assert!(invalid.validate().is_err());
    let mut invalid = original.clone();
    invalid.artwork.as_mut().unwrap().assets.remove(&blue);
    assert!(invalid.validate().is_err());
    let mut invalid = original;
    invalid.artwork.as_mut().unwrap().candidates[0]
        .parents
        .push("folder-first".into());
    assert!(invalid.validate().is_err());
}
