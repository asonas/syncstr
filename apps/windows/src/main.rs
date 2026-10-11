#![windows_subsystem = "windows"]
#![allow(unsafe_op_in_unsafe_fn)]

use std::sync::{Mutex, OnceLock};
use windows::{
    Win32::{
        Foundation::*, Graphics::Gdi::*, Media::Multimedia::*, Security::Cryptography::*,
        System::LibraryLoader::*, UI::Input::KeyboardAndMouse::EnableWindow,
        UI::WindowsAndMessaging::*,
    },
    core::*,
};

const ID_INVITE: i32 = 101;
const ID_DISCOVER: i32 = 102;
const ID_REGISTER: i32 = 103;
const ID_REFRESH: i32 = 104;
const ID_SAVE: i32 = 105;
const ID_PLAY: i32 = 106;
const ID_PAUSE: i32 = 107;
const ID_HOSTS: i32 = 108;
const ID_TRACKS: i32 = 109;

#[derive(Default)]
struct Ui {
    invite: HWND,
    hosts: HWND,
    tracks: HWND,
    status: HWND,
    action_buttons: Vec<HWND>,
    discovered: Vec<iroh::EndpointAddr>,
    entries: Vec<syncstr_headless::model::Entry>,
    paused: bool,
    busy: bool,
}

// HWND values are only read and used by the creating UI thread. The mutex is
// required solely to make the callback-owned state available to that thread.
unsafe impl Send for Ui {}

static UI: OnceLock<Mutex<Ui>> = OnceLock::new();

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain([0]).collect()
}

fn data_root() -> anyhow::Result<std::path::PathBuf> {
    let base = std::env::var_os("LOCALAPPDATA")
        .ok_or_else(|| anyhow::anyhow!("LOCALAPPDATA is unavailable"))?;
    Ok(std::path::PathBuf::from(base).join("Syncstr"))
}

fn device_secret(root: &std::path::Path) -> anyhow::Result<[u8; 32]> {
    std::fs::create_dir_all(root)?;
    let path = root.join("device-key.dpapi");
    if path.exists() {
        let encrypted = std::fs::read(&path)?;
        anyhow::ensure!(
            !encrypted.is_empty(),
            "The protected device identity is unreadable. Restore it before opening this library."
        );
        let input = CRYPT_INTEGER_BLOB {
            cbData: encrypted.len().try_into()?,
            pbData: encrypted.as_ptr() as *mut u8,
        };
        let mut output = CRYPT_INTEGER_BLOB::default();
        unsafe { CryptUnprotectData(&input, None, None, None, None, 0, &mut output)? };
        let bytes =
            unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
        unsafe {
            let _ = LocalFree(Some(HLOCAL(output.pbData.cast())));
        }
        return bytes
            .try_into()
            .map_err(|_| anyhow::anyhow!("The protected device identity has an invalid length"));
    }
    anyhow::ensure!(
        !root.join("node.sqlite").exists(),
        "The device identity is missing for an existing library. Restore it instead of creating a replacement."
    );
    let secret: [u8; 32] = rand::random();
    let input = CRYPT_INTEGER_BLOB {
        cbData: 32,
        pbData: secret.as_ptr() as *mut u8,
    };
    let mut output = CRYPT_INTEGER_BLOB::default();
    unsafe {
        CryptProtectData(
            &input,
            w!("Syncstr device identity"),
            None,
            None,
            None,
            0,
            &mut output,
        )?
    };
    let protected =
        unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
    unsafe {
        let _ = LocalFree(Some(HLOCAL(output.pbData.cast())));
    }
    use std::io::Write as _;
    let mut file = tempfile::Builder::new()
        .prefix("device-key-")
        .tempfile_in(root)?;
    file.write_all(&protected)?;
    file.as_file().sync_all()?;
    file.into_temp_path().persist_noclobber(path)?;
    Ok(secret)
}

fn invitation_host(invitation: &str) -> anyhow::Result<String> {
    serde_json::from_str::<serde_json::Value>(invitation)?["host"]
        .as_str()
        .filter(|host| host.len() == 64 && host.bytes().all(|b| b.is_ascii_hexdigit()))
        .map(str::to_owned)
        .ok_or_else(|| anyhow::anyhow!("Invitation does not identify a valid host"))
}

fn runtime() -> anyhow::Result<tokio::runtime::Runtime> {
    Ok(tokio::runtime::Runtime::new()?)
}

fn client() -> anyhow::Result<syncstr_headless::cluster_client::PlaybackClient> {
    let root = data_root()?;
    let secret = device_secret(&root)?;
    syncstr_headless::cluster_client::PlaybackClient::open(&root, secret)
}

unsafe fn show_library(library: syncstr_headless::cluster_client::Library) {
    let mut ui = UI.get().unwrap().lock().unwrap();
    list_clear(ui.tracks);
    for entry in &library.catalog.entries {
        list_add(
            ui.tracks,
            &format!(
                "{} — {}",
                entry.track.title,
                entry.track.artist.as_deref().unwrap_or("Unknown Artist")
            ),
        );
    }
    ui.entries = library.catalog.entries;
    set_text(
        ui.status,
        &format!(
            "{} tracks available. {} unresolved conflicts.",
            ui.entries.len(),
            library.conflicts.len()
        ),
    );
}

unsafe fn set_text(hwnd: HWND, value: &str) {
    let value = wide(value);
    let _ = SetWindowTextW(hwnd, PCWSTR(value.as_ptr()));
}

unsafe fn get_text(hwnd: HWND) -> String {
    let len = GetWindowTextLengthW(hwnd);
    let mut buffer = vec![0u16; len as usize + 1];
    GetWindowTextW(hwnd, &mut buffer);
    String::from_utf16_lossy(&buffer[..len as usize])
}

unsafe fn list_clear(hwnd: HWND) {
    SendMessageW(hwnd, LB_RESETCONTENT, None, None);
}
unsafe fn list_add(hwnd: HWND, value: &str) {
    let text = wide(value);
    SendMessageW(
        hwnd,
        LB_ADDSTRING,
        None,
        Some(LPARAM(text.as_ptr() as isize)),
    );
}
unsafe fn selected(hwnd: HWND) -> Option<usize> {
    let index = SendMessageW(hwnd, LB_GETCURSEL, None, None).0;
    (index != LB_ERR as isize).then_some(index as usize)
}

unsafe fn status(text: &str) {
    if let Some(ui) = UI.get() {
        let status = ui.lock().unwrap().status;
        set_text(status, text);
        let _ = UpdateWindow(status);
    }
}

unsafe fn set_busy(value: bool) -> bool {
    let Some(ui) = UI.get() else { return false };
    let mut ui = ui.lock().unwrap();
    if value && ui.busy {
        return false;
    }
    ui.busy = value;
    for button in &ui.action_buttons {
        let _ = EnableWindow(*button, !value);
    }
    true
}

fn discover() -> anyhow::Result<Vec<iroh::EndpointAddr>> {
    runtime()?.block_on(async {
        let discovery = syncstr_headless::cluster_discovery::Discovery::browse()?;
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(3);
        let mut found = std::collections::BTreeMap::new();
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            match tokio::time::timeout(remaining, discovery.next()).await {
                Ok(Ok(address)) => {
                    found.insert(address.id.to_string(), address);
                }
                Ok(Err(error)) => return Err(error),
                Err(_) => break,
            }
        }
        Ok(found.into_values().collect())
    })
}

unsafe fn perform(id: i32) -> anyhow::Result<()> {
    match id {
        ID_DISCOVER => {
            status("Discovering library hosts on the LAN…");
            let hosts = discover()?;
            let mut ui = UI.get().unwrap().lock().unwrap();
            list_clear(ui.hosts);
            for host in &hosts {
                list_add(ui.hosts, &host.id.to_string());
            }
            ui.discovered = hosts;
            set_text(
                ui.status,
                if ui.discovered.is_empty() {
                    "No Syncstr library hosts were found."
                } else {
                    "Select the expected host, then register or refresh."
                },
            );
        }
        ID_REGISTER => {
            let (invite, address) = {
                let ui = UI.get().unwrap().lock().unwrap();
                let invite = get_text(ui.invite);
                let expected = invitation_host(&invite)?;
                let selected = selected(ui.hosts)
                    .ok_or_else(|| anyhow::anyhow!("Select the expected discovered host"))?;
                let address = ui
                    .discovered
                    .get(selected)
                    .cloned()
                    .ok_or_else(|| anyhow::anyhow!("Discovered host is no longer available"))?;
                anyhow::ensure!(
                    address.id.to_string() == expected,
                    "The selected host does not match the invitation"
                );
                let socket = *address
                    .ip_addrs()
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("The selected host has no LAN address"))?;
                (invite, socket)
            };
            status("Registering this Windows device…");
            runtime()?.block_on(client()?.enroll(&invite, address))?;
            status("Connection registered. Refresh the library to browse music.");
        }
        ID_REFRESH => {
            let addresses = { UI.get().unwrap().lock().unwrap().discovered.clone() };
            anyhow::ensure!(!addresses.is_empty(), "Discover a library host first");
            status("Refreshing the library without downloading originals…");
            let client = client()?;
            let trusted = runtime()?.block_on(client.hosts())?;
            let address = addresses
                .into_iter()
                .find(|a| trusted.contains(&a.id.to_string()))
                .ok_or_else(|| anyhow::anyhow!("No trusted library host is currently available"))?;
            let library = runtime()?.block_on(client.refresh(address))?;
            show_library(library);
        }
        ID_SAVE => {
            let (object, sources) = {
                let ui = UI.get().unwrap().lock().unwrap();
                let index =
                    selected(ui.tracks).ok_or_else(|| anyhow::anyhow!("Select a track to save"))?;
                (
                    ui.entries
                        .get(index)
                        .ok_or_else(|| anyhow::anyhow!("Track selection is stale"))?
                        .sha256
                        .clone(),
                    ui.discovered.clone(),
                )
            };
            let client = client()?;
            let trusted = runtime()?.block_on(client.hosts())?;
            let sources = sources
                .into_iter()
                .filter(|a| trusted.contains(&a.id.to_string()))
                .collect();
            status("Saving and verifying the selected original…");
            runtime()?.block_on(client.download_from(sources, &object))?;
            status("Saved and verified. This track is available offline.");
        }
        ID_PLAY => {
            let object = {
                let ui = UI.get().unwrap().lock().unwrap();
                let index = selected(ui.tracks)
                    .ok_or_else(|| anyhow::anyhow!("Select a saved track to play"))?;
                ui.entries
                    .get(index)
                    .ok_or_else(|| anyhow::anyhow!("Track selection is stale"))?
                    .sha256
                    .clone()
            };
            let path = runtime()?
                .block_on(client()?.local_file(&object))?
                .ok_or_else(|| {
                    anyhow::anyhow!("This track is not saved. Save it before playing.")
                })?;
            let _ = mciSendStringW(w!("close syncstr_audio"), None, None);
            let command = wide(&format!("open \"{}\" alias syncstr_audio", path.display()));
            anyhow::ensure!(
                mciSendStringW(PCWSTR(command.as_ptr()), None, None) == 0,
                "Windows could not open this audio format"
            );
            anyhow::ensure!(
                mciSendStringW(w!("play syncstr_audio"), None, None) == 0,
                "Windows could not start playback"
            );
            UI.get().unwrap().lock().unwrap().paused = false;
            status("Playing saved audio locally.");
        }
        ID_PAUSE => {
            let mut ui = UI.get().unwrap().lock().unwrap();
            let command = if ui.paused {
                w!("resume syncstr_audio")
            } else {
                w!("pause syncstr_audio")
            };
            anyhow::ensure!(
                mciSendStringW(command, None, None) == 0,
                "No active playback session"
            );
            ui.paused = !ui.paused;
            set_text(
                ui.status,
                if ui.paused {
                    "Playback paused."
                } else {
                    "Playback resumed."
                },
            );
        }
        _ => {}
    }
    Ok(())
}

unsafe extern "system" fn wndproc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_CREATE => {
            let hinstance = GetModuleHandleW(None).unwrap();
            let font = GetStockObject(DEFAULT_GUI_FONT);
            let create = |class: PCWSTR, text: &str, style: WINDOW_STYLE, x, y, w, h, id| {
                let text = wide(text);
                let control = CreateWindowExW(
                    WINDOW_EX_STYLE(0),
                    class,
                    PCWSTR(text.as_ptr()),
                    style | WS_CHILD | WS_VISIBLE,
                    x,
                    y,
                    w,
                    h,
                    Some(hwnd),
                    Some(HMENU(id as usize as *mut _)),
                    Some(hinstance.into()),
                    None,
                )
                .unwrap();
                SendMessageW(
                    control,
                    WM_SETFONT,
                    Some(WPARAM(font.0 as usize)),
                    Some(LPARAM(1)),
                );
                control
            };
            create(
                w!("STATIC"),
                "Connection invitation",
                WS_GROUP,
                20,
                18,
                300,
                22,
                0,
            );
            let invite = create(
                w!("EDIT"),
                "",
                WS_BORDER | WINDOW_STYLE((ES_MULTILINE | ES_AUTOVSCROLL) as u32) | WS_VSCROLL,
                20,
                42,
                500,
                86,
                ID_INVITE,
            );
            let discover_button = create(
                w!("BUTTON"),
                "Discover",
                WINDOW_STYLE(BS_PUSHBUTTON as u32),
                535,
                42,
                110,
                30,
                ID_DISCOVER,
            );
            let register_button = create(
                w!("BUTTON"),
                "Register",
                WINDOW_STYLE(BS_PUSHBUTTON as u32),
                535,
                82,
                110,
                30,
                ID_REGISTER,
            );
            create(
                w!("STATIC"),
                "Discovered hosts",
                WS_GROUP,
                20,
                142,
                300,
                22,
                0,
            );
            let hosts = create(
                w!("LISTBOX"),
                "",
                WS_BORDER | WS_VSCROLL | WINDOW_STYLE(LBS_NOTIFY as u32),
                20,
                166,
                625,
                88,
                ID_HOSTS,
            );
            let refresh_button = create(
                w!("BUTTON"),
                "Refresh library",
                WINDOW_STYLE(BS_PUSHBUTTON as u32),
                20,
                270,
                135,
                32,
                ID_REFRESH,
            );
            create(w!("STATIC"), "Library", WS_GROUP, 20, 318, 300, 22, 0);
            let tracks = create(
                w!("LISTBOX"),
                "",
                WS_BORDER | WS_VSCROLL | WINDOW_STYLE(LBS_NOTIFY as u32),
                20,
                342,
                625,
                190,
                ID_TRACKS,
            );
            let save_button = create(
                w!("BUTTON"),
                "Save",
                WINDOW_STYLE(BS_PUSHBUTTON as u32),
                20,
                548,
                100,
                32,
                ID_SAVE,
            );
            let play_button = create(
                w!("BUTTON"),
                "Play",
                WINDOW_STYLE(BS_PUSHBUTTON as u32),
                130,
                548,
                100,
                32,
                ID_PLAY,
            );
            let pause_button = create(
                w!("BUTTON"),
                "Pause / Resume",
                WINDOW_STYLE(BS_PUSHBUTTON as u32),
                240,
                548,
                130,
                32,
                ID_PAUSE,
            );
            let status_hwnd = create(
                w!("STATIC"),
                "Ready. Discover a host or play an already saved track.",
                WS_GROUP,
                20,
                598,
                625,
                42,
                0,
            );
            let _ = UI.set(Mutex::new(Ui {
                invite,
                hosts,
                tracks,
                status: status_hwnd,
                action_buttons: vec![
                    discover_button,
                    register_button,
                    refresh_button,
                    save_button,
                    play_button,
                    pause_button,
                ],
                ..Default::default()
            }));
            if data_root().is_ok_and(|root| root.join("node.sqlite").exists()) {
                match client().and_then(|client| runtime()?.block_on(client.catalog())) {
                    Ok(library) => show_library(library),
                    Err(error) => status(&format!("Saved library could not be restored: {error}")),
                }
            }
            LRESULT(0)
        }
        WM_COMMAND => {
            let id = (wparam.0 & 0xffff) as i32;
            if matches!(
                id,
                ID_DISCOVER | ID_REGISTER | ID_REFRESH | ID_SAVE | ID_PLAY | ID_PAUSE
            ) && set_busy(true)
            {
                let result = perform(id);
                set_busy(false);
                if let Err(error) = result {
                    status(&format!(
                        "Action failed: {error}. You can retry this action."
                    ));
                }
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            let _ = mciSendStringW(w!("close syncstr_audio"), None, None);
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn run() -> Result<()> {
    unsafe {
        let hinstance = GetModuleHandleW(None)?;
        let class = w!("SyncstrWindowsApp");
        let cursor = LoadCursorW(None, IDC_ARROW)?;
        RegisterClassW(&WNDCLASSW {
            hCursor: cursor,
            hInstance: hinstance.into(),
            lpszClassName: class,
            lpfnWndProc: Some(wndproc),
            hbrBackground: HBRUSH((COLOR_WINDOW.0 + 1) as *mut _),
            ..Default::default()
        });
        CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            w!("Syncstr for Windows"),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            700,
            710,
            None,
            None,
            Some(hinstance.into()),
            None,
        )?;
        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).into() {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        let title = wide("Syncstr could not start");
        let text = wide(&error.to_string());
        unsafe {
            MessageBoxW(
                None,
                PCWSTR(text.as_ptr()),
                PCWSTR(title.as_ptr()),
                MB_OK | MB_ICONERROR,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn protected_identity_survives_reopen() {
        let directory = tempfile::tempdir().unwrap();
        let first = super::device_secret(directory.path()).unwrap();
        let second = super::device_secret(directory.path()).unwrap();
        assert_eq!(first, second);
        assert_ne!(
            std::fs::read(directory.path().join("device-key.dpapi")).unwrap(),
            first
        );
    }

    #[test]
    fn existing_store_without_identity_requires_recovery() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("node.sqlite"), []).unwrap();
        assert!(
            super::device_secret(directory.path())
                .unwrap_err()
                .to_string()
                .contains("missing")
        );
    }

    #[test]
    fn invitation_host_requires_a_full_endpoint_id() {
        let id = "a".repeat(64);
        assert_eq!(
            super::invitation_host(&format!(r#"{{"host":"{id}"}}"#)).unwrap(),
            id
        );
        assert!(super::invitation_host(r#"{"host":"short"}"#).is_err());
        assert!(
            super::invitation_host(
                r#"{"host":"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"}"#
            )
            .is_err()
        );
    }
}
