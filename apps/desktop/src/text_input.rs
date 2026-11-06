use std::ops::Range;

use gpui::{
    App, Bounds, ClipboardItem, Context, CursorStyle, ElementInputHandler, EntityInputHandler,
    FocusHandle, KeyBinding, MouseButton, Pixels, Point, Role, ShapedLine, SharedString, TextRun,
    UTF16Selection, UnderlineStyle, Window, actions, canvas, div, fill, point, prelude::*, px, rgb,
    rgba, size,
};
use unicode_segmentation::UnicodeSegmentation;

actions!(
    search,
    [
        Backspace,
        Delete,
        Left,
        Right,
        SelectLeft,
        SelectRight,
        SelectAll,
        Home,
        End,
        Copy,
        Cut,
        Paste
    ]
);

pub fn bind_keys(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("backspace", Backspace, Some("Search")),
        KeyBinding::new("delete", Delete, Some("Search")),
        KeyBinding::new("left", Left, Some("Search")),
        KeyBinding::new("right", Right, Some("Search")),
        KeyBinding::new("shift-left", SelectLeft, Some("Search")),
        KeyBinding::new("shift-right", SelectRight, Some("Search")),
        KeyBinding::new("home", Home, Some("Search")),
        KeyBinding::new("end", End, Some("Search")),
        KeyBinding::new("cmd-a", SelectAll, Some("Search")),
        KeyBinding::new("ctrl-a", SelectAll, Some("Search")),
        KeyBinding::new("cmd-c", Copy, Some("Search")),
        KeyBinding::new("ctrl-c", Copy, Some("Search")),
        KeyBinding::new("cmd-x", Cut, Some("Search")),
        KeyBinding::new("ctrl-x", Cut, Some("Search")),
        KeyBinding::new("cmd-v", Paste, Some("Search")),
        KeyBinding::new("ctrl-v", Paste, Some("Search")),
    ]);
}

pub struct SearchInput {
    pub focus: FocusHandle,
    pub content: SharedString,
    selection: Range<usize>,
    reversed: bool,
    marked: Option<Range<usize>>,
    layout: Option<ShapedLine>,
    bounds: Option<Bounds<Pixels>>,
    scroll_x: Pixels,
    dragging: bool,
}

impl SearchInput {
    pub fn new(cx: &mut Context<Self>) -> Self {
        Self {
            focus: cx.focus_handle().tab_stop(true),
            content: "".into(),
            selection: 0..0,
            reversed: false,
            marked: None,
            layout: None,
            bounds: None,
            scroll_x: px(0.),
            dragging: false,
        }
    }

    fn cursor(&self) -> usize {
        if self.reversed {
            self.selection.start
        } else {
            self.selection.end
        }
    }

    fn utf8_offset(&self, utf16: usize) -> usize {
        let mut units = 0;
        for (index, ch) in self.content.char_indices() {
            if units >= utf16 {
                return index;
            }
            units += ch.len_utf16();
        }
        self.content.len()
    }

    fn utf16_offset(&self, utf8: usize) -> usize {
        self.content[..utf8].encode_utf16().count()
    }

    fn utf8_range(&self, range: Range<usize>) -> Range<usize> {
        let start = self.utf8_offset(range.start);
        start..self.utf8_offset(range.end).max(start)
    }

    fn utf16_range(&self, range: Range<usize>) -> Range<usize> {
        self.utf16_offset(range.start)..self.utf16_offset(range.end)
    }

    fn move_cursor(
        &mut self,
        offset: usize,
        extend: bool,
        window: &Window,
        cx: &mut Context<Self>,
    ) {
        let anchor = if self.reversed {
            self.selection.end
        } else {
            self.selection.start
        };
        self.selection = if extend {
            anchor.min(offset)..anchor.max(offset)
        } else {
            offset..offset
        };
        self.reversed = extend && offset < anchor;
        window.notify_text_selection_changed(&self.focus);
        cx.notify();
    }

    fn adjacent(&self, forward: bool) -> usize {
        let cursor = self.cursor();
        if forward {
            self.content
                .grapheme_indices(true)
                .find_map(|(i, _)| (i > cursor).then_some(i))
                .unwrap_or(self.content.len())
        } else {
            self.content
                .grapheme_indices(true)
                .rev()
                .find_map(|(i, _)| (i < cursor).then_some(i))
                .unwrap_or(0)
        }
    }

    fn arrow(&mut self, forward: bool, extend: bool, window: &Window, cx: &mut Context<Self>) {
        let offset = if !extend && !self.selection.is_empty() {
            if forward {
                self.selection.end
            } else {
                self.selection.start
            }
        } else {
            self.adjacent(forward)
        };
        self.move_cursor(offset, extend, window, cx);
    }

    fn erase(&mut self, forward: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.selection.is_empty() {
            self.move_cursor(self.adjacent(forward), true, window, cx);
        }
        self.replace_text_in_range(None, "", window, cx);
    }

    fn copy(&self, cx: &mut Context<Self>) {
        if !self.selection.is_empty() {
            cx.write_to_clipboard(ClipboardItem::new_string(
                self.content[self.selection.clone()].to_owned(),
            ));
        }
    }

    fn index_at(&self, position: Point<Pixels>) -> usize {
        match (&self.layout, self.bounds) {
            (Some(line), Some(bounds)) if line.text == self.content => {
                line.closest_index_for_x(position.x - bounds.left() + self.scroll_x)
            }
            _ => self.content.len(),
        }
    }
}

impl EntityInputHandler for SearchInput {
    fn text_for_range(
        &mut self,
        range: Range<usize>,
        actual: &mut Option<Range<usize>>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<String> {
        let range = self.utf8_range(range);
        *actual = Some(self.utf16_range(range.clone()));
        Some(self.content[range].to_owned())
    }

    fn selected_text_range(
        &mut self,
        _: bool,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        Some(UTF16Selection {
            range: self.utf16_range(self.selection.clone()),
            reversed: self.reversed,
        })
    }

    fn set_selected_text_range(
        &mut self,
        range: Range<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.selection = self.utf8_range(range);
        self.reversed = false;
        window.notify_text_selection_changed(&self.focus);
        cx.notify();
    }

    fn text_length_utf16(&mut self, _: &mut Window, _: &mut Context<Self>) -> Option<usize> {
        Some(self.content.encode_utf16().count())
    }

    fn marked_text_range(&self, _: &mut Window, _: &mut Context<Self>) -> Option<Range<usize>> {
        self.marked.clone().map(|range| self.utf16_range(range))
    }

    fn unmark_text(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.marked = None;
        window.notify_text_input_changed(&self.focus);
        cx.notify();
    }

    fn replace_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let range = range
            .map(|range| self.utf8_range(range))
            .or(self.marked.clone())
            .unwrap_or(self.selection.clone());
        let text = text.replace(['\n', '\r'], " ");
        self.content = format!(
            "{}{}{}",
            &self.content[..range.start],
            text,
            &self.content[range.end..]
        )
        .into();
        let cursor = range.start + text.len();
        self.selection = cursor..cursor;
        self.reversed = false;
        self.marked = None;
        window.notify_text_input_changed(&self.focus);
        cx.notify();
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        text: &str,
        selected: Option<Range<usize>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let text = text.replace(['\n', '\r'], " ");
        let range = range
            .map(|range| self.utf8_range(range))
            .or(self.marked.clone())
            .unwrap_or(self.selection.clone());
        let start_utf16 = self.utf16_offset(range.start);
        let length_utf16 = text.encode_utf16().count();
        self.replace_text_in_range(Some(self.utf16_range(range.clone())), &text, window, cx);
        self.marked = (!text.is_empty()).then_some(range.start..range.start + text.len());
        if let Some(selected) = selected {
            self.selection = self.utf8_range(
                start_utf16 + selected.start.min(length_utf16)
                    ..start_utf16 + selected.end.min(length_utf16),
            );
        }
    }

    fn bounds_for_range(
        &mut self,
        range: Range<usize>,
        bounds: Bounds<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        let line = self.layout.as_ref()?;
        if line.text != self.content {
            return None;
        }
        let range = self.utf8_range(range);
        Some(Bounds::from_corners(
            point(
                bounds.left() + line.x_for_index(range.start) - self.scroll_x,
                bounds.top(),
            ),
            point(
                bounds.left() + line.x_for_index(range.end) - self.scroll_x,
                bounds.bottom(),
            ),
        ))
    }

    fn selection_bounds_for_range(
        &mut self,
        range: Range<usize>,
        bounds: Bounds<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<Bounds<Pixels>> {
        self.bounds_for_range(range, bounds, window, cx)
            .into_iter()
            .collect()
    }

    fn character_index_for_point(
        &mut self,
        point: Point<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<usize> {
        self.bounds?;
        if self.layout.as_ref()?.text != self.content {
            return None;
        }
        Some(self.utf16_offset(self.index_at(point)))
    }
}

impl Render for SearchInput {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let input = cx.entity();
        let paint_input = input.clone();
        div()
            .id("search")
            .key_context("Search")
            .track_focus(&self.focus)
            .tab_stop(true)
            .role(Role::TextInput)
            .accessibility_id("track-search")
            .aria_label("Search tracks")
            .aria_value(self.content.clone())
            .border_1()
            .border_color(rgb(0x5c6069))
            .focus_visible(|style| style.border_color(rgb(0x2a65d1)))
            .rounded_md()
            .p_2()
            .cursor(CursorStyle::IBeam)
            .on_action(cx.listener(|this, _: &Left, w, cx| this.arrow(false, false, w, cx)))
            .on_action(cx.listener(|this, _: &Right, w, cx| this.arrow(true, false, w, cx)))
            .on_action(cx.listener(|this, _: &SelectLeft, w, cx| this.arrow(false, true, w, cx)))
            .on_action(cx.listener(|this, _: &SelectRight, w, cx| this.arrow(true, true, w, cx)))
            .on_action(cx.listener(|this, _: &Home, w, cx| this.move_cursor(0, false, w, cx)))
            .on_action(cx.listener(|this, _: &End, w, cx| {
                this.move_cursor(this.content.len(), false, w, cx)
            }))
            .on_action(cx.listener(|this, _: &SelectAll, w, cx| {
                this.move_cursor(0, false, w, cx);
                this.move_cursor(this.content.len(), true, w, cx);
            }))
            .on_action(cx.listener(|this, _: &Backspace, w, cx| this.erase(false, w, cx)))
            .on_action(cx.listener(|this, _: &Delete, w, cx| this.erase(true, w, cx)))
            .on_action(cx.listener(|this, _: &Copy, _, cx| this.copy(cx)))
            .on_action(cx.listener(|this, _: &Cut, w, cx| {
                this.copy(cx);
                this.replace_text_in_range(None, "", w, cx);
            }))
            .on_action(cx.listener(|this, _: &Paste, w, cx| {
                if let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) {
                    this.replace_text_in_range(None, &text, w, cx);
                }
            }))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, event, w, cx| {
                    w.focus(&this.focus, cx);
                    this.dragging = true;
                    this.move_cursor(this.index_at(event.position), event.modifiers.shift, w, cx);
                }),
            )
            .on_mouse_move(cx.listener(|this, event, w, cx| {
                if this.dragging {
                    this.move_cursor(this.index_at(event.position), true, w, cx);
                }
            }))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|this, _, _, _| this.dragging = false),
            )
            .on_mouse_up_out(
                MouseButton::Left,
                cx.listener(|this, _, _, _| this.dragging = false),
            )
            .child(
                canvas(
                    move |bounds, window, cx| {
                        let this = input.read(cx);
                        let style = window.text_style();
                        let display = if this.content.is_empty() {
                            "Search tracks".into()
                        } else {
                            this.content.clone()
                        };
                        let run = TextRun {
                            len: display.len(),
                            font: style.font(),
                            color: if this.content.is_empty() {
                                rgb(0x5c6069).into()
                            } else {
                                style.color
                            },
                            background_color: None,
                            underline: None,
                            strikethrough: None,
                        };
                        let runs = if let Some(marked) = &this.marked {
                            vec![
                                TextRun {
                                    len: marked.start,
                                    ..run.clone()
                                },
                                TextRun {
                                    len: marked.len(),
                                    underline: Some(UnderlineStyle {
                                        color: Some(run.color),
                                        thickness: px(1.),
                                        wavy: false,
                                    }),
                                    ..run.clone()
                                },
                                TextRun {
                                    len: display.len() - marked.end,
                                    ..run
                                },
                            ]
                            .into_iter()
                            .filter(|run| run.len > 0)
                            .collect()
                        } else {
                            vec![run]
                        };
                        let line = window.text_system().shape_line(
                            display,
                            style.font_size.to_pixels(window.rem_size()),
                            &runs,
                            None,
                        );
                        let cursor_x = line.x_for_index(this.cursor());
                        let scroll_x = if cursor_x < this.scroll_x {
                            cursor_x
                        } else {
                            this.scroll_x.max(cursor_x - bounds.size.width + px(2.))
                        }
                        .max(px(0.));
                        (line, scroll_x)
                    },
                    move |bounds, (line, scroll_x), window, cx| {
                        let this = paint_input.read(cx);
                        let focus = this.focus.clone();
                        let selection = this.selection.clone();
                        let cursor = this.cursor();
                        window.handle_input(
                            &focus,
                            ElementInputHandler::new(bounds, paint_input.clone()),
                            cx,
                        );
                        window.with_content_mask(Some(gpui::ContentMask { bounds }), |window| {
                            if focus.is_focused(window) && !selection.is_empty() {
                                window.paint_quad(fill(
                                    Bounds::from_corners(
                                        point(
                                            bounds.left() + line.x_for_index(selection.start)
                                                - scroll_x,
                                            bounds.top(),
                                        ),
                                        point(
                                            bounds.left() + line.x_for_index(selection.end)
                                                - scroll_x,
                                            bounds.bottom(),
                                        ),
                                    ),
                                    rgba(0x2a65d140),
                                ));
                            }
                            let _ = line.paint(
                                point(bounds.left() - scroll_x, bounds.top()),
                                bounds.size.height,
                                gpui::TextAlign::Left,
                                None,
                                window,
                                cx,
                            );
                            if focus.is_focused(window) && selection.is_empty() {
                                window.paint_quad(fill(
                                    Bounds::new(
                                        point(
                                            bounds.left() + line.x_for_index(cursor) - scroll_x,
                                            bounds.top(),
                                        ),
                                        size(px(1.), bounds.size.height),
                                    ),
                                    rgb(0x2a65d1),
                                ));
                            }
                        });
                        paint_input.update(cx, |this, _| {
                            this.layout = Some(line);
                            this.bounds = Some(bounds);
                            this.scroll_x = scroll_x;
                        });
                    },
                )
                .w_full()
                .h(px(24.)),
            )
    }
}
