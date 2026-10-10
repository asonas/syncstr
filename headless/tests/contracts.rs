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
