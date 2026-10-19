//! GTK 4 / libadwaita front end: a client of `planmeterd`'s control socket.

mod accounts;
mod chart;
mod dashboard;
mod preferences;
mod qr;
mod remote;
mod screenshot;
mod state;
mod widgets;
mod window;

use adw::prelude::*;
use gtk::{gio, glib};
use planmeter::client::{default_socket_path, Client};
use planmeter::range::TimeRange;
use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;
use window::MainWindow;

pub const APP_ID: &str = "com.neilgoldader.PlanMeter";

const USAGE: &str = "Usage: planmeter [OPTIONS]

Shows AI coding-agent spend, tokens, and limits from planmeterd.

Options:
  --socket PATH           Control socket (default: $PLANMETER_CONTROL_SOCKET,
                          $XDG_RUNTIME_DIR/planmeter/control.sock)
  --screenshot FILE.png   Render the window to a PNG and exit
    --size WxH            Window size for the screenshot (default 1200x800)
    --page NAME           dashboard, accounts, remote, or preferences
    --range ID            lastHour, today, day, week, month, or quarter
    --dark                Use the dark style
    --pair                Show a pairing code first (with --page remote)
    --action NAME         Activate an action first, e.g. app.about or
                          win.revoke-device::ID (repeatable)
    --delay MS            Wait this long after loading (default 900)
  --version               Print the version
  -h, --help              Show this help";

#[derive(Debug, Clone, Default)]
pub struct ScreenshotOptions {
    pub path: PathBuf,
    pub width: i32,
    pub height: i32,
    pub page: String,
    pub range: Option<TimeRange>,
    pub dark: bool,
    pub pair: bool,
    /// Detailed action names to activate before capturing, e.g. `app.about`.
    pub actions: Vec<String>,
    pub delay_ms: u64,
}

#[derive(Debug, Clone, Default)]
struct Options {
    socket: Option<PathBuf>,
    screenshot: Option<ScreenshotOptions>,
}

fn parse_args(args: impl Iterator<Item = String>) -> Result<Options, String> {
    let mut options = Options::default();
    let mut shot = ScreenshotOptions {
        width: 1200,
        height: 800,
        delay_ms: 900,
        page: "dashboard".into(),
        ..Default::default()
    };
    let mut wants_shot = false;
    let mut args = args.peekable();
    while let Some(arg) = args.next() {
        let mut value = |name: &str| args.next().ok_or_else(|| format!("{name} needs a value"));
        match arg.as_str() {
            "--socket" => options.socket = Some(PathBuf::from(value("--socket")?)),
            "--screenshot" => {
                shot.path = PathBuf::from(value("--screenshot")?);
                wants_shot = true;
            }
            "--size" => {
                let raw = value("--size")?;
                let (w, h) = raw.split_once('x').ok_or("--size takes WIDTHxHEIGHT")?;
                shot.width = w.parse().map_err(|_| "bad --size width")?;
                shot.height = h.parse().map_err(|_| "bad --size height")?;
            }
            "--page" => {
                shot.page = value("--page")?;
                if !["dashboard", "accounts", "remote", "preferences"].contains(&shot.page.as_str())
                {
                    return Err(format!("unknown page {:?}", shot.page));
                }
            }
            "--range" => {
                let id = value("--range")?;
                shot.range =
                    Some(TimeRange::from_id(&id).ok_or_else(|| format!("unknown range {id:?}"))?);
            }
            "--dark" => shot.dark = true,
            "--pair" => shot.pair = true,
            "--action" => shot.actions.push(value("--action")?),
            "--delay" => {
                shot.delay_ms = value("--delay")?
                    .parse()
                    .map_err(|_| "--delay takes milliseconds")?
            }
            "--version" => {
                println!("planmeter {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            "-h" | "--help" => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            other => return Err(format!("unknown option {other:?}")),
        }
    }
    if wants_shot {
        options.screenshot = Some(shot);
    }
    Ok(options)
}

pub fn main() -> glib::ExitCode {
    let options = match parse_args(std::env::args().skip(1)) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("planmeter: {e}\n\n{USAGE}");
            return glib::ExitCode::from(2);
        }
    };
    gio::resources_register_include!("planmeter.gresource").expect("bundled resources");
    glib::set_application_name("PlanMeter");
    let flags = if options.screenshot.is_some() {
        gio::ApplicationFlags::NON_UNIQUE
    } else {
        gio::ApplicationFlags::default()
    };
    let app = adw::Application::builder()
        .application_id(APP_ID)
        .resource_base_path("/com/neilgoldader/PlanMeter")
        .flags(flags)
        .build();

    let client = Client::new(options.socket.clone().unwrap_or_else(default_socket_path));
    let main_window: Rc<RefCell<Option<Rc<MainWindow>>>> = Rc::new(RefCell::new(None));
    let exit_code = Rc::new(Cell::new(0u8));

    app.connect_startup(|app| {
        app.set_accels_for_action("win.refresh", &["<Control>r", "F5"]);
        app.set_accels_for_action("app.preferences", &["<Control>comma"]);
        app.set_accels_for_action("app.quit", &["<Control>q"]);
        app.set_accels_for_action("window.close", &["<Control>w"]);
        for (i, range) in TimeRange::ALL.iter().enumerate() {
            app.set_accels_for_action(
                &format!("win.range::{}", range.id()),
                &[&format!("<Alt>{}", i + 1)],
            );
        }
    });

    let (slot, shot, code) = (
        main_window.clone(),
        options.screenshot.clone(),
        exit_code.clone(),
    );
    app.connect_activate(move |app| {
        if let Some(win) = slot.borrow().as_ref() {
            win.present();
            return;
        }
        if let Some(shot) = &shot {
            if shot.dark {
                adw::StyleManager::default().set_color_scheme(adw::ColorScheme::ForceDark);
            } else {
                adw::StyleManager::default().set_color_scheme(adw::ColorScheme::ForceLight);
            }
        }
        let win = MainWindow::new(app, client.clone());
        install_app_actions(app, &win);
        if let Some(shot) = &shot {
            screenshot::run(&win, shot.clone(), code.clone());
        }
        win.present();
        *slot.borrow_mut() = Some(win);
    });

    // GTK must not parse our options.
    let status = app.run_with_args::<&str>(&[]);
    match exit_code.get() {
        0 => status,
        n => glib::ExitCode::from(n),
    }
}

fn install_app_actions(app: &adw::Application, win: &Rc<MainWindow>) {
    let w = Rc::downgrade(win);
    let preferences = gio::ActionEntry::builder("preferences")
        .activate(move |_: &adw::Application, _, _| {
            if let Some(win) = w.upgrade() {
                preferences::present(&win, None);
            }
        })
        .build();
    let w = Rc::downgrade(win);
    let about = gio::ActionEntry::builder("about")
        .activate(move |_: &adw::Application, _, _| {
            if let Some(win) = w.upgrade() {
                present_about(&win.window);
            }
        })
        .build();
    let quit = gio::ActionEntry::builder("quit")
        .activate(|app: &adw::Application, _, _| app.quit())
        .build();
    app.add_action_entries([preferences, about, quit]);
}

fn present_about(parent: &adw::ApplicationWindow) {
    let about = adw::AboutDialog::builder()
        .application_name("PlanMeter")
        .application_icon(APP_ID)
        .developer_name("Neil Goldader")
        .version(env!("CARGO_PKG_VERSION"))
        .comments(
            "Spend, tokens, and limits for your AI coding agents, across Personal and Work plans.",
        )
        .website("https://github.com/avatarneil/planmeter")
        .issue_url("https://github.com/avatarneil/planmeter/issues")
        .license_type(gtk::License::MitX11)
        .copyright("© 2026 Neil Goldader")
        .build();
    about.present(Some(parent));
}
