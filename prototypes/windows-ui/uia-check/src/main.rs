use windows::Win32::UI::Accessibility as uia;

fn runtime_id(element: &uia::IUIAutomationElement) -> windows::core::Result<Vec<i32>> {
    unsafe {
        let array = element.GetRuntimeId()?;
        if array.is_null() {
            return Ok(vec![]);
        }
        let result = (|| {
            let lower = windows::Win32::System::Ole::SafeArrayGetLBound(array, 1)?;
            let upper = windows::Win32::System::Ole::SafeArrayGetUBound(array, 1)?;
            let mut values = Vec::new();
            for index in lower..=upper {
                let mut value = 0i32;
                windows::Win32::System::Ole::SafeArrayGetElement(
                    array,
                    &index,
                    (&mut value as *mut i32).cast(),
                )?;
                values.push(value);
            }
            Ok(values)
        })();
        windows::Win32::System::Ole::SafeArrayDestroy(array)?;
        result
    }
}

fn snapshot(
    automation: &uia::IUIAutomation,
    element: &uia::IUIAutomationElement,
    pid: i32,
) -> windows::core::Result<serde_json::Value> {
    unsafe {
        if element.CurrentProcessId()? != pid {
            return Ok(serde_json::json!({"outside_probe": true}));
        }
        let position = element.GetCurrentPropertyValueEx(uia::UIA_PositionInSetPropertyId, true)?;
        let size = element.GetCurrentPropertyValueEx(uia::UIA_SizeOfSetPropertyId, true)?;
        Ok(serde_json::json!({
            "name": element.CurrentName()?.to_string(),
            "control_type": element.CurrentControlType()?.0,
            "has_keyboard_focus": element.CurrentHasKeyboardFocus()?.as_bool(),
            "position_in_set": i32::try_from(&position).ok(),
            "position_in_set_supported": !automation.CheckNotSupported(&position)?.as_bool(),
            "size_of_set": i32::try_from(&size).ok(),
            "size_of_set_supported": !automation.CheckNotSupported(&size)?.as_bool(),
            "runtime_id": runtime_id(element)?,
        }))
    }
}

fn find(
    automation: &uia::IUIAutomation,
    root: &uia::IUIAutomationElement,
    name: &str,
    role: uia::UIA_CONTROLTYPE_ID,
) -> windows::core::Result<uia::IUIAutomationElement> {
    unsafe {
        let condition = automation.CreatePropertyCondition(
            uia::UIA_NamePropertyId,
            &windows::Win32::System::Variant::VARIANT::from(name),
        )?;
        let role = automation.CreatePropertyCondition(
            uia::UIA_ControlTypePropertyId,
            &windows::Win32::System::Variant::VARIANT::from(role.0),
        )?;
        let condition = automation.CreateAndCondition(&condition, &role)?;
        root.FindFirst(uia::TreeScope_Descendants, &condition)
    }
}

fn key(
    hwnd: windows::Win32::Foundation::HWND,
    key: windows::Win32::UI::Input::KeyboardAndMouse::VIRTUAL_KEY,
    shift: bool,
) -> windows::core::Result<()> {
    use windows::Win32::UI::Input::KeyboardAndMouse as keyboard;
    unsafe {
        if windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow() != hwnd {
            return Err(windows::core::Error::new(
                windows::core::HRESULT(0x80004005u32 as i32),
                "Foreground changed; no input sent",
            ));
        }
        let event = |code, flags| keyboard::INPUT {
            r#type: keyboard::INPUT_KEYBOARD,
            Anonymous: keyboard::INPUT_0 {
                ki: keyboard::KEYBDINPUT {
                    wVk: code,
                    dwFlags: flags,
                    ..Default::default()
                },
            },
        };
        let mut events = vec![];
        if shift {
            events.push(event(keyboard::VK_SHIFT, keyboard::KEYBD_EVENT_FLAGS(0)));
        }
        events.push(event(key, keyboard::KEYBD_EVENT_FLAGS(0)));
        events.push(event(key, keyboard::KEYEVENTF_KEYUP));
        if shift {
            events.push(event(keyboard::VK_SHIFT, keyboard::KEYEVENTF_KEYUP));
        }
        let sent = keyboard::SendInput(&events, std::mem::size_of::<keyboard::INPUT>() as i32);
        if sent != events.len() as u32 {
            return Err(windows::core::Error::from_thread());
        }
    }
    std::thread::sleep(std::time::Duration::from_millis(700));
    Ok(())
}

fn state(
    automation: &uia::IUIAutomation,
    list: &uia::IUIAutomationElement,
    pid: i32,
) -> windows::core::Result<serde_json::Value> {
    unsafe {
        let focus = snapshot(automation, &automation.GetFocusedElement()?, pid)?;
        let selection = match list
            .GetCurrentPatternAs::<uia::IUIAutomationSelectionPattern>(uia::UIA_SelectionPatternId)
        {
            Ok(pattern) => {
                let items = pattern.GetCurrentSelection()?;
                if items.Length()? > 0 {
                    Some(snapshot(automation, &items.GetElement(0)?, pid)?)
                } else {
                    None
                }
            }
            Err(_) => None,
        };
        Ok(serde_json::json!({"focus": focus, "selection": selection}))
    }
}

fn probe(
    automation: &uia::IUIAutomation,
    candidate: &str,
) -> windows::core::Result<serde_json::Value> {
    use windows::Win32::UI::Input::KeyboardAndMouse as keyboard;
    use windows::Win32::UI::WindowsAndMessaging as messaging;
    unsafe {
        let title = format!(
            "ASO-51 — {}",
            if candidate == "slint" {
                "Slint"
            } else if candidate == "win32" {
                "Win32"
            } else {
                "gpui"
            }
        );
        let hwnd = messaging::FindWindowW(None, &windows::core::HSTRING::from(title))?;
        let mut pid = 0;
        messaging::GetWindowThreadProcessId(hwnd, Some(&mut pid));
        // Verify the executable as well as its unique window title before sending input.
        let process = windows::Win32::System::Threading::OpenProcess(
            windows::Win32::System::Threading::PROCESS_QUERY_LIMITED_INFORMATION,
            false,
            pid,
        )?;
        let mut path = [0u16; 32768];
        let mut length = path.len() as u32;
        let queried = windows::Win32::System::Threading::QueryFullProcessImageNameW(
            process,
            windows::Win32::System::Threading::PROCESS_NAME_WIN32,
            windows::core::PWSTR(path.as_mut_ptr()),
            &mut length,
        );
        windows::Win32::Foundation::CloseHandle(process)?;
        queried?;
        let path = std::path::PathBuf::from(String::from_utf16_lossy(&path[..length as usize]));
        if path.file_name()
            != Some(std::ffi::OsStr::new(&format!(
                "toolkit-probe-{candidate}.exe"
            )))
        {
            return Err(windows::core::Error::new(
                windows::core::HRESULT(0x80004005u32 as i32),
                "Window is not a probe executable; no input sent",
            ));
        }
        let pid = pid as i32;
        let root = automation.ElementFromHandle(hwnd)?;
        if root.CurrentProcessId()? != pid {
            return Err(windows::core::Error::empty());
        }
        let _ = messaging::SetForegroundWindow(hwnd);
        std::thread::sleep(std::time::Duration::from_millis(300));
        let search = find(automation, &root, "Search", uia::UIA_EditControlTypeId)?;
        let list = find(automation, &root, "Tracks", uia::UIA_ListControlTypeId)?;
        let button = find(automation, &root, "Play", uia::UIA_ButtonControlTypeId)
            .or_else(|_| find(automation, &root, "Pause", uia::UIA_ButtonControlTypeId))?;
        let controls = serde_json::json!({"search": snapshot(automation,&search,pid)?, "list": snapshot(automation,&list,pid)?, "button": snapshot(automation,&button,pid)?});
        // Clear an earlier manual query through the search field's public value pattern.
        let value = search
            .GetCurrentPatternAs::<uia::IUIAutomationValuePattern>(uia::UIA_ValuePatternId)?;
        value.SetValue(&windows::core::BSTR::from(""))?;
        if !value.CurrentValue()?.is_empty() {
            return Err(windows::core::Error::new(
                windows::core::HRESULT(0x80004005u32 as i32),
                "Search value did not clear",
            ));
        }
        let _ = messaging::SetForegroundWindow(hwnd);
        std::thread::sleep(std::time::Duration::from_millis(300));
        search.SetFocus()?;
        std::thread::sleep(std::time::Duration::from_millis(700));
        if !search.CurrentHasKeyboardFocus()?.as_bool() {
            return Err(windows::core::Error::new(
                windows::core::HRESULT(0x80004005u32 as i32),
                "Could not establish initial Search focus",
            ));
        }
        let mut steps =
            vec![serde_json::json!({"step":"search", "state":state(automation,&list,pid)?})];
        key(hwnd, keyboard::VK_TAB, false)?;
        steps.push(serde_json::json!({"step":"tab_to_list", "state":state(automation,&list,pid)?}));
        for (label, code) in [
            ("home", keyboard::VK_HOME),
            ("down", keyboard::VK_DOWN),
            ("page_down", keyboard::VK_NEXT),
            ("end", keyboard::VK_END),
            ("home_again", keyboard::VK_HOME),
        ] {
            key(hwnd, code, false)?;
            steps.push(serde_json::json!({"step":label,"state":state(automation,&list,pid)?}));
        }
        let first = state(automation, &list, pid)?;
        for _ in 0..9 {
            key(hwnd, keyboard::VK_DOWN, false)?;
        }
        let tenth = state(automation, &list, pid)?;
        steps.push(serde_json::json!({"step":"duplicate_titles", "first":first,"tenth":tenth}));
        key(hwnd, keyboard::VK_TAB, false)?;
        let before = snapshot(automation, &button, pid)?;
        steps
            .push(serde_json::json!({"step":"tab_to_button","state":state(automation,&list,pid)?}));
        key(hwnd, keyboard::VK_SPACE, false)?;
        let after = snapshot(automation, &button, pid)?;
        steps.push(serde_json::json!({"step":"space","before":before,"after":after}));
        key(hwnd, keyboard::VK_TAB, true)?;
        steps.push(
            serde_json::json!({"step":"shift_tab_to_list","state":state(automation,&list,pid)?}),
        );
        key(hwnd, keyboard::VK_TAB, true)?;
        steps.push(
            serde_json::json!({"step":"shift_tab_to_search","state":state(automation,&list,pid)?}),
        );
        let checks = checks(&steps);
        Ok(
            serde_json::json!({"candidate":candidate,"controls":controls,"checks":checks,"steps":steps}),
        )
    }
}

fn checks(steps: &[serde_json::Value]) -> serde_json::Value {
    let step = |name| {
        steps
            .iter()
            .find(|step| step["step"] == name)
            .expect("recorded step")
    };
    let focus = |name| &step(name)["state"]["focus"];
    let focused_type = |name, role| {
        focus(name)["control_type"] == role && focus(name)["has_keyboard_focus"] == true
    };
    let first = &step("duplicate_titles")["first"]["focus"];
    let tenth = &step("duplicate_titles")["tenth"]["focus"];
    let space = step("space");
    let duplicate_row = |row: &serde_json::Value| {
        row["name"]
            .as_str()
            .is_some_and(|name| name.starts_with("Intro — "))
            && row["control_type"] == 50007
            && row["has_keyboard_focus"] == true
    };
    let positions = [
        ("home", 1, "Intro — Example Artist 00"),
        ("down", 2, "東京 0001 — Example Artist 01"),
        ("end", 5000, "Intro — Example Artist 04"),
    ]
    .iter()
    .all(|(name, position, title)| {
        focused_type(name, 50007)
            && focus(name)["name"] == *title
            && focus(name)["position_in_set"] == *position
            && focus(name)["size_of_set"] == 5000
    });
    serde_json::json!({
        "tab_sequence": focused_type("search",50004)
            && focused_type("tab_to_list",50007)
            && focused_type("tab_to_button",50000)
            && focused_type("shift_tab_to_list",50007)
            && focused_type("shift_tab_to_search",50004),
        "row_navigation_and_position": positions
            && focused_type("page_down",50007)
            && focus("page_down")["position_in_set"].as_i64().is_some_and(|position| position>2 && position<5000)
            && focus("page_down")["size_of_set"] == 5000,
        "duplicate_runtime_ids": duplicate_row(first) && duplicate_row(tenth)
            && first["runtime_id"].as_array().is_some_and(|id| !id.is_empty())
            && tenth["runtime_id"].as_array().is_some_and(|id| !id.is_empty())
            && first["runtime_id"] != tenth["runtime_id"],
        "space_updates_button": space["before"]["has_keyboard_focus"] == true
            && space["after"]["has_keyboard_focus"] == true
            && ((space["before"]["name"] == "Play" && space["after"]["name"] == "Pause")
                || (space["before"]["name"] == "Pause" && space["after"]["name"] == "Play")),
    })
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    unsafe {
        windows::Win32::System::Com::CoInitializeEx(
            None,
            windows::Win32::System::Com::COINIT_MULTITHREADED,
        )
        .ok()?;
    }
    let result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let automation: uia::IUIAutomation = unsafe {
            windows::Win32::System::Com::CoCreateInstance(
                &uia::CUIAutomation8,
                None,
                windows::Win32::System::Com::CLSCTX_INPROC_SERVER,
            )?
        };
        {
            use windows::core::Interface as _;
            let options: uia::IUIAutomation2 = automation.cast()?;
            unsafe {
                options.SetConnectionTimeout(3000)?;
                options.SetTransactionTimeout(3000)?;
            }
        }
        let mut reports = vec![];
        for candidate in ["win32", "slint", "gpui"] {
            eprintln!("Checking {candidate}");
            reports.push(match probe(&automation, candidate) {
                Ok(report) => report,
                Err(error) => serde_json::json!({"candidate":candidate,"error":error.to_string()}),
            });
        }
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({"reports":reports}))?
        );
        if reports.iter().any(|report| report.get("error").is_some()) {
            return Err("At least one probe could not be inspected; see JSON errors".into());
        }
        Ok(())
    })();
    unsafe {
        windows::Win32::System::Com::CoUninitialize();
    }
    result
}
