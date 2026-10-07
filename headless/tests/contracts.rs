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
