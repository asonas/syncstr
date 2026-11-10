use std::ops::Range;

use gpui::{
    App, Context, Entity, FocusHandle, KeyBinding, Role, ScrollStrategy, Subscription,
    UniformListScrollHandle, Window, actions, canvas, div, prelude::*, px, rgb, uniform_list,
};

use crate::model::{DEFAULT_TRACK_COUNT, PlaybackState, Track, filtered_indices, fixture_tracks};
use crate::text_input::SearchInput;

actions!(
    desktop,
    [Tab, PreviousTab, Up, Down, PageUp, PageDown, First, Last]
);

pub fn bind_keys(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("tab", Tab, Some("Desktop")),
        KeyBinding::new("shift-tab", PreviousTab, Some("Desktop")),
        KeyBinding::new("up", Up, Some("Tracks")),
        KeyBinding::new("down", Down, Some("Tracks")),
        KeyBinding::new("pageup", PageUp, Some("Tracks")),
        KeyBinding::new("pagedown", PageDown, Some("Tracks")),
        KeyBinding::new("home", First, Some("Tracks")),
        KeyBinding::new("end", Last, Some("Tracks")),
    ]);
}

pub struct Desktop {
    tracks: Vec<Track>,
    filtered: Vec<usize>,
    selected: Option<usize>,
    playback: PlaybackState,
    search: Entity<SearchInput>,
    query: String,
    list_focus: FocusHandle,
    button_focus: FocusHandle,
    scroll: UniformListScrollHandle,
    page_size: usize,
    _search_subscription: Subscription,
    #[cfg(windows)]
    service: Option<crate::backend::Service>,
    #[cfg(windows)]
    hosts: Vec<crate::backend::Host>,
    #[cfg(windows)]
    selected_host: Option<String>,
    #[cfg(windows)]
    library: Vec<Track>,
    #[cfg(windows)]
    playlists: Vec<(String, String, Vec<Track>)>,
    #[cfg(windows)]
    collection: Option<String>,
    message: String,
    busy: bool,
    position: String,
}

impl Desktop {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        #[cfg(windows)]
        let service = if std::env::args().any(|a| a == "--demo") {
            None
        } else {
            Some(crate::backend::Service::start(
                crate::backend::configuration::Config::arguments()
                    .expect("invalid desktop arguments"),
            ))
        };
        let tracks = fixture_tracks(DEFAULT_TRACK_COUNT);
        #[cfg(windows)]
        let tracks = if service.is_some() {
            Vec::new()
        } else {
            tracks
        };
        #[cfg(windows)]
        cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(std::time::Duration::from_millis(100))
                    .await;
                if this.update(cx, |this, cx| this.poll(cx)).is_err() {
                    break;
                }
            }
        })
        .detach();
        let search = cx.new(SearchInput::new);
        let search_focus = search.read(cx).focus.clone();
        window.focus(&search_focus, cx);
        let subscription = cx.observe(&search, |this, search, cx| {
            let query = search.read(cx).content.to_string();
            if query != this.query {
                this.query = query;
                this.filtered = filtered_indices(&this.tracks, &this.query);
                this.selected = (!this.filtered.is_empty()).then_some(0);
                this.scroll.scroll_to_item(0, ScrollStrategy::Top);
                cx.notify();
            }
        });
        Self {
            filtered: filtered_indices(&tracks, ""),
            tracks,
            selected: Some(0),
            playback: PlaybackState::default(),
            search,
            query: String::new(),
            list_focus: cx.focus_handle().tab_stop(true),
            button_focus: cx.focus_handle().tab_stop(true),
            scroll: UniformListScrollHandle::new(),
            page_size: 1,
            _search_subscription: subscription,
            #[cfg(windows)]
            service,
            #[cfg(windows)]
            hosts: Vec::new(),
            #[cfg(windows)]
            selected_host: None,
            #[cfg(windows)]
            library: Vec::new(),
            #[cfg(windows)]
            playlists: Vec::new(),
            #[cfg(windows)]
            collection: None,
            message: String::new(),
            busy: false,
            position: String::new(),
        }
    }

    fn select(&mut self, index: usize, cx: &mut Context<Self>) {
        if self.filtered.is_empty() {
            self.selected = None;
        } else {
            let index = index.min(self.filtered.len() - 1);
            self.selected = Some(index);
            self.scroll.scroll_to_item(index, ScrollStrategy::Nearest);
        }
        cx.notify();
    }

    fn step(&mut self, forward: bool, count: usize, cx: &mut Context<Self>) {
        let current = self.selected.unwrap_or(0);
        self.select(
            if forward {
                current.saturating_add(count)
            } else {
                current.saturating_sub(count)
            },
            cx,
        );
    }

    fn toggle(&mut self, cx: &mut Context<Self>) {
        let selected = self
            .selected
            .and_then(|index| self.filtered.get(index))
            .map(|&index| &self.tracks[index]);
        #[cfg(windows)]
        if let Some(service) = &self.service {
            if self.playback.is_playing && selected.is_none() {
                service.pause();
                cx.notify();
                return;
            }
            if let Some(track) = selected {
                if self.playback.current_track_id.as_ref() == Some(&track.id) {
                    if self.playback.is_playing {
                        service.pause();
                    } else {
                        service.resume();
                    }
                } else if track.available {
                    service.play(track.clone());
                } else {
                    self.message = "This entry is unavailable; its exact track and audio version are retained.".into();
                }
            }
            cx.notify();
            return;
        }
        self.playback.toggle(selected);
        cx.notify();
    }

    #[cfg(windows)]
    fn poll(&mut self, cx: &mut Context<Self>) {
        let events: Vec<_> = self
            .service
            .as_ref()
            .map(|s| s.events.try_iter().collect())
            .unwrap_or_default();
        if events.is_empty() {
            return;
        }
        for event in events {
            match event {
                crate::backend::Event::Library {
                    tracks,
                    playlists,
                    message,
                } => {
                    let selected = self
                        .selected
                        .and_then(|i| self.filtered.get(i))
                        .map(|&i| self.tracks[i].id.clone());
                    self.library = tracks;
                    self.playlists = playlists;
                    self.tracks = self
                        .collection
                        .as_ref()
                        .and_then(|id| {
                            self.playlists
                                .iter()
                                .find(|p| &p.0 == id)
                                .map(|p| p.2.clone())
                        })
                        .unwrap_or_else(|| self.library.clone());
                    self.filtered = filtered_indices(&self.tracks, &self.query);
                    self.selected = selected
                        .and_then(|key| {
                            self.filtered.iter().position(|&i| self.tracks[i].id == key)
                        })
                        .or_else(|| (!self.filtered.is_empty()).then_some(0));
                    self.message = message;
                }
                crate::backend::Event::Hosts(hosts, selected) => {
                    self.hosts = hosts;
                    self.selected_host = selected;
                }
                crate::backend::Event::Busy(busy) => self.busy = busy,
                crate::backend::Event::Message(message) => self.message = message,
                crate::backend::Event::Playback {
                    key,
                    title,
                    playing,
                    seconds,
                    duration,
                } => {
                    self.playback.current_track_id = (!key.is_empty()).then_some(key);
                    self.playback.is_playing = playing;
                    self.position = format!("{title} · {seconds:.1} / {duration:.1} s");
                }
            }
        }
        cx.notify();
    }

    #[cfg(windows)]
    fn command(&mut self, command: crate::backend::Command) {
        if !self.busy
            && let Some(service) = &self.service
        {
            service.send(command);
            self.busy = true;
        }
    }
}

impl Render for Desktop {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let button_label = if self.playback.is_playing {
            "Pause"
        } else {
            "Play"
        };
        let status = self
            .playback
            .current_track_id
            .as_ref()
            .and_then(|id| self.tracks.iter().find(|track| &track.id == id))
            .map(|track| {
                format!(
                    "{}: {} — {}",
                    if self.playback.is_playing {
                        "Now playing"
                    } else {
                        "Paused"
                    },
                    track.title,
                    track.artist
                )
            })
            .unwrap_or_else(|| "No track playing".to_owned());
        let view = cx.entity();
        div()
            .id("desktop")
            .key_context("Desktop")
            .role(Role::Application)
            .aria_label("Syncstr Desktop")
            .on_action(cx.listener(|_, _: &Tab, window, cx| window.focus_next(cx)))
            .on_action(cx.listener(|_, _: &PreviousTab, window, cx| window.focus_prev(cx)))
            .size_full()
            .flex()
            .flex_col()
            .gap_4()
            .p_4()
            .bg(rgb(0xffffff))
            .text_color(rgb(0x202126))
            .text_size(px(16.))
            .child(self.controls(cx))
            .child(self.search.clone())
            .child(
                div()
                    .id("tracks")
                    .key_context("Tracks")
                    .track_focus(&self.list_focus)
                    .tab_stop(true)
                    .role(Role::ListBox)
                    .accessibility_id("track-list")
                    .aria_label("Tracks")
                    .aria_size_of_set(self.filtered.len())
                    .border_1()
                    .border_color(rgb(0xedeff3))
                    .focus_visible(|style| style.border_color(rgb(0x2a65d1)))
                    .relative()
                    .flex_1()
                    .min_h_0()
                    .on_action(cx.listener(|this, _: &Up, _, cx| this.step(false, 1, cx)))
                    .on_action(cx.listener(|this, _: &Down, _, cx| this.step(true, 1, cx)))
                    .on_action(
                        cx.listener(|this, _: &PageUp, _, cx| this.step(false, this.page_size, cx)),
                    )
                    .on_action(
                        cx.listener(|this, _: &PageDown, _, cx| {
                            this.step(true, this.page_size, cx)
                        }),
                    )
                    .on_action(cx.listener(|this, _: &First, _, cx| this.select(0, cx)))
                    .on_action(cx.listener(|this, _: &Last, _, cx| {
                        this.select(this.filtered.len().saturating_sub(1), cx)
                    }))
                    .on_click(cx.listener(|this, _, window, cx| window.focus(&this.list_focus, cx)))
                    .child(
                        canvas(
                            move |bounds, _, cx| {
                                view.update(cx, |this, _| {
                                    this.page_size =
                                        (bounds.size.height.to_f64() / 36.).floor().max(1.) as usize
                                });
                            },
                            |_, _, _, _| {},
                        )
                        .absolute()
                        .size_full(),
                    )
                    .when(self.filtered.is_empty(), |list| {
                        list.child(div().p_4().child("No matching tracks"))
                    })
                    .when(!self.filtered.is_empty(), |list| {
                        list.child(
                            uniform_list(
                                "track-rows",
                                self.filtered.len(),
                                cx.processor(|this, range: Range<usize>, _, cx| {
                                    range
                                        .map(|index| {
                                            let track = &this.tracks[this.filtered[index]];
                                            let selected = this.selected == Some(index);
                                            div()
                                                .id(gpui::SharedString::from(format!(
                                                    "track-{}",
                                                    track.id
                                                )))
                                                .role(Role::ListBoxOption)
                                                .accessibility_id(format!("track-{}", track.id))
                                                .aria_label(format!(
                                                    "{} — {} · {}{}{}",
                                                    track.title,
                                                    track.artist,
                                                    track.album,
                                                    if track.saved { " · Saved" } else { "" },
                                                    if track.available {
                                                        ""
                                                    } else {
                                                        " · Unavailable"
                                                    }
                                                ))
                                                .aria_position_in_set(index)
                                                .aria_selected(selected)
                                                .when(selected, |row| row.aria_active_descendant())
                                                .h(px(36.))
                                                .w_full()
                                                .px_2()
                                                .flex()
                                                .items_center()
                                                .overflow_hidden()
                                                .when(selected, |row| {
                                                    row.bg(rgb(0x1253ff)).text_color(rgb(0xffffff))
                                                })
                                                .when(!selected, |row| {
                                                    row.hover(|style| style.bg(rgb(0xf5f6f8)))
                                                })
                                                .on_click(cx.listener(
                                                    move |this, _, window, cx| {
                                                        window.focus(&this.list_focus, cx);
                                                        this.select(index, cx);
                                                    },
                                                ))
                                                .child(format!(
                                                    "{} · {} — {} · {}{}{}",
                                                    index + 1,
                                                    track.title,
                                                    track.artist,
                                                    track.album,
                                                    if track.saved { " · Saved" } else { "" },
                                                    if track.available {
                                                        ""
                                                    } else {
                                                        " · Unavailable"
                                                    }
                                                ))
                                        })
                                        .collect()
                                }),
                            )
                            .track_scroll(&self.scroll)
                            .h_full(),
                        )
                    }),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .id("play-pause")
                            .track_focus(&self.button_focus)
                            .tab_stop(true)
                            .role(Role::Button)
                            .accessibility_id("play-pause")
                            .aria_label(button_label)
                            .aria_keyshortcuts("Space Enter")
                            .border_2()
                            .border_color(rgb(0x1253ff))
                            .focus_visible(|style| style.border_color(rgb(0x202126)))
                            .bg(rgb(0x1253ff))
                            .text_color(rgb(0xffffff))
                            .rounded_md()
                            .px_4()
                            .py_2()
                            .cursor_pointer()
                            // GPUI's on_click also handles unmodified Space/Enter on key-up.
                            .on_click(cx.listener(|this, _, window, cx| {
                                window.focus(&this.button_focus, cx);
                                this.toggle(cx);
                            }))
                            .child(button_label),
                    )
                    .child(
                        div()
                            .id("playback-status")
                            .role(Role::Label)
                            .aria_label(status.clone())
                            .child(status),
                    ),
            )
            .child(div().text_sm().child(self.position.clone()))
            .child(div().text_sm().child(self.message.clone()))
    }
}

impl Desktop {
    fn controls(&self, cx: &mut Context<Self>) -> gpui::AnyElement {
        #[cfg(windows)]
        if self.service.is_some() {
            let mut controls = div().flex().flex_col().gap_2();
            let mut actions = div().flex().flex_wrap().gap_2();
            for (id, label) in [
                ("discover", "Discover"),
                ("enroll", "Enroll from clipboard"),
                ("refresh", "Refresh / retry saves"),
                ("save", "Save"),
                ("remove", "Remove save"),
                ("cancel", "Cancel"),
            ] {
                actions = actions.child(
                    div()
                        .id(id)
                        .role(Role::Button)
                        .aria_label(label)
                        .accessibility_id(id)
                        .tab_stop(true)
                        .tab_index(0)
                        .focus_visible(|style| style.border_color(rgb(0x1253ff)))
                        .border_1()
                        .px_2()
                        .py_1()
                        .cursor_pointer()
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if id == "cancel" {
                                if let Some(service) = &this.service {
                                    service.cancel();
                                }
                            } else {
                                let command = match id {
                                    "discover" => Some(crate::backend::Command::Discover),
                                    "refresh" => Some(crate::backend::Command::Refresh),
                                    "enroll" => cx
                                        .read_from_clipboard()
                                        .and_then(|item| item.text())
                                        .map(crate::backend::Command::Enroll),
                                    "save" | "remove" => this
                                        .selected
                                        .and_then(|i| this.filtered.get(i))
                                        .map(|&i| this.tracks[i].clone())
                                        .map(|track| {
                                            if id == "save" {
                                                crate::backend::Command::Save(track)
                                            } else {
                                                crate::backend::Command::Remove(track)
                                            }
                                        }),
                                    _ => None,
                                };
                                if let Some(command) = command {
                                    this.command(command);
                                }
                            }
                            cx.notify();
                        }))
                        .child(label),
                );
            }
            controls = controls.child(actions).child(div().text_sm().child(if self.busy { "Working… Cancel interrupts acquisition; playback controls remain available." } else { "Library editing is unavailable until shared member-write contracts are implemented." }));
            for host in &self.hosts {
                let member = host.member.clone();
                let label = format!(
                    "{} {}",
                    if self.selected_host.as_ref() == Some(&member) {
                        "Selected host:"
                    } else {
                        "Host:"
                    },
                    member
                );
                controls = controls.child(
                    div()
                        .id(gpui::SharedString::from(format!("host-{member}")))
                        .role(Role::Button)
                        .aria_label(label.clone())
                        .tab_stop(true)
                        .tab_index(0)
                        .border_1()
                        .px_2()
                        .py_1()
                        .focus_visible(|style| style.border_color(rgb(0x1253ff)))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.command(crate::backend::Command::SelectHost(member.clone()));
                            cx.notify();
                        }))
                        .child(label),
                );
            }
            let mut collections = div().flex().flex_wrap().gap_2();
            let choices = std::iter::once((None, "All tracks".to_string())).chain(
                self.playlists
                    .iter()
                    .map(|p| (Some(p.0.clone()), p.1.clone())),
            );
            for (id, label) in choices {
                collections = collections.child(
                    div()
                        .id(gpui::SharedString::from(format!(
                            "collection-{}",
                            id.as_deref().unwrap_or("all")
                        )))
                        .role(Role::Button)
                        .aria_label(label.clone())
                        .tab_stop(true)
                        .tab_index(0)
                        .border_1()
                        .px_2()
                        .py_1()
                        .focus_visible(|style| style.border_color(rgb(0x1253ff)))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.collection = id.clone();
                            this.tracks = id
                                .as_ref()
                                .and_then(|id| {
                                    this.playlists
                                        .iter()
                                        .find(|p| &p.0 == id)
                                        .map(|p| p.2.clone())
                                })
                                .unwrap_or_else(|| this.library.clone());
                            this.filtered = filtered_indices(&this.tracks, &this.query);
                            this.selected = (!this.filtered.is_empty()).then_some(0);
                            cx.notify();
                        }))
                        .child(label),
                );
            }
            return controls.child(collections).into_any_element();
        }
        let _ = cx;
        div().text_xl().child("Tracks (demo)").into_any_element()
    }
}
