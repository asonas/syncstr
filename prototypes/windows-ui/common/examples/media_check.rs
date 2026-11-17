fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manager =
        windows::Media::Control::GlobalSystemMediaTransportControlsSessionManager::RequestAsync()?
            .join()?;
    let sessions = manager.GetSessions()?;
    let mut checked = 0;
    for index in 0..sessions.Size()? {
        let session = sessions.GetAt(index)?;
        let app_id = session.SourceAppUserModelId()?.to_string();
        let Some(label) = ["win32", "slint", "gpui"]
            .into_iter()
            .find(|label| app_id.contains(&format!("toolkit-probe-{label}")))
        else {
            continue;
        };
        let properties = session.TryGetMediaPropertiesAsync()?.join()?;
        let title = properties.Title()?;
        assert!(!title.is_empty(), "{label}: missing track title");
        println!("{label}: title = {title}");
        for playing in [true, false] {
            let accepted = if playing {
                session.TryPlayAsync()?.join()?
            } else {
                session.TryPauseAsync()?.join()?
            };
            assert!(accepted, "{label}: system rejected playback request");
            let expected = if playing {
                windows::Media::Control::GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing
            } else {
                windows::Media::Control::GlobalSystemMediaTransportControlsSessionPlaybackStatus::Paused
            };
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
            loop {
                let actual = session.GetPlaybackInfo()?.PlaybackStatus()?;
                if actual == expected {
                    break;
                }
                assert!(
                    std::time::Instant::now() < deadline,
                    "{label}: UI did not acknowledge playback request"
                );
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            println!(
                "{label}: system {} request acknowledged",
                if playing { "play" } else { "pause" }
            );
        }
        checked += 1;
    }
    assert_eq!(
        checked, 3,
        "Start exactly one instance of each prototype before this check"
    );
    Ok(())
}
