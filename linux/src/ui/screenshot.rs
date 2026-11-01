//! `--screenshot`: render the window to a PNG once data has loaded, then
//! quit. The Linux counterpart of the Mac app's `--snapshot`.

use super::window::MainWindow;
use super::ScreenshotOptions;
use adw::prelude::*;
use gtk::{glib, graphene};
use std::cell::Cell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

/// Give up if the daemon never answers.
const TIMEOUT: Duration = Duration::from_secs(30);

pub fn run(win: &Rc<MainWindow>, options: ScreenshotOptions, exit_code: Rc<Cell<u8>>) {
    win.disable_persistence();
    win.window.set_default_size(options.width, options.height);
    if let Some(range) = options.range {
        win.override_range(range);
    }

    let app = win.app.clone();
    let code = exit_code.clone();
    let timeout = glib::timeout_add_local_once(TIMEOUT, move || {
        eprintln!("planmeter: screenshot timed out waiting for planmeterd");
        code.set(1);
        app.quit();
    });
    let timeout = Rc::new(Cell::new(Some(timeout)));

    win.when_loaded(move |win| {
        win.show_page(if options.page == "preferences" {
            "dashboard"
        } else {
            &options.page
        });
        if options.page == "preferences" {
            super::preferences::present(win, None);
        }
        if options.pair && options.page == "remote" {
            win.create_invite();
        }
        for detailed in &options.actions {
            match gtk::gio::Action::parse_detailed_name(detailed) {
                Ok((name, target)) => {
                    if let Err(e) = WidgetExt::activate_action(&win.window, &name, target.as_ref())
                    {
                        eprintln!("planmeter: cannot activate {detailed}: {e}");
                    }
                }
                Err(e) => eprintln!("planmeter: bad action name {detailed}: {e}"),
            }
        }
        // Let layout, icons, and transitions settle before capturing.
        let settle = Duration::from_millis(options.delay_ms);
        let win = win.clone();
        glib::timeout_add_local_once(settle, move || {
            if let Some(id) = timeout.take() {
                id.remove();
            }
            attempt(win, options.path, exit_code, 10);
        });
    });
}

/// Captures, retrying briefly if the window has not produced a frame yet
/// (a slow X server can map it after the data arrives).
fn attempt(win: Rc<MainWindow>, path: PathBuf, exit_code: Rc<Cell<u8>>, tries: u32) {
    match capture(&win.window, &path) {
        Ok(()) => println!("planmeter: wrote {}", path.display()),
        Err(_) if tries > 1 => {
            win.window.queue_draw();
            glib::timeout_add_local_once(Duration::from_millis(300), move || {
                attempt(win, path, exit_code, tries - 1);
            });
            return;
        }
        Err(e) => {
            eprintln!("planmeter: screenshot failed: {e}");
            exit_code.set(1);
        }
    }
    win.app.quit();
}

fn capture(window: &adw::ApplicationWindow, path: &Path) -> Result<(), String> {
    let (width, height) = (window.width(), window.height());
    if width <= 0 || height <= 0 {
        return Err("the window has no size yet".into());
    }
    let paintable = gtk::WidgetPaintable::new(Some(window));
    let snapshot = gtk::Snapshot::new();
    paintable.snapshot(&snapshot, f64::from(width), f64::from(height));
    let node = snapshot.to_node().ok_or("nothing was rendered")?;
    let renderer = window.renderer().ok_or("the window has no renderer")?;
    let bounds = graphene::Rect::new(0.0, 0.0, width as f32, height as f32);
    let texture = renderer.render_texture(&node, Some(&bounds));
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    texture.save_to_png(path).map_err(|e| e.to_string())
}
