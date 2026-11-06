fn main() -> Result<(), Box<dyn std::error::Error>> {
    let command = std::env::args().nth(1).unwrap_or_else(|| "observe".into());
    if !matches!(command.as_str(), "observe" | "normal" | "bottom") {
        return Err("Usage: windows-ime-probe [observe|normal|bottom]".into());
    }
    unsafe {
        windows::Win32::UI::HiDpi::SetProcessDpiAwarenessContext(
            windows::Win32::UI::HiDpi::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        )?;
        let window = windows::Win32::UI::WindowsAndMessaging::FindWindowW(
            None,
            windows::core::w!("Syncstr Desktop"),
        )
        .map_err(|_| "Syncstr Desktop window not found")?;
        let mut pid = 0;
        windows::Win32::UI::WindowsAndMessaging::GetWindowThreadProcessId(window, Some(&mut pid));
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
        if path.file_name() != Some(std::ffi::OsStr::new("syncstr-desktop.exe")) {
            return Err("Window is not the desktop scaffold executable".into());
        }
        if windows::Win32::UI::WindowsAndMessaging::IsIconic(window).as_bool()
            || windows::Win32::UI::WindowsAndMessaging::IsZoomed(window).as_bool()
        {
            return Err("Restore the window before inspection".into());
        }
        let monitor = windows::Win32::Graphics::Gdi::MonitorFromWindow(
            window,
            windows::Win32::Graphics::Gdi::MONITOR_DEFAULTTONEAREST,
        );
        let mut info = windows::Win32::Graphics::Gdi::MONITORINFO {
            cbSize: std::mem::size_of::<windows::Win32::Graphics::Gdi::MONITORINFO>() as u32,
            ..Default::default()
        };
        windows::Win32::Graphics::Gdi::GetMonitorInfoW(monitor, &mut info).ok()?;
        let mut rect = windows::Win32::Foundation::RECT::default();
        windows::Win32::UI::WindowsAndMessaging::GetWindowRect(window, &mut rect)?;
        let dpi = windows::Win32::UI::HiDpi::GetDpiForWindow(window) as i32;
        if command != "observe" {
            let x = info.rcWork.left
                + (info.rcWork.right - info.rcWork.left - (rect.right - rect.left)) / 2;
            let y = if command == "bottom" {
                info.rcWork.bottom - 150 * dpi / 96
            } else {
                info.rcWork.top
                    + (info.rcWork.bottom - info.rcWork.top - (rect.bottom - rect.top)) / 2
            };
            windows::Win32::UI::WindowsAndMessaging::SetWindowPos(
                window,
                None,
                x,
                y,
                0,
                0,
                windows::Win32::UI::WindowsAndMessaging::SWP_NOSIZE
                    | windows::Win32::UI::WindowsAndMessaging::SWP_NOZORDER
                    | windows::Win32::UI::WindowsAndMessaging::SWP_NOACTIVATE,
            )?;
            windows::Win32::UI::WindowsAndMessaging::GetWindowRect(window, &mut rect)?;
            if rect.left != x || rect.top != y {
                return Err("Placement did not apply".into());
            }
        }
        println!(
            "{}",
            serde_json::json!({
                "dpi":dpi, "window":[rect.left,rect.top,rect.right,rect.bottom],
                "work_area":[info.rcWork.left,info.rcWork.top,info.rcWork.right,info.rcWork.bottom],
            })
        );
    }
    Ok(())
}
