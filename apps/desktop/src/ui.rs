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
}

impl Desktop {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let tracks = fixture_tracks(DEFAULT_TRACK_COUNT);
        let search = cx.new(SearchInput::new);
        window.focus(&search.read(cx).focus, cx);
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
        self.playback.toggle(selected);
        cx.notify();
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
            .and_then(|id| self.tracks.iter().find(|track| track.id == id))
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
            .child(div().text_xl().child("Tracks"))
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
                                cx.processor(|this, range, _, cx| {
                                    range
                                        .map(|index| {
                                            let track = &this.tracks[this.filtered[index]];
                                            let selected = this.selected == Some(index);
                                            div()
                                                .id(("track", track.id))
                                                .role(Role::ListBoxOption)
                                                .accessibility_id(format!("track-{}", track.id))
                                                .aria_label(format!(
                                                    "{} — {}",
                                                    track.title, track.artist
                                                ))
                                                .aria_position_in_set(index)
                                                .aria_selected(selected)
                                                .when(selected, |row| row.aria_active_descendant())
                                                .h(px(36.))
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
                                                    "{} · {} — {}",
                                                    index + 1,
                                                    track.title,
                                                    track.artist
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
    }
}
