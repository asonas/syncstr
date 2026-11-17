#![windows_subsystem = "windows"]

slint::slint! {
    #[edition = "1.19"]
    import { StandardListView, LineEdit, Button, VerticalBox, HorizontalBox, AboutSlint } from "std-widgets.slint";
    export component Probe inherits Window {
        title: "ASO-51 — Slint";
        preferred-width: 720px;
        preferred-height: 560px;
        min-width: 360px;
        min-height: 300px;
        in property <[StandardListViewItem]> tracks;
        in-out property <int> selected: 0;
        in property <bool> playing: false;
        in property <string> now-playing;
        callback search(string);
        callback select(int);
        callback toggle();
        VerticalBox {
            padding: 16px;
            spacing: 8px;
            HorizontalBox {
                Text { text: "Search"; }
                search := LineEdit {
                    accessible-label: "Search";
                    placeholder-text: "Search tracks";
                    edited => { root.search(self.text); }
                }
            }
            list := StandardListView {
                vertical-stretch: 1;
                accessible-label: "Tracks";
                model: root.tracks;
                current-item <=> root.selected;
                current-item-changed(index) => { root.select(index); }
            }
            HorizontalBox {
                Button {
                    text: root.playing ? "Pause" : "Play";
                    clicked => { root.toggle(); }
                }
                Text { text: root.now-playing; wrap: word-wrap; }
            }
            HorizontalBox {
                vertical-stretch: 0;
                AboutSlint { width: 280px; height: 112px; }
                Rectangle { horizontal-stretch: 1; }
            }
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    use raw_window_handle::HasWindowHandle as _;
    use slint::ComponentHandle as _;
    let app = Probe::new()?;
    let tracks = std::rc::Rc::new(toolkit_probe_common::tracks());
    let visible = std::rc::Rc::new(std::cell::RefCell::new((0..5000).collect::<Vec<_>>()));
    let selected = std::rc::Rc::new(std::cell::Cell::new(0usize));
    app.show()?;
    app.window().set_size(slint::LogicalSize::new(720., 560.));
    let media = std::rc::Rc::new(std::cell::RefCell::new(
        None::<toolkit_probe_common::MediaControls>,
    ));
    let update: std::rc::Rc<dyn Fn()> = {
        let weak = app.as_weak();
        let tracks = tracks.clone();
        let selected = selected.clone();
        let media = media.clone();
        std::rc::Rc::new(move || {
            if let Some(app) = weak.upgrade() {
                let track = &tracks[selected.get()];
                let state = if app.get_playing() {
                    "Playing"
                } else {
                    "Paused"
                };
                app.set_now_playing(format!("{state}: {}", track.row()).into());
                if let Some(media) = media.borrow().as_ref()
                    && let Err(error) = media.update(track, app.get_playing())
                {
                    app.set_now_playing(format!("SMTC update failed: {error}").into());
                }
            }
        })
    };
    let model = slint::VecModel::from(
        tracks
            .iter()
            .map(|track| slint::StandardListViewItem::from(slint::SharedString::from(track.row())))
            .collect::<Vec<_>>(),
    );
    app.set_tracks(std::rc::Rc::new(model).into());
    app.on_toggle({
        let weak = app.as_weak();
        let update = update.clone();
        move || {
            if let Some(app) = weak.upgrade() {
                app.set_playing(!app.get_playing());
                update();
            }
        }
    });
    app.on_select({
        let visible = visible.clone();
        let selected = selected.clone();
        let update = update.clone();
        move |index| {
            if let Some(id) = visible.borrow().get(index as usize) {
                selected.set(*id);
                update();
            }
        }
    });
    app.on_search({
        let weak = app.as_weak();
        let tracks = tracks.clone();
        let visible = visible.clone();
        let selected = selected.clone();
        let update = update.clone();
        move |query| {
            if let Some(app) = weak.upgrade() {
                let ids = toolkit_probe_common::matching(&tracks, &query);
                let index = ids.iter().position(|id| *id == selected.get()).unwrap_or(0);
                if let Some(id) = ids.get(index) {
                    selected.set(*id);
                }
                let rows = ids
                    .iter()
                    .map(|id| {
                        slint::StandardListViewItem::from(slint::SharedString::from(
                            tracks[*id].row(),
                        ))
                    })
                    .collect::<Vec<_>>();
                *visible.borrow_mut() = ids;
                app.set_tracks(std::rc::Rc::new(slint::VecModel::from(rows)).into());
                app.set_selected(index as i32);
                update();
            }
        }
    });
    slint::Timer::single_shot(std::time::Duration::from_millis(50), {
        let weak = app.as_weak();
        let media = media.clone();
        let update = update.clone();
        move || {
            let Some(app) = weak.upgrade() else { return };
            let initialize =
                || -> Result<toolkit_probe_common::MediaControls, Box<dyn std::error::Error>> {
                    let handle = app.window().window_handle();
                    let raw_window_handle::RawWindowHandle::Win32(handle) =
                        handle.window_handle()?.as_raw()
                    else {
                        return Err("Win32 handle unavailable".into());
                    };
                    let weak = app.as_weak();
                    Ok(toolkit_probe_common::MediaControls::new(
                        windows::Win32::Foundation::HWND(handle.hwnd.get() as *mut _),
                        move |playing| {
                            let weak = weak.clone();
                            let _ = slint::invoke_from_event_loop(move || {
                                if let Some(app) = weak.upgrade()
                                    && app.get_playing() != playing
                                {
                                    app.invoke_toggle();
                                }
                            });
                        },
                    )?)
                };
            match initialize() {
                Ok(controls) => {
                    *media.borrow_mut() = Some(controls);
                    update();
                }
                Err(error) => {
                    app.set_now_playing(format!("SMTC initialization failed: {error}").into())
                }
            }
        }
    });
    update();
    slint::run_event_loop()?;
    Ok(())
}
