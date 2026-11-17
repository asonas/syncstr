fn observer_profile(selected: Option<&str>) -> windows::core::Result<String> {
    use windows::core::Interface as _;
    unsafe {
        let profiles: windows::Win32::UI::TextServices::ITfInputProcessorProfiles =
            windows::Win32::System::Com::CoCreateInstance(
                &windows::Win32::UI::TextServices::CLSID_TF_InputProcessorProfiles,
                None,
                windows::Win32::System::Com::CLSCTX_INPROC_SERVER,
            )?;
        let manager: windows::Win32::UI::TextServices::ITfInputProcessorProfileMgr =
            profiles.cast()?;
        if let Some(selected) = selected {
            let enumerator = profiles.EnumLanguageProfiles(0x0411)?;
            let mut matches = Vec::new();
            loop {
                let mut item = [windows::Win32::UI::TextServices::TF_LANGUAGEPROFILE::default()];
                let mut fetched = 0;
                enumerator.Next(&mut item, &mut fetched)?;
                if fetched == 0 {
                    break;
                }
                let item = item[0];
                if item.catid != windows::Win32::UI::TextServices::GUID_TFCAT_TIP_KEYBOARD {
                    continue;
                }
                let description = profiles
                    .GetLanguageProfileDescription(&item.clsid, item.langid, &item.guidProfile)
                    .map_err(|error| {
                        windows::core::Error::new(
                            error.code(),
                            format!("Profile description: {error}"),
                        )
                    })?
                    .to_string();
                if description == selected {
                    matches.push(item);
                }
            }
            if matches.len() != 1 {
                return Err(windows::core::Error::new(
                    windows::core::HRESULT(0x80070057u32 as i32),
                    "Expected one installed IME profile",
                ));
            }
            let item = matches[0];
            manager
                .ActivateProfile(
                    windows::Win32::UI::TextServices::TF_PROFILETYPE_INPUTPROCESSOR,
                    item.langid,
                    &item.clsid,
                    &item.guidProfile,
                    windows::Win32::UI::Input::KeyboardAndMouse::HKL::default(),
                    windows::Win32::UI::TextServices::TF_IPPMF_FORSESSION,
                )
                .map_err(|error| {
                    windows::core::Error::new(error.code(), format!("ActivateProfile: {error}"))
                })?;
        }
        let mut profile = windows::Win32::UI::TextServices::TF_INPUTPROCESSORPROFILE::default();
        manager.GetActiveProfile(
            &windows::Win32::UI::TextServices::GUID_TFCAT_TIP_KEYBOARD,
            &mut profile,
        )?;
        let description = profiles
            .GetLanguageProfileDescription(&profile.clsid, profile.langid, &profile.guidProfile)?
            .to_string();
        if selected.is_some_and(|selected| selected != description) {
            return Err(windows::core::Error::new(
                windows::core::HRESULT(0x80004005u32 as i32),
                "Requested IME did not become active",
            ));
        }
        Ok(description)
    }
}

fn main() -> windows::core::Result<()> {
    let selection = std::env::args().nth(1);
    let selected = match selection.as_deref() {
        None => None,
        Some("microsoft") => Some("Microsoft IME"),
        Some("google") => Some("Google 日本語入力"),
        _ => {
            return Err(windows::core::Error::new(
                windows::core::HRESULT(0x80070057u32 as i32),
                "Usage: ime_identity [microsoft|google]",
            ));
        }
    };
    unsafe {
        windows::Win32::System::Com::CoInitializeEx(
            None,
            windows::Win32::System::Com::COINIT_APARTMENTTHREADED,
        )
        .ok()?;
    }
    let profile = observer_profile(selected);
    unsafe {
        windows::Win32::System::Com::CoUninitialize();
    }
    let reports: Vec<_> = ["Win32", "Slint", "gpui"]
        .into_iter()
        .map(|candidate| unsafe {
            let title = windows::core::HSTRING::from(format!("ASO-51 — {candidate}"));
            match windows::Win32::UI::WindowsAndMessaging::FindWindowW(None, &title) {
                Ok(window) => {
                    let thread = windows::Win32::UI::WindowsAndMessaging::GetWindowThreadProcessId(
                        window, None,
                    );
                    let layout =
                        windows::Win32::UI::Input::KeyboardAndMouse::GetKeyboardLayout(thread);
                    let mut description = [0u16; 256];
                    let length = windows::Win32::UI::Input::Ime::ImmGetDescriptionW(
                        layout,
                        Some(&mut description),
                    );
                    serde_json::json!({
                        "candidate":candidate,
                        "dpi":windows::Win32::UI::HiDpi::GetDpiForWindow(window),
                        "keyboard_layout":format!("{:X}",layout.0 as usize),
                        "ime_description":String::from_utf16_lossy(&description[..length as usize]),
                    })
                }
                Err(_) => {
                    serde_json::json!({"candidate":candidate,"error":"Prototype window not found"})
                }
            }
        })
        .collect();
    println!(
        "{}",
        serde_json::to_string_pretty(&serde_json::json!({"observer_active_profile":profile.as_ref().map(String::as_str).unwrap_or("Unknown"),"windows":reports})).expect("serializable metadata")
    );
    profile.map(|_| ())
}
