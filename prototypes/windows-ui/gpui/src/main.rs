#![windows_subsystem = "windows"]

mod text_input;

gpui::actions!(
    probe,
    [
        Tab,
        TabPrev,
        Next,
        Previous,
        PageNext,
        PagePrevious,
        First,
        Last,
        Toggle
    ]
);

struct Probe {
    input: gpui::Entity<crate::text_input::TextInput>,
    root_focus: gpui::FocusHandle,
    list_focus: gpui::FocusHandle,
    button_focus: gpui::FocusHandle,
    scroll: gpui::UniformListScrollHandle,
    tracks: Vec<toolkit_probe_common::Track>,
    visible: Vec<usize>,
    selected: usize,
    query: String,
    playing: bool,
    status: String,
    media: toolkit_probe_common::MediaControls,
}

impl Probe {
    fn refresh(&mut self) {
        let track = &self.tracks[self.selected];
        self.status = format!(
            "{}: {}",
            if self.playing { "Playing" } else { "Paused" },
            track.row()
        );
        if let Err(error) = self.media.update(track, self.playing) {
            self.status = format!("SMTC update failed: {error}");
        }
    }

    fn select(&mut self, index: usize, cx: &mut gpui::Context<Self>) {
        if let Some(id) = self.visible.get(index) {
            self.selected = *id;
            self.scroll
                .scroll_to_item(index, gpui::ScrollStrategy::Nearest);
            self.refresh();
            cx.notify();
        }
    }

    fn move_by(&mut self, delta: isize, cx: &mut gpui::Context<Self>) {
        let current = self
            .visible
            .iter()
            .position(|id| *id == self.selected)
            .unwrap_or(0);
        self.select(
            current
                .saturating_add_signed(delta)
                .min(self.visible.len().saturating_sub(1)),
            cx,
        );
    }
}

impl gpui::Render for Probe {
    fn render(
        &mut self,
        _window: &mut gpui::Window,
        cx: &mut gpui::Context<Self>,
    ) -> impl gpui::IntoElement {
        use gpui::prelude::*;
        gpui::div()
            .id("root")
            .track_focus(&self.root_focus)
            .on_action(cx.listener(|_, _: &Tab, window, cx| window.focus_next(cx)))
            .on_action(cx.listener(|_, _: &TabPrev, window, cx| window.focus_prev(cx)))
            .size_full()
            .flex()
            .flex_col()
            .gap_2()
            .p_4()
            .bg(gpui::rgb(0xf5f6f8))
            .text_color(gpui::rgb(0x202126))
            .font_family("Segoe UI")
            .text_size(gpui::px(16.))
            .child(self.input.clone())
            .child(
                gpui::div()
                    .id("tracks")
                    .role(gpui::Role::ListBox)
                    .aria_label("Tracks")
                    .aria_size_of_set(self.visible.len())
                    .track_focus(&self.list_focus)
                    .key_context("Tracks")
                    .flex_1()
                    .min_h_0()
                    .border_1()
                    .border_color(gpui::rgb(0xa6a8ad))
                    .focus(|style| style.border_color(gpui::rgb(0x1253ff)))
                    .on_action(cx.listener(|this, _: &Next, _, cx| this.move_by(1, cx)))
                    .on_action(cx.listener(|this, _: &Previous, _, cx| this.move_by(-1, cx)))
                    .on_action(cx.listener(|this, _: &PageNext, _, cx| this.move_by(12, cx)))
                    .on_action(cx.listener(|this, _: &PagePrevious, _, cx| this.move_by(-12, cx)))
                    .on_action(cx.listener(|this, _: &First, _, cx| this.select(0, cx)))
                    .on_action(cx.listener(|this, _: &Last, _, cx| {
                        this.select(this.visible.len().saturating_sub(1), cx)
                    }))
                    .child(
                        gpui::uniform_list(
                            "track-rows",
                            self.visible.len(),
                            cx.processor(|this, range: std::ops::Range<usize>, _, cx| {
                                range
                                    .map(|index| {
                                        let id = this.visible[index];
                                        gpui::div()
                                            .id(("track", id))
                                            .role(gpui::Role::ListBoxOption)
                                            .aria_label(gpui::SharedString::from(
                                                this.tracks[id].row(),
                                            ))
                                            .aria_position_in_set(index)
                                            .aria_selected(id == this.selected)
                                            .when(id == this.selected, |row| {
                                                row.aria_active_descendant().bg(gpui::rgb(0xdce8ff))
                                            })
                                            .h(gpui::px(30.))
                                            .px_2()
                                            .cursor_pointer()
                                            .on_click(cx.listener(move |this, _, window, cx| {
                                                window.focus(&this.list_focus, cx);
                                                this.select(index, cx);
                                            }))
                                            .child(this.tracks[id].row())
                                    })
                                    .collect()
                            }),
                        )
                        .track_scroll(&self.scroll)
                        .h_full(),
                    ),
            )
            .child(
                gpui::div()
                    .flex()
                    .items_center()
                    .gap_4()
                    .child(
                        gpui::div()
                            .id("play")
                            .role(gpui::Role::Button)
                            .aria_label(if self.playing { "Pause" } else { "Play" })
                            .track_focus(&self.button_focus)
                            .key_context("PlayButton")
                            .border_1()
                            .border_color(gpui::rgba(0x00000000))
                            .focus(|style| style.border_color(gpui::rgb(0x202126)))
                            .px_4()
                            .py_2()
                            .bg(gpui::rgb(0x1253ff))
                            .text_color(gpui::white())
                            .cursor_pointer()
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.playing = !this.playing;
                                this.refresh();
                                cx.notify();
                            }))
                            .on_action(cx.listener(|this, _: &Toggle, _, cx| {
                                this.playing = !this.playing;
                                this.refresh();
                                cx.notify();
                            }))
                            .child(if self.playing { "Pause" } else { "Play" }),
                    )
                    .child(
                        gpui::div()
                            .id("now-playing")
                            .role(gpui::Role::Status)
                            .aria_label(self.status.clone())
                            .child(self.status.clone()),
                    ),
            )
    }
}

fn main() {
    use gpui::AppContext as _;
    use gpui::Focusable as _;
    use raw_window_handle::HasWindowHandle as _;
    gpui_platform::application().run(|cx| {
        crate::text_input::bind_keys(cx);
        cx.bind_keys([
            gpui::KeyBinding::new("tab", Tab, None),
            gpui::KeyBinding::new("shift-tab", TabPrev, None),
            gpui::KeyBinding::new("down", Next, Some("Tracks")),
            gpui::KeyBinding::new("up", Previous, Some("Tracks")),
            gpui::KeyBinding::new("pagedown", PageNext, Some("Tracks")),
            gpui::KeyBinding::new("pageup", PagePrevious, Some("Tracks")),
            gpui::KeyBinding::new("home", First, Some("Tracks")),
            gpui::KeyBinding::new("end", Last, Some("Tracks")),
            gpui::KeyBinding::new("space", Toggle, Some("PlayButton")),
            gpui::KeyBinding::new("enter", Toggle, Some("PlayButton")),
        ]);
        cx.on_window_closed(|cx, _| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        cx.open_window(
            gpui::WindowOptions {
                titlebar: Some(gpui::TitlebarOptions {
                    title: Some("ASO-51 — gpui".into()),
                    ..Default::default()
                }),
                window_bounds: Some(gpui::WindowBounds::Windowed(gpui::Bounds::centered(
                    None,
                    gpui::size(gpui::px(720.), gpui::px(560.)),
                    cx,
                ))),
                ..Default::default()
            },
            |window, cx| {
                let input = cx.new(crate::text_input::TextInput::new);
                let raw_window_handle::RawWindowHandle::Win32(handle) =
                    window.window_handle().expect("window handle").as_raw()
                else {
                    panic!("Win32 handle unavailable")
                };
                let (sender, receiver) = async_channel::unbounded();
                let media = toolkit_probe_common::MediaControls::new(
                    windows::Win32::Foundation::HWND(handle.hwnd.get() as *mut _),
                    move |playing| {
                        let _ = sender.try_send(playing);
                    },
                )
                .expect("SMTC initialization");
                let focus = input.focus_handle(cx);
                let view = cx.new(|cx: &mut gpui::Context<Probe>| {
                    let mut probe = Probe {
                        input: input.clone(),
                        root_focus: cx.focus_handle(),
                        list_focus: cx.focus_handle().tab_stop(true),
                        button_focus: cx.focus_handle().tab_stop(true),
                        scroll: gpui::UniformListScrollHandle::new(),
                        tracks: toolkit_probe_common::tracks(),
                        visible: (0..5000).collect(),
                        selected: 0,
                        query: String::new(),
                        playing: false,
                        status: String::new(),
                        media,
                    };
                    cx.observe(&input, |this, input, cx| {
                        let query = input.read(cx).content.to_string();
                        if query != this.query {
                            this.query = query;
                            this.visible =
                                toolkit_probe_common::matching(&this.tracks, &this.query);
                            let index = this
                                .visible
                                .iter()
                                .position(|id| *id == this.selected)
                                .unwrap_or(0);
                            this.select(index, cx);
                            cx.notify();
                        }
                    })
                    .detach();
                    cx.spawn_in(window, async move |this, cx| {
                        while let Ok(playing) = receiver.recv().await {
                            if this
                                .update(cx, |this, cx| {
                                    this.playing = playing;
                                    this.refresh();
                                    cx.notify();
                                })
                                .is_err()
                            {
                                break;
                            }
                        }
                    })
                    .detach();
                    probe.refresh();
                    probe
                });
                window.focus(&focus, cx);
                cx.activate(true);
                view
            },
        )
        .expect("open probe window");
    });
}
