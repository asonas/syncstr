#![windows_subsystem = "windows"]
#![allow(unsafe_op_in_unsafe_fn)]

const SEARCH: usize = 101;
const LIST: usize = 102;
const PLAY: usize = 103;
const MEDIA_MESSAGE: u32 = windows::Win32::UI::WindowsAndMessaging::WM_APP + 1;

struct Probe {
    search: windows::Win32::Foundation::HWND,
    list: windows::Win32::Foundation::HWND,
    play: windows::Win32::Foundation::HWND,
    status: windows::Win32::Foundation::HWND,
    tracks: Vec<toolkit_probe_common::Track>,
    visible: Vec<usize>,
    selected: usize,
    playing: bool,
    media: Option<toolkit_probe_common::MediaControls>,
    font: windows::Win32::Graphics::Gdi::HFONT,
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain([0]).collect()
}

unsafe fn set_text(hwnd: windows::Win32::Foundation::HWND, text: &str) {
    let _ = windows::Win32::UI::WindowsAndMessaging::SetWindowTextW(
        hwnd,
        windows::core::PCWSTR(crate::wide(text).as_ptr()),
    );
}

impl Probe {
    unsafe fn refresh(&mut self) {
        crate::set_text(self.play, if self.playing { "&Pause" } else { "&Play" });
        let label = format!(
            "{}: {}",
            if self.playing { "Playing" } else { "Paused" },
            self.tracks[self.selected].row()
        );
        crate::set_text(self.status, &label);
        if let Some(media) = &self.media
            && let Err(error) = media.update(&self.tracks[self.selected], self.playing)
        {
            crate::set_text(self.status, &format!("SMTC update failed: {error}"));
        }
    }

    unsafe fn filter(&mut self) {
        let length = windows::Win32::UI::WindowsAndMessaging::GetWindowTextLengthW(self.search);
        let mut query = vec![0u16; length as usize + 1];
        let length =
            windows::Win32::UI::WindowsAndMessaging::GetWindowTextW(self.search, &mut query);
        self.visible = toolkit_probe_common::matching(
            &self.tracks,
            &String::from_utf16_lossy(&query[..length as usize]),
        );
        windows::Win32::UI::WindowsAndMessaging::SendMessageW(
            self.list,
            windows::Win32::UI::WindowsAndMessaging::WM_SETREDRAW,
            Some(windows::Win32::Foundation::WPARAM(0)),
            None,
        );
        windows::Win32::UI::WindowsAndMessaging::SendMessageW(
            self.list,
            windows::Win32::UI::WindowsAndMessaging::LB_RESETCONTENT,
            None,
            None,
        );
        for id in &self.visible {
            let row = crate::wide(&self.tracks[*id].row());
            windows::Win32::UI::WindowsAndMessaging::SendMessageW(
                self.list,
                windows::Win32::UI::WindowsAndMessaging::LB_ADDSTRING,
                None,
                Some(windows::Win32::Foundation::LPARAM(row.as_ptr() as isize)),
            );
        }
        let index = self
            .visible
            .iter()
            .position(|id| *id == self.selected)
            .unwrap_or(0);
        if let Some(id) = self.visible.get(index) {
            self.selected = *id;
            windows::Win32::UI::WindowsAndMessaging::SendMessageW(
                self.list,
                windows::Win32::UI::WindowsAndMessaging::LB_SETCURSEL,
                Some(windows::Win32::Foundation::WPARAM(index)),
                None,
            );
        }
        windows::Win32::UI::WindowsAndMessaging::SendMessageW(
            self.list,
            windows::Win32::UI::WindowsAndMessaging::WM_SETREDRAW,
            Some(windows::Win32::Foundation::WPARAM(1)),
            None,
        );
        let _ = windows::Win32::Graphics::Gdi::InvalidateRect(Some(self.list), None, true);
        self.refresh();
    }
}

unsafe fn child(
    parent: windows::Win32::Foundation::HWND,
    class: &str,
    text: &str,
    id: usize,
    extra: u32,
) -> windows::Win32::Foundation::HWND {
    windows::Win32::UI::WindowsAndMessaging::CreateWindowExW(
        windows::Win32::UI::WindowsAndMessaging::WINDOW_EX_STYLE::default(),
        windows::core::PCWSTR(crate::wide(class).as_ptr()),
        windows::core::PCWSTR(crate::wide(text).as_ptr()),
        windows::Win32::UI::WindowsAndMessaging::WINDOW_STYLE(
            windows::Win32::UI::WindowsAndMessaging::WS_CHILD.0
                | windows::Win32::UI::WindowsAndMessaging::WS_VISIBLE.0
                | extra,
        ),
        0,
        0,
        100,
        30,
        Some(parent),
        Some(windows::Win32::UI::WindowsAndMessaging::HMENU(id as *mut _)),
        None,
        None,
    )
    .expect("create standard control")
}

unsafe extern "system" fn window_proc(
    hwnd: windows::Win32::Foundation::HWND,
    message: u32,
    wparam: windows::Win32::Foundation::WPARAM,
    lparam: windows::Win32::Foundation::LPARAM,
) -> windows::Win32::Foundation::LRESULT {
    let ptr = windows::Win32::UI::WindowsAndMessaging::GetWindowLongPtrW(
        hwnd,
        windows::Win32::UI::WindowsAndMessaging::GWLP_USERDATA,
    ) as *mut Probe;
    match message {
        windows::Win32::UI::WindowsAndMessaging::WM_CREATE => {
            let tab = windows::Win32::UI::WindowsAndMessaging::WS_TABSTOP.0;
            crate::child(hwnd, "STATIC", "&Search", 201, 0);
            let search = crate::child(
                hwnd,
                "EDIT",
                "",
                SEARCH,
                tab | windows::Win32::UI::WindowsAndMessaging::WS_BORDER.0
                    | windows::Win32::UI::WindowsAndMessaging::ES_AUTOHSCROLL as u32,
            );
            crate::child(hwnd, "STATIC", "&Tracks", 202, 0);
            let list = crate::child(
                hwnd,
                "LISTBOX",
                "",
                LIST,
                tab | windows::Win32::UI::WindowsAndMessaging::WS_BORDER.0
                    | windows::Win32::UI::WindowsAndMessaging::WS_VSCROLL.0
                    | windows::Win32::UI::WindowsAndMessaging::LBS_NOTIFY as u32
                    | windows::Win32::UI::WindowsAndMessaging::LBS_NOINTEGRALHEIGHT as u32,
            );
            let play = crate::child(hwnd, "BUTTON", "&Play", PLAY, tab);
            let status = crate::child(hwnd, "STATIC", "", 203, 0);
            let font = windows::Win32::Graphics::Gdi::CreateFontW(
                -16 * windows::Win32::UI::HiDpi::GetDpiForWindow(hwnd) as i32 / 96,
                0,
                0,
                0,
                400,
                0,
                0,
                0,
                windows::Win32::Graphics::Gdi::DEFAULT_CHARSET,
                windows::Win32::Graphics::Gdi::OUT_DEFAULT_PRECIS,
                windows::Win32::Graphics::Gdi::CLIP_DEFAULT_PRECIS,
                windows::Win32::Graphics::Gdi::CLEARTYPE_QUALITY,
                0,
                windows::core::w!("Segoe UI"),
            );
            for control in [
                search,
                list,
                play,
                status,
                windows::Win32::UI::WindowsAndMessaging::GetDlgItem(Some(hwnd), 201).unwrap(),
                windows::Win32::UI::WindowsAndMessaging::GetDlgItem(Some(hwnd), 202).unwrap(),
            ] {
                windows::Win32::UI::WindowsAndMessaging::SendMessageW(
                    control,
                    windows::Win32::UI::WindowsAndMessaging::WM_SETFONT,
                    Some(windows::Win32::Foundation::WPARAM(font.0 as usize)),
                    Some(windows::Win32::Foundation::LPARAM(1)),
                );
            }
            let mut probe = Box::new(Probe {
                search,
                list,
                play,
                status,
                tracks: toolkit_probe_common::tracks(),
                visible: vec![],
                selected: 0,
                playing: false,
                media: None,
                font,
            });
            let raw_hwnd = hwnd.0 as isize;
            match toolkit_probe_common::MediaControls::new(hwnd, move |playing| {
                let _ = windows::Win32::UI::WindowsAndMessaging::PostMessageW(
                    Some(windows::Win32::Foundation::HWND(raw_hwnd as *mut _)),
                    MEDIA_MESSAGE,
                    windows::Win32::Foundation::WPARAM(playing as usize),
                    windows::Win32::Foundation::LPARAM(0),
                );
            }) {
                Ok(media) => probe.media = Some(media),
                Err(error) => {
                    windows::Win32::UI::WindowsAndMessaging::MessageBoxW(
                        Some(hwnd),
                        windows::core::PCWSTR(
                            crate::wide(&format!("SMTC initialization failed: {error}")).as_ptr(),
                        ),
                        windows::core::w!("Probe error"),
                        windows::Win32::UI::WindowsAndMessaging::MB_OK,
                    );
                }
            }
            probe.filter();
            windows::Win32::UI::WindowsAndMessaging::SetWindowLongPtrW(
                hwnd,
                windows::Win32::UI::WindowsAndMessaging::GWLP_USERDATA,
                Box::into_raw(probe) as isize,
            );
            let _ = windows::Win32::UI::Input::KeyboardAndMouse::SetFocus(Some(search));
        }
        windows::Win32::UI::WindowsAndMessaging::WM_SIZE if !ptr.is_null() => {
            let width = (lparam.0 & 0xffff) as i32;
            let height = ((lparam.0 >> 16) & 0xffff) as i32;
            let dpi = windows::Win32::UI::HiDpi::GetDpiForWindow(hwnd) as i32;
            let scale = |n: i32| n * dpi / 96;
            let ui = &*ptr;
            for (control, x, y, w, h) in [
                (
                    windows::Win32::UI::WindowsAndMessaging::GetDlgItem(Some(hwnd), 201).unwrap(),
                    scale(16),
                    scale(16),
                    scale(70),
                    scale(24),
                ),
                (
                    ui.search,
                    scale(90),
                    scale(12),
                    width - scale(106),
                    scale(30),
                ),
                (
                    windows::Win32::UI::WindowsAndMessaging::GetDlgItem(Some(hwnd), 202).unwrap(),
                    scale(16),
                    scale(50),
                    scale(70),
                    scale(24),
                ),
                (
                    ui.list,
                    scale(16),
                    scale(78),
                    width - scale(32),
                    (height - scale(164)).max(scale(60)),
                ),
                (
                    ui.play,
                    scale(16),
                    height - scale(70),
                    scale(100),
                    scale(36),
                ),
                (
                    ui.status,
                    scale(128),
                    height - scale(66),
                    width - scale(144),
                    scale(48),
                ),
            ] {
                let _ = windows::Win32::UI::WindowsAndMessaging::MoveWindow(
                    control,
                    x,
                    y,
                    w.max(1),
                    h,
                    true,
                );
            }
        }
        windows::Win32::UI::WindowsAndMessaging::WM_COMMAND if !ptr.is_null() => {
            let ui = &mut *ptr;
            let id = wparam.0 & 0xffff;
            let notification = wparam.0 >> 16;
            if id == SEARCH
                && notification == windows::Win32::UI::WindowsAndMessaging::EN_CHANGE as usize
            {
                ui.filter();
            } else if id == PLAY
                && notification == windows::Win32::UI::WindowsAndMessaging::BN_CLICKED as usize
            {
                ui.playing = !ui.playing;
                ui.refresh();
            } else if id == LIST
                && notification == windows::Win32::UI::WindowsAndMessaging::LBN_SELCHANGE as usize
            {
                let index = windows::Win32::UI::WindowsAndMessaging::SendMessageW(
                    ui.list,
                    windows::Win32::UI::WindowsAndMessaging::LB_GETCURSEL,
                    None,
                    None,
                )
                .0;
                if let Some(id) = ui.visible.get(index as usize) {
                    ui.selected = *id;
                    ui.refresh();
                }
            }
        }
        MEDIA_MESSAGE if !ptr.is_null() => {
            let ui = &mut *ptr;
            ui.playing = wparam.0 != 0;
            ui.refresh();
        }
        windows::Win32::UI::WindowsAndMessaging::WM_DESTROY => {
            windows::Win32::UI::WindowsAndMessaging::SetWindowLongPtrW(
                hwnd,
                windows::Win32::UI::WindowsAndMessaging::GWLP_USERDATA,
                0,
            );
            if !ptr.is_null() {
                let _ = windows::Win32::Graphics::Gdi::DeleteObject((*ptr).font.into());
                drop(Box::from_raw(ptr));
            }
            windows::Win32::UI::WindowsAndMessaging::PostQuitMessage(0);
        }
        _ => {
            return windows::Win32::UI::WindowsAndMessaging::DefWindowProcW(
                hwnd, message, wparam, lparam,
            );
        }
    }
    windows::Win32::Foundation::LRESULT(0)
}

fn main() -> windows::core::Result<()> {
    unsafe {
        let _ = windows::Win32::UI::HiDpi::SetProcessDpiAwarenessContext(
            windows::Win32::UI::HiDpi::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        );
        let instance = windows::Win32::System::LibraryLoader::GetModuleHandleW(None)?;
        let class = windows::Win32::UI::WindowsAndMessaging::WNDCLASSW {
            lpfnWndProc: Some(crate::window_proc),
            hInstance: instance.into(),
            lpszClassName: windows::core::w!("ToolkitProbeWin32"),
            hCursor: windows::Win32::UI::WindowsAndMessaging::LoadCursorW(
                None,
                windows::Win32::UI::WindowsAndMessaging::IDC_ARROW,
            )?,
            hbrBackground: windows::Win32::Graphics::Gdi::HBRUSH(
                (windows::Win32::Graphics::Gdi::COLOR_WINDOW.0 + 1) as *mut _,
            ),
            ..Default::default()
        };
        windows::Win32::UI::WindowsAndMessaging::RegisterClassW(&class);
        let dpi = windows::Win32::UI::HiDpi::GetDpiForSystem() as i32;
        let hwnd = windows::Win32::UI::WindowsAndMessaging::CreateWindowExW(
            windows::Win32::UI::WindowsAndMessaging::WS_EX_CONTROLPARENT,
            class.lpszClassName,
            windows::core::w!("ASO-51 — Win32"),
            windows::Win32::UI::WindowsAndMessaging::WS_OVERLAPPEDWINDOW,
            windows::Win32::UI::WindowsAndMessaging::CW_USEDEFAULT,
            windows::Win32::UI::WindowsAndMessaging::CW_USEDEFAULT,
            720 * dpi / 96,
            560 * dpi / 96,
            None,
            None,
            Some(instance.into()),
            None,
        )?;
        let _ = windows::Win32::UI::WindowsAndMessaging::ShowWindow(
            hwnd,
            windows::Win32::UI::WindowsAndMessaging::SW_SHOW,
        );
        let mut message = windows::Win32::UI::WindowsAndMessaging::MSG::default();
        loop {
            let result =
                windows::Win32::UI::WindowsAndMessaging::GetMessageW(&mut message, None, 0, 0).0;
            if result == -1 {
                return Err(windows::core::Error::from_thread());
            }
            if result == 0 {
                break;
            }
            if !windows::Win32::UI::WindowsAndMessaging::IsDialogMessageW(hwnd, &message).as_bool()
            {
                let _ = windows::Win32::UI::WindowsAndMessaging::TranslateMessage(&message);
                windows::Win32::UI::WindowsAndMessaging::DispatchMessageW(&message);
            }
        }
    }
    Ok(())
}
