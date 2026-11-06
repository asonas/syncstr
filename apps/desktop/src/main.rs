mod model;
mod text_input;
mod ui;

use gpui::{App, AppContext, Bounds, WindowBounds, WindowOptions, px, size};

fn main() {
    gpui_platform::application().run(|cx: &mut App| {
        text_input::bind_keys(cx);
        ui::bind_keys(cx);
        cx.on_window_closed(|cx, _| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        let bounds = Bounds::centered(None, size(px(800.), px(640.)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                window_min_size: Some(size(px(480.), px(400.))),
                titlebar: Some(gpui::TitlebarOptions {
                    title: Some("Syncstr Desktop".into()),
                    ..Default::default()
                }),
                ..Default::default()
            },
            |window, cx| cx.new(|cx| ui::Desktop::new(window, cx)),
        )
        .expect("could not open Syncstr Desktop window");
        cx.activate(true);
    });
}
