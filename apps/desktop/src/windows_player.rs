pub struct Player {
    engine: windows::Media::Playback::MediaPlayer,
    source: Option<windows::Media::Core::MediaSource>,
    asset: Option<syncstr_headless::catalog_client::VerifiedAudio>,
    ended: std::sync::Arc<std::sync::atomic::AtomicBool>,
    failure: std::sync::Arc<std::sync::Mutex<Option<String>>>,
}

impl Player {
    pub fn new(muted: bool) -> anyhow::Result<Self> {
        unsafe {
            windows::Win32::System::WinRT::RoInitialize(
                windows::Win32::System::WinRT::RO_INIT_MULTITHREADED,
            )?;
        }
        let engine = windows::Media::Playback::MediaPlayer::new()?;
        engine.SetIsMuted(muted)?;
        let ended = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = ended.clone();
        engine.MediaEnded(&windows::Foundation::TypedEventHandler::new(move |_, _| {
            flag.store(true, std::sync::atomic::Ordering::Release);
            Ok(())
        }))?;
        let failure: std::sync::Arc<std::sync::Mutex<Option<String>>> = Default::default();
        let errors = failure.clone();
        engine.MediaFailed(&windows::Foundation::TypedEventHandler::<
            windows::Media::Playback::MediaPlayer,
            windows::Media::Playback::MediaPlayerFailedEventArgs,
        >::new(move |_, args| {
            if let Some(args) = args.as_ref()
                && let Ok(message) = args.ErrorMessage()
                && let Ok(mut error) = errors.lock()
            {
                *error = Some(message.to_string());
            }
            Ok(())
        }))?;
        Ok(Self {
            engine,
            source: None,
            asset: None,
            ended,
            failure,
        })
    }

    pub fn play(
        &mut self,
        asset: syncstr_headless::catalog_client::VerifiedAudio,
    ) -> anyhow::Result<()> {
        self.stop()?;
        self.ended
            .store(false, std::sync::atomic::Ordering::Release);
        self.failure.lock().expect("audio failure").take();
        let file = windows::Storage::StorageFile::GetFileFromPathAsync(
            &windows::core::HSTRING::from(asset.path().to_string_lossy().as_ref()),
        )?
        .join()?;
        let source = windows::Media::Core::MediaSource::CreateFromStorageFile(&file)?;
        self.engine.SetSource(&source)?;
        self.source = Some(source);
        self.asset = Some(asset);
        self.engine.Play()?;
        Ok(())
    }

    pub fn pause(&self) -> anyhow::Result<()> {
        self.engine.Pause()?;
        Ok(())
    }
    pub fn resume(&self) -> anyhow::Result<()> {
        self.engine.Play()?;
        Ok(())
    }
    pub fn ended(&self) -> bool {
        self.ended.swap(false, std::sync::atomic::Ordering::AcqRel)
    }
    pub fn failure(&self) -> Option<String> {
        self.failure.lock().ok()?.take()
    }
    pub fn state(&self) -> anyhow::Result<(bool, f64, f64)> {
        let session = self.engine.PlaybackSession()?;
        Ok((
            session.PlaybackState()? == windows::Media::Playback::MediaPlaybackState::Playing,
            session.Position()?.Duration as f64 / 10_000_000.,
            session.NaturalDuration()?.Duration as f64 / 10_000_000.,
        ))
    }
    pub fn stop(&mut self) -> anyhow::Result<()> {
        self.engine.Pause()?;
        self.engine
            .SetSource(None::<&windows::Media::Playback::IMediaPlaybackSource>)?;
        if let Some(source) = self.source.take() {
            source.Close()?;
        }
        self.asset.take();
        Ok(())
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        let _ = self.stop();
        let _ = self.engine.Close();
        unsafe {
            windows::Win32::System::WinRT::RoUninitialize();
        }
    }
}
