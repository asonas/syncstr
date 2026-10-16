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
const ID_LIBRARY: i32 = 110;
const ID_HIDDEN: i32 = 111;
const ID_VISIBILITY: i32 = 112;

#[derive(Default)]
struct Ui {
    invite: HWND,
    hosts: HWND,
    tracks: HWND,
    status: HWND,
    action_buttons: Vec<HWND>,
    discovered: Vec<iroh::EndpointAddr>,
    entries: Vec<syncstr_headless::model::Entry>,
    all_entries: Vec<syncstr_headless::model::Entry>,
    organization: syncstr_headless::organization::Organization,
    hidden: bool,
    conflicts: usize,
    paused: bool,
    busy: bool,
    worker: Option<OperationWorker>,
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

fn client() -> anyhow::Result<syncstr_headless::cluster_client::PlaybackClient> {
    let root = data_root()?;
    let secret = device_secret(&root)?;
    syncstr_headless::cluster_client::PlaybackClient::open(&root, secret)
}

unsafe fn show_library(library: syncstr_headless::cluster_client::Library) {
    let mut ui = UI.get().unwrap().lock().unwrap();
    ui.conflicts = library.conflicts.len();
    ui.all_entries = library.catalog.entries;
    ui.organization = library.catalog.organization;
    render_entries(&mut ui);
}

fn entry_album(organization: &syncstr_headless::organization::Organization, entry: &syncstr_headless::model::Entry) -> Option<String> {
    organization.tracks.iter().find(|track| track.sha256 == entry.sha256)
        .and_then(|track| organization.album_id_for_track(&track.id).ok().flatten())
}

unsafe fn render_entries(ui: &mut Ui) {
    list_clear(ui.tracks);
    let mut albums = std::collections::BTreeSet::new();
    ui.entries = ui.all_entries.iter().filter(|entry| {
        let album = entry_album(&ui.organization, entry);
        album.as_deref().is_some_and(|id| ui.organization.is_hidden(id)) == ui.hidden
            && (!ui.hidden || albums.insert(album))
    }).cloned().collect();
    for entry in &ui.entries {
        list_add(
            ui.tracks,
            &format!(
                "{} — {}",
                if ui.hidden { entry.track.album.as_deref().unwrap_or("Unknown Album") } else { &entry.track.title },
                entry.track.artist.as_deref().unwrap_or("Unknown Artist")
            ),
        );
    }
    set_text(
        ui.status,
        &format!(
            "{} {} available. {} unresolved conflicts.",
            ui.entries.len(),
            if ui.hidden { "hidden albums" } else { "tracks" },
            ui.conflicts
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

const WM_WORK_COMPLETE: u32 = WM_APP + 1;

enum Work {
    Restore,
    Discover,
    Register {
        invitation: String,
        socket: std::net::SocketAddr,
    },
    Refresh(Vec<iroh::EndpointAddr>),
    Save {
        object: String,
        sources: Vec<iroh::EndpointAddr>,
    },
    Play(String),
    Visibility { album: String, hidden: bool },
}

enum Completed {
    Library(Box<syncstr_headless::cluster_client::Library>),
    Discovered(Vec<iroh::EndpointAddr>),
    Message(String),
    Play(std::path::PathBuf),
    Visibility(Box<syncstr_headless::cluster_client::Library>),
}

#[derive(Default)]
struct Delivery {
    closed: bool,
    results: Vec<std::result::Result<Completed, String>>,
    abort: Option<tokio::task::AbortHandle>,
}

struct OperationWorker {
    requests: std::sync::mpsc::Sender<Work>,
    delivery: std::sync::Arc<std::sync::Mutex<Delivery>>,
}

impl OperationWorker {
    fn start(window: HWND) -> Self {
        let (requests, receiver) = std::sync::mpsc::channel();
        let delivery = std::sync::Arc::new(std::sync::Mutex::new(Delivery::default()));
        let shared = delivery.clone();
        let window = window.0 as usize;
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Runtime::new();
            while let Ok(work) = receiver.recv() {
                if shared.lock().unwrap().closed {
                    break;
                }
                let result = match &runtime {
                    Ok(runtime) => {
                        let task = runtime.spawn(execute(work));
                        {
                            let mut delivery = shared.lock().unwrap();
                            if delivery.closed {
                                task.abort();
                            }
                            delivery.abort = Some(task.abort_handle());
                        }
                        runtime
                            .block_on(task)
                            .map_err(|error| error.to_string())
                            .and_then(|result| result.map_err(|error| error.to_string()))
                    }
                    Err(error) => Err(error.to_string()),
                };
                let mut delivery = shared.lock().unwrap();
                delivery.abort = None;
                if delivery.closed {
                    break;
                }
                delivery.results.push(result);
                // Closing takes this same lock before destroying the notification target.
                if unsafe {
                    PostMessageW(
                        Some(HWND(window as *mut _)),
                        WM_WORK_COMPLETE,
                        WPARAM(0),
                        LPARAM(0),
                    )
                }
                .is_err()
                {
                    delivery.closed = true;
                    delivery.results.clear();
                    break;
                }
            }
        });
        Self { requests, delivery }
    }

    fn stop(&self) {
        let mut delivery = self.delivery.lock().unwrap();
        delivery.closed = true;
        delivery.results.clear();
        if let Some(task) = &delivery.abort {
            task.abort();
        }
    }
}

async fn execute(work: Work) -> anyhow::Result<Completed> {
    if matches!(work, Work::Discover) {
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
        return Ok(Completed::Discovered(found.into_values().collect()));
    }
    let client = client()?;
    match work {
        Work::Restore => Ok(Completed::Library(Box::new(client.catalog().await?))),
        Work::Register { invitation, socket } => {
            client.enroll(&invitation, socket).await?;
            Ok(Completed::Message(
                "Connection registered. Refresh the library to browse music.".into(),
            ))
        }
        Work::Refresh(addresses) => {
            let trusted = client.hosts().await?;
            let address = addresses
                .into_iter()
                .find(|address| trusted.contains(&address.id.to_string()))
                .ok_or_else(|| anyhow::anyhow!("No trusted library host is currently available"))?;
            Ok(Completed::Library(Box::new(client.refresh(address).await?)))
        }
        Work::Save { object, sources } => {
            let trusted = client.hosts().await?;
            let sources = sources
                .into_iter()
                .filter(|address| trusted.contains(&address.id.to_string()))
                .collect();
            client.download_from(sources, &object).await?;
            Ok(Completed::Message(
                "Saved and verified. This track is available offline.".into(),
            ))
        }
        Work::Play(object) => Ok(Completed::Play(
            client.local_file(&object).await?.ok_or_else(|| {
                anyhow::anyhow!("This track is not saved. Save it before playing.")
            })?,
        )),
        Work::Visibility { album, hidden } => Ok(Completed::Visibility(Box::new(client.set_album_hidden(&album, hidden).await?))),
        Work::Discover => unreachable!(),
    }
}

unsafe fn capture_work(id: i32) -> anyhow::Result<Work> {
    let ui = UI.get().unwrap().lock().unwrap();
    match id {
        ID_DISCOVER => Ok(Work::Discover),
        ID_REGISTER => {
            let invitation = get_text(ui.invite);
            let expected = invitation_host(&invitation)?;
            let index = selected(ui.hosts)
                .ok_or_else(|| anyhow::anyhow!("Select the expected discovered host"))?;
            let address = ui
                .discovered
                .get(index)
                .ok_or_else(|| anyhow::anyhow!("Discovered host is no longer available"))?;
            anyhow::ensure!(
                address.id.to_string() == expected,
                "The selected host does not match the invitation"
            );
            let socket = *address
                .ip_addrs()
                .next()
                .ok_or_else(|| anyhow::anyhow!("The selected host has no LAN address"))?;
            Ok(Work::Register { invitation, socket })
        }
        ID_REFRESH => {
            anyhow::ensure!(!ui.discovered.is_empty(), "Discover a library host first");
            Ok(Work::Refresh(ui.discovered.clone()))
        }
        ID_VISIBILITY => {
            let index = selected(ui.tracks).ok_or_else(|| anyhow::anyhow!("Select an album or track"))?;
            let album = ui.entries.get(index).and_then(|entry| entry_album(&ui.organization, entry)).ok_or_else(|| anyhow::anyhow!("Album is unavailable"))?;
            Ok(Work::Visibility { album, hidden: !ui.hidden })
        }
        ID_SAVE | ID_PLAY => {
            let index = selected(ui.tracks).ok_or_else(|| anyhow::anyhow!("Select a track"))?;
            let object = ui
                .entries
                .get(index)
                .ok_or_else(|| anyhow::anyhow!("Track selection is stale"))?
                .sha256
                .clone();
            Ok(if id == ID_PLAY {
                Work::Play(object)
            } else {
                Work::Save {
                    object,
                    sources: ui.discovered.clone(),
                }
            })
        }
        _ => anyhow::bail!("Unsupported action"),
    }
}

unsafe fn dispatch(work: Work) -> anyhow::Result<()> {
    if !set_busy(true) {
        return Ok(());
    }
    status(match &work {
        Work::Restore => "Restoring saved library…",
        Work::Discover => "Discovering library hosts on the LAN…",
        Work::Register { .. } => "Registering this Windows device…",
        Work::Refresh(_) => "Refreshing the library without downloading originals…",
        Work::Save { .. } => "Saving and verifying the selected original…",
        Work::Play(_) => "Checking saved audio…",
        Work::Visibility { .. } => "Saving album visibility. Refresh the library to sync this change…",
    });
    let ui = UI.get().unwrap().lock().unwrap();
    ui.worker
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("Operation worker is unavailable"))?
        .requests
        .send(work)
        .map_err(|_| anyhow::anyhow!("Operation worker stopped"))
}

unsafe fn apply_completed(completed: Completed) -> anyhow::Result<()> {
    match completed {
        Completed::Library(library) => show_library(*library),
        Completed::Visibility(library) => {
            show_library(*library);
            status("Saved on this device. Refresh the library when connected to sync this change.");
        },
        Completed::Discovered(hosts) => {
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
        Completed::Message(message) => status(&message),
        Completed::Play(path) => {
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
    }
    Ok(())
}

unsafe fn pause_playback() -> anyhow::Result<()> {
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
            let library_button = create(w!("BUTTON"), "Library", WINDOW_STYLE(BS_PUSHBUTTON as u32), 20, 342, 130, 32, ID_LIBRARY);
            let hidden_button = create(w!("BUTTON"), "Hidden albums", WINDOW_STYLE(BS_PUSHBUTTON as u32), 20, 382, 130, 32, ID_HIDDEN);
            let tracks = create(
                w!("LISTBOX"),
                "",
                WS_BORDER | WS_VSCROLL | WINDOW_STYLE(LBS_NOTIFY as u32),
                165,
                342,
                480,
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
            let _pause_button = create(
                w!("BUTTON"),
                "Pause / Resume",
                WINDOW_STYLE(BS_PUSHBUTTON as u32),
                240,
                548,
                130,
                32,
                ID_PAUSE,
            );
            let visibility_button = create(w!("BUTTON"), "Hide / Unhide album", WINDOW_STYLE(BS_PUSHBUTTON as u32), 385, 548, 200, 32, ID_VISIBILITY);
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
                worker: Some(OperationWorker::start(hwnd)),
                action_buttons: vec![
                    discover_button,
                    register_button,
                    refresh_button,
                    save_button,
                    play_button,
                    library_button,
                    hidden_button,
                    visibility_button,
                ],
                ..Default::default()
            }));
            if let Err(error) = dispatch(Work::Restore) {
                set_busy(false);
                status(&format!("Saved library could not be restored: {error}"));
            }
            LRESULT(0)
        }
        WM_COMMAND => {
            let id = (wparam.0 & 0xffff) as i32;
            let result = if (id == ID_LIBRARY || id == ID_HIDDEN) && !UI.get().unwrap().lock().unwrap().busy {
                let mut ui = UI.get().unwrap().lock().unwrap();
                ui.hidden = id == ID_HIDDEN;
                render_entries(&mut ui);
                Ok(())
            } else if id == ID_PAUSE {
                pause_playback()
            } else if matches!(
                id,
                ID_DISCOVER | ID_REGISTER | ID_REFRESH | ID_SAVE | ID_PLAY | ID_VISIBILITY
            ) && !UI.get().unwrap().lock().unwrap().busy
            {
                capture_work(id).and_then(|work| dispatch(work))
            } else {
                Ok(())
            };
            if let Err(error) = result {
                if id != ID_PAUSE {
                    set_busy(false);
                }
                status(&format!(
                    "Action failed: {error}. You can retry this action."
                ));
            }
            LRESULT(0)
        }
        WM_WORK_COMPLETE => {
            let results = {
                let ui = UI.get().unwrap().lock().unwrap();
                let worker = ui.worker.as_ref().unwrap();
                std::mem::take(&mut worker.delivery.lock().unwrap().results)
            };
            for result in results {
                set_busy(false);
                if let Err(error) = result
                    .map_err(anyhow::Error::msg)
                    .and_then(|completed| apply_completed(completed))
                {
                    status(&format!(
                        "Action failed: {error}. You can retry this action."
                    ));
                }
            }
            LRESULT(0)
        }
        WM_CLOSE => {
            let ui = UI.get().unwrap().lock().unwrap();
            if let Some(worker) = &ui.worker {
                worker.stop();
            }
            drop(ui);
            let _ = DestroyWindow(hwnd);
            LRESULT(0)
        }
        WM_DESTROY => {
            if let Some(worker) = &mut UI.get().unwrap().lock().unwrap().worker.take() {
                worker.stop();
            }
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
