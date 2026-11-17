pub struct Track {
    pub id: usize,
    pub title: String,
    pub artist: String,
}

impl Track {
    pub fn row(&self) -> String {
        format!("{} — {}", self.title, self.artist)
    }
}

pub fn tracks() -> Vec<Track> {
    (0..5000)
        .map(|id| Track {
            id,
            title: if id == 0 || (id + 1) % 10 == 0 {
                "Intro".into()
            } else if id % 100 == 1 {
                format!("東京 {id:04}")
            } else {
                format!("Night Train {id:04}")
            },
            artist: format!("Example Artist {:02}", id % 37),
        })
        .collect()
}

pub fn matching(tracks: &[Track], query: &str) -> Vec<usize> {
    let query = query.to_lowercase();
    tracks
        .iter()
        .filter(|t| t.title.to_lowercase().contains(&query))
        .map(|t| t.id)
        .collect()
}

pub struct MediaControls {
    controls: windows::Media::SystemMediaTransportControls,
    token: i64,
}

impl MediaControls {
    pub fn new(
        hwnd: windows::Win32::Foundation::HWND,
        on_button: impl Fn(bool) + Send + Sync + 'static,
    ) -> windows::core::Result<Self> {
        unsafe {
            windows::Win32::System::WinRT::RoInitialize(
                windows::Win32::System::WinRT::RO_INIT_SINGLETHREADED,
            )?;
        }
        let interop = windows::core::factory::<
            windows::Media::SystemMediaTransportControls,
            windows::Win32::System::WinRT::ISystemMediaTransportControlsInterop,
        >()?;
        let controls: windows::Media::SystemMediaTransportControls =
            unsafe { interop.GetForWindow(hwnd)? };
        controls.SetIsEnabled(true)?;
        controls.SetIsPlayEnabled(true)?;
        controls.SetIsPauseEnabled(true)?;
        let token = controls.ButtonPressed(&windows::Foundation::TypedEventHandler::new(
            move |_,
                  args: windows::core::Ref<
                windows::Media::SystemMediaTransportControlsButtonPressedEventArgs,
            >| {
                let button = args
                    .as_ref()
                    .ok_or_else(windows::core::Error::empty)?
                    .Button()?;
                if button == windows::Media::SystemMediaTransportControlsButton::Play {
                    on_button(true);
                } else if button == windows::Media::SystemMediaTransportControlsButton::Pause {
                    on_button(false);
                }
                Ok(())
            },
        ))?;
        Ok(Self { controls, token })
    }

    pub fn update(&self, track: &Track, playing: bool) -> windows::core::Result<()> {
        let updater = self.controls.DisplayUpdater()?;
        updater.SetType(windows::Media::MediaPlaybackType::Music)?;
        let music = updater.MusicProperties()?;
        music.SetTitle(&windows::core::HSTRING::from(&track.title))?;
        music.SetArtist(&windows::core::HSTRING::from(&track.artist))?;
        updater.Update()?;
        self.controls.SetPlaybackStatus(if playing {
            windows::Media::MediaPlaybackStatus::Playing
        } else {
            windows::Media::MediaPlaybackStatus::Paused
        })
    }
}

impl Drop for MediaControls {
    fn drop(&mut self) {
        let _ = self.controls.RemoveButtonPressed(self.token);
        let _ = self.controls.SetIsEnabled(false);
        unsafe {
            windows::Win32::System::WinRT::RoUninitialize();
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn fixture_and_search_match_the_probe_contract() {
        let tracks = crate::tracks();
        assert_eq!(tracks.len(), 5000);
        for index in (9..5000).step_by(10) {
            assert!(
                tracks[..index]
                    .iter()
                    .any(|earlier| earlier.title == tracks[index].title)
            );
        }
        assert_eq!(crate::matching(&tracks, "INTRO").len(), 501);
        assert_eq!(crate::matching(&tracks, "東京").len(), 50);
        assert_eq!(crate::matching(&tracks, "Night Train 0042"), [42]);
        assert!(crate::matching(&tracks, "missing title").is_empty());
        assert_eq!(crate::matching(&tracks, "").len(), 5000);
    }
}
