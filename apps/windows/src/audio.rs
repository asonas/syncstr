pub struct Apartment;

impl Apartment {
    pub fn initialize() -> windows::core::Result<Self> {
        unsafe {
            windows::Win32::System::WinRT::RoInitialize(
                windows::Win32::System::WinRT::RO_INIT_SINGLETHREADED,
            )?;
        }
        Ok(Self)
    }
}

impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe { windows::Win32::System::WinRT::RoUninitialize() };
    }
}

pub struct Playback {
    player: windows::Media::Playback::MediaPlayer,
    failure: std::sync::Arc<std::sync::Mutex<Option<String>>>,
    last_status: String,
}

impl Playback {
    pub fn open(path: &std::path::Path) -> anyhow::Result<Self> {
        let uri = url::Url::from_file_path(path)
            .map_err(|_| anyhow::anyhow!("Audio requires an absolute file path"))?;
        let player = windows::Media::Playback::MediaPlayer::new()?;
        let mut playback = Self {
            player,
            failure: Default::default(),
            last_status: String::new(),
        };
        let failure = playback.failure.clone();
        playback
            .player
            .MediaFailed(&windows::Foundation::TypedEventHandler::new(
                move |_,
                      args: windows::core::Ref<
                    windows::Media::Playback::MediaPlayerFailedEventArgs,
                >| {
                    let message = args
                        .as_ref()
                        .map(|args| {
                            format!(
                                "Audio playback failed: {} ({:?})",
                                args.ErrorMessage().unwrap_or_default(),
                                args.ExtendedErrorCode().unwrap_or_default()
                            )
                        })
                        .unwrap_or_else(|| "Audio playback failed".to_owned());
                    *failure.lock().unwrap() = Some(message);
                    Ok(())
                },
            ))?;
        let uri = windows::Foundation::Uri::CreateUri(&windows::core::HSTRING::from(uri.as_str()))?;
        let source = windows::Media::Core::MediaSource::CreateFromUri(&uri)?;
        playback.player.SetSource(&source)?;
        playback.player.Play()?;
        playback.last_status = "Opening saved audio locally.".to_owned();
        Ok(playback)
    }

    pub fn toggle_pause(&self) -> anyhow::Result<()> {
        let state = self.player.PlaybackSession()?.PlaybackState()?;
        if state == windows::Media::Playback::MediaPlaybackState::Playing {
            self.player.Pause()?;
        } else if state == windows::Media::Playback::MediaPlaybackState::Paused {
            self.player.Play()?;
        } else {
            anyhow::bail!("No active playback session");
        }
        Ok(())
    }

    pub fn changed_status(&mut self) -> anyhow::Result<Option<String>> {
        let message = if let Some(error) = self.failure.lock().unwrap().as_ref() {
            error.clone()
        } else {
            match self.player.PlaybackSession()?.PlaybackState()? {
                windows::Media::Playback::MediaPlaybackState::Playing => {
                    "Playing saved audio locally."
                }
                windows::Media::Playback::MediaPlaybackState::Paused => "Playback paused.",
                windows::Media::Playback::MediaPlaybackState::Buffering => "Buffering saved audio.",
                windows::Media::Playback::MediaPlaybackState::Opening => {
                    "Opening saved audio locally."
                }
                _ => "Playback stopped.",
            }
            .to_owned()
        };
        if message == self.last_status {
            Ok(None)
        } else {
            self.last_status = message.clone();
            Ok(Some(message))
        }
    }
}

impl Drop for Playback {
    fn drop(&mut self) {
        let _ = self.player.Close();
    }
}

#[cfg(test)]
mod tests {
    fn wait_until(mut condition: impl FnMut() -> bool) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        loop {
            unsafe {
                let mut message = windows::Win32::UI::WindowsAndMessaging::MSG::default();
                while windows::Win32::UI::WindowsAndMessaging::PeekMessageW(
                    &mut message,
                    None,
                    0,
                    0,
                    windows::Win32::UI::WindowsAndMessaging::PM_REMOVE,
                )
                .as_bool()
                {
                    let _ = windows::Win32::UI::WindowsAndMessaging::TranslateMessage(&message);
                    windows::Win32::UI::WindowsAndMessaging::DispatchMessageW(&message);
                }
            }
            if condition() {
                return;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "Playback did not reach the expected state"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    #[test]
    #[ignore = "requires an audio output device and SYNCSTR_AUDIO_TEST_FILES"]
    fn local_audio_plays_pauses_resumes_and_reports_invalid_media() {
        let _apartment = crate::audio::Apartment::initialize().unwrap();
        let files = std::env::var_os("SYNCSTR_AUDIO_TEST_FILES").expect("Set test audio paths");
        let files: Vec<_> = std::env::split_paths(&files).collect();
        assert!(!files.is_empty());
        for path in files {
            let playback = crate::audio::Playback::open(&path).unwrap();
            let session = playback.player.PlaybackSession().unwrap();
            wait_until(|| {
                assert!(
                    playback.failure.lock().unwrap().is_none(),
                    "{:?}",
                    playback.failure.lock().unwrap()
                );
                session.Position().unwrap().Duration > 5_000_000
            });
            playback.toggle_pause().unwrap();
            wait_until(|| {
                session.PlaybackState().unwrap()
                    == windows::Media::Playback::MediaPlaybackState::Paused
            });
            let paused = session.Position().unwrap().Duration;
            std::thread::sleep(std::time::Duration::from_millis(300));
            assert_eq!(session.Position().unwrap().Duration, paused);
            playback.toggle_pause().unwrap();
            wait_until(|| session.Position().unwrap().Duration > paused + 5_000_000);
            eprintln!("Playback, pause and resume passed for {}", path.display());
            drop(playback);
        }
        let directory = tempfile::tempdir().unwrap();
        let invalid = directory.path().join("invalid.mp3");
        std::fs::write(&invalid, b"invalid audio").unwrap();
        let mut playback = crate::audio::Playback::open(&invalid).unwrap();
        wait_until(|| playback.failure.lock().unwrap().is_some());
        assert!(
            playback
                .changed_status()
                .unwrap()
                .unwrap()
                .starts_with("Audio playback failed:")
        );
    }
}
