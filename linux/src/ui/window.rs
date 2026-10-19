//! The main window: header bar, adaptive page switcher, data refresh, the
//! daemon-unavailable state, and spend alerts.

use super::accounts::AccountsPage;
use super::dashboard::DashboardPage;
use super::remote::{RemoteAction, RemotePage};
use super::state::UiState;
use super::widgets::markup_escape;
use super::APP_ID;
use adw::prelude::*;
use chrono::{Local, Utc};
use gtk::{gio, glib};
use planmeter::client::{Client, ClientError, Dashboard};
use planmeter::format;
use planmeter::models::{PlanGroup, RemoteSettingsBody, RemoteStatus, SpendThreshold};
use planmeter::notify;
use planmeter::range::{Resolution, TimeRange};
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::rc::Rc;
use std::time::{Duration, Instant};

const AUTO_REFRESH: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Refresh {
    /// Read the latest report; the daemon rescans when its data is stale.
    Auto,
    /// The refresh button: rescan transcripts and account-wide usage first.
    User,
}

type Callback = Box<dyn FnOnce(&Rc<MainWindow>)>;

pub struct MainWindow {
    pub app: adw::Application,
    pub window: adw::ApplicationWindow,
    client: Client,
    toasts: adw::ToastOverlay,
    main_stack: gtk::Stack,
    pub view_stack: adw::ViewStack,
    banner: adw::Banner,
    range_button: gtk::MenuButton,
    refresh_stack: gtk::Stack,
    status_page: adw::StatusPage,
    status_detail: gtk::Label,
    start_button: gtk::Button,
    dashboard: Rc<DashboardPage>,
    accounts: AccountsPage,
    remote: Rc<RemotePage>,
    state: RefCell<UiState>,
    data: RefCell<Option<Dashboard>>,
    generation: Cell<u64>,
    in_flight: Cell<u32>,
    last_refresh: Cell<Option<Instant>>,
    clock24: Cell<bool>,
    on_loaded: RefCell<Vec<Callback>>,
    ticks: Cell<u64>,
    /// Persist alert state and window size on change, not on every refresh.
    persist_alerts: Cell<bool>,
    /// Off for screenshots, which must not touch saved preferences.
    persist: Cell<bool>,
}

fn clock_24h() -> bool {
    if let Some(schema) = gio::SettingsSchemaSource::default()
        .and_then(|s| s.lookup("org.gnome.desktop.interface", true))
    {
        if schema.has_key("clock-format") {
            return gio::Settings::new("org.gnome.desktop.interface").string("clock-format")
                != "12h";
        }
    }
    let locale = ["LC_ALL", "LC_TIME", "LANG"]
        .iter()
        .find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()))
        .unwrap_or_default();
    !(locale.starts_with("en_US") || locale.starts_with("en_CA") || locale.starts_with("en_AU"))
}

impl MainWindow {
    pub fn new(app: &adw::Application, client: Client) -> Rc<Self> {
        let state = UiState::load();
        let window = adw::ApplicationWindow::builder()
            .application(app)
            .title("PlanMeter")
            .default_width(state.width.max(360))
            .default_height(state.height.max(400))
            .maximized(state.maximized)
            .width_request(360)
            .height_request(400)
            .build();
        let toasts = adw::ToastOverlay::new();

        // Header: range menu, page switcher, refresh, primary menu.
        let header = adw::HeaderBar::new();
        let range_menu = gio::Menu::new();
        for range in TimeRange::ALL {
            range_menu.append(
                Some(range.display_name()),
                Some(&format!("win.range::{}", range.id())),
            );
        }
        let range_button = gtk::MenuButton::builder()
            .label(state.range().short_label())
            .always_show_arrow(true)
            .menu_model(&range_menu)
            .tooltip_text("Range")
            .build();
        header.pack_start(&range_button);

        let view_stack = adw::ViewStack::new();
        let switcher = adw::ViewSwitcher::builder()
            .stack(&view_stack)
            .policy(adw::ViewSwitcherPolicy::Wide)
            .build();
        let title = adw::WindowTitle::new("PlanMeter", "");
        title.set_visible(false);
        let title_box = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        title_box.append(&switcher);
        title_box.append(&title);
        header.set_title_widget(Some(&title_box));

        let primary = gio::Menu::new();
        let section = gio::Menu::new();
        section.append(Some("_Refresh"), Some("win.refresh"));
        primary.append_section(None, &section);
        let section = gio::Menu::new();
        section.append(Some("_Preferences"), Some("app.preferences"));
        section.append(Some("_About PlanMeter"), Some("app.about"));
        primary.append_section(None, &section);
        let menu_button = gtk::MenuButton::builder()
            .icon_name("open-menu-symbolic")
            .menu_model(&primary)
            .primary(true)
            .tooltip_text("Main Menu")
            .build();
        header.pack_end(&menu_button);
        let refresh_stack = gtk::Stack::new();
        let refresh = gtk::Button::builder()
            .icon_name("view-refresh-symbolic")
            .action_name("win.refresh")
            .tooltip_text("Refresh (Ctrl+R)")
            .build();
        refresh.update_property(&[gtk::accessible::Property::Label("Refresh")]);
        refresh_stack.add_named(&refresh, Some("button"));
        let spinner = gtk::Spinner::builder()
            .spinning(true)
            .tooltip_text("Refreshing…")
            .halign(gtk::Align::Center)
            .valign(gtk::Align::Center)
            .build();
        refresh_stack.add_named(&spinner, Some("spinner"));
        header.pack_end(&refresh_stack);

        // Pages.
        let dashboard = DashboardPage::new();
        let socket = client.socket().to_path_buf();
        let accounts = AccountsPage::new(socket.clone());
        let weak_slot: Rc<RefCell<std::rc::Weak<MainWindow>>> =
            Rc::new(RefCell::new(std::rc::Weak::new()));
        let slot = weak_slot.clone();
        let remote = RemotePage::new(&toasts, move |action| {
            if let Some(win) = slot.borrow().upgrade() {
                win.remote_action(action);
            }
        });
        view_stack.add_titled_with_icon(
            &dashboard.root,
            Some("dashboard"),
            "Dashboard",
            "planmeter-dashboard-symbolic",
        );
        view_stack.add_titled_with_icon(
            &accounts.root,
            Some("accounts"),
            "Accounts",
            "system-users-symbolic",
        );
        view_stack.add_titled_with_icon(
            &remote.root,
            Some("remote"),
            "Remote",
            "planmeter-remote-symbolic",
        );

        let banner = adw::Banner::new("");
        banner.set_revealed(false);
        let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
        content.append(&banner);
        content.append(&view_stack);

        // Loading and daemon-unavailable states.
        let loading = adw::StatusPage::builder().title("Loading Usage…").build();
        let loading_spinner = gtk::Spinner::builder()
            .spinning(true)
            .width_request(32)
            .height_request(32)
            .halign(gtk::Align::Center)
            .build();
        loading.set_child(Some(&loading_spinner));
        let status_box = gtk::Box::new(gtk::Orientation::Vertical, 12);
        status_box.set_halign(gtk::Align::Center);
        let start_button = gtk::Button::builder()
            .label("Start Service")
            .action_name("win.start-daemon")
            .build();
        start_button.add_css_class("pill");
        start_button.add_css_class("suggested-action");
        let retry = gtk::Button::builder()
            .label("Try Again")
            .action_name("win.refresh")
            .build();
        retry.add_css_class("pill");
        status_box.append(&start_button);
        status_box.append(&retry);
        let status_detail = gtk::Label::builder()
            .wrap(true)
            .justify(gtk::Justification::Center)
            .max_width_chars(60)
            .build();
        status_detail.add_css_class("caption");
        status_detail.add_css_class("dim-label");
        status_detail.set_selectable(true);
        status_detail.set_margin_top(12);
        status_box.append(&status_detail);
        let status_page = adw::StatusPage::builder()
            .icon_name("com.neilgoldader.PlanMeter-symbolic")
            .child(&status_box)
            .vexpand(true)
            .build();

        let main_stack = gtk::Stack::builder()
            .transition_type(gtk::StackTransitionType::Crossfade)
            .build();
        main_stack.add_named(&loading, Some("loading"));
        main_stack.add_named(&content, Some("content"));
        main_stack.add_named(&status_page, Some("status"));
        main_stack.set_visible_child_name("loading");

        let switcher_bar = adw::ViewSwitcherBar::builder().stack(&view_stack).build();
        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&header);
        toolbar.set_content(Some(&main_stack));
        toolbar.add_bottom_bar(&switcher_bar);
        toasts.set_child(Some(&toolbar));
        window.set_content(Some(&toasts));

        // Adaptive layout: stack side-by-side sections, then move the page
        // switcher to the bottom bar on phone-sized windows.
        let medium = adw::Breakpoint::new(adw::BreakpointCondition::new_length(
            adw::BreakpointConditionLengthType::MaxWidth,
            860.0,
            adw::LengthUnit::Sp,
        ));
        medium.add_setter(
            &dashboard.lower_row,
            "orientation",
            Some(&gtk::Orientation::Vertical.to_value()),
        );
        medium.add_setter(
            &dashboard.limits_column,
            "width-request",
            Some(&(-1).to_value()),
        );
        window.add_breakpoint(medium);
        let narrow = adw::Breakpoint::new(adw::BreakpointCondition::new_length(
            adw::BreakpointConditionLengthType::MaxWidth,
            640.0,
            adw::LengthUnit::Sp,
        ));
        narrow.add_setter(
            &dashboard.lower_row,
            "orientation",
            Some(&gtk::Orientation::Vertical.to_value()),
        );
        narrow.add_setter(
            &dashboard.limits_column,
            "width-request",
            Some(&(-1).to_value()),
        );
        narrow.add_setter(
            &dashboard.hero_row,
            "orientation",
            Some(&gtk::Orientation::Vertical.to_value()),
        );
        narrow.add_setter(
            &dashboard.limit_stack,
            "width-request",
            Some(&(-1).to_value()),
        );
        for side in ["margin-start", "margin-end", "margin-top"] {
            narrow.add_setter(&dashboard.content, side, Some(&12.to_value()));
        }
        narrow.add_setter(&switcher, "visible", Some(&false.to_value()));
        narrow.add_setter(&title, "visible", Some(&true.to_value()));
        narrow.add_setter(&switcher_bar, "reveal", Some(&true.to_value()));
        window.add_breakpoint(narrow);

        let win = Rc::new(MainWindow {
            app: app.clone(),
            window,
            client,
            toasts,
            main_stack,
            view_stack,
            banner,
            range_button,
            refresh_stack,
            status_page,
            status_detail,
            start_button,
            dashboard,
            accounts,
            remote,
            state: RefCell::new(state),
            data: RefCell::new(None),
            generation: Cell::new(0),
            in_flight: Cell::new(0),
            last_refresh: Cell::new(None),
            clock24: Cell::new(clock_24h()),
            on_loaded: RefCell::new(Vec::new()),
            ticks: Cell::new(0),
            persist_alerts: Cell::new(false),
            persist: Cell::new(true),
        });
        *weak_slot.borrow_mut() = Rc::downgrade(&win);
        win.install_actions();
        win.update_granularity_menu();
        win.connect_lifecycle();
        win
    }

    fn install_actions(self: &Rc<Self>) {
        let w = Rc::downgrade(self);
        let refresh = gio::ActionEntry::builder("refresh")
            .activate(move |_: &adw::ApplicationWindow, _, _| {
                if let Some(win) = w.upgrade() {
                    win.refresh(Refresh::User);
                }
            })
            .build();
        let w = Rc::downgrade(self);
        let range = gio::ActionEntry::builder("range")
            .parameter_type(Some(glib::VariantTy::STRING))
            .state(self.state.borrow().range().id().to_variant())
            .change_state(move |_: &adw::ApplicationWindow, action, value| {
                let Some(id) = value.and_then(|v| v.get::<String>()) else {
                    return;
                };
                let Some(range) = TimeRange::from_id(&id) else {
                    return;
                };
                action.set_state(&id.to_variant());
                if let Some(win) = w.upgrade() {
                    win.set_range(range);
                }
            })
            .build();
        let w = Rc::downgrade(self);
        let current = self.state.borrow().granularity(self.state.borrow().range());
        let granularity = gio::ActionEntry::builder("granularity")
            .parameter_type(Some(glib::VariantTy::STRING))
            .state(current.as_str().to_variant())
            .change_state(move |_: &adw::ApplicationWindow, action, value| {
                let Some(raw) = value.and_then(|v| v.get::<String>()) else {
                    return;
                };
                let Some(g) = Resolution::parse(&raw) else {
                    return;
                };
                action.set_state(&raw.to_variant());
                if let Some(win) = w.upgrade() {
                    win.set_granularity(g);
                }
            })
            .build();
        let w = Rc::downgrade(self);
        let spend_limit = gio::ActionEntry::builder("spend-limit")
            .activate(move |_: &adw::ApplicationWindow, _, _| {
                if let Some(win) = w.upgrade() {
                    super::preferences::present(&win, Some("spending"));
                }
            })
            .build();
        let w = Rc::downgrade(self);
        let plan_groups = gio::ActionEntry::builder("plan-groups")
            .activate(move |_: &adw::ApplicationWindow, _, _| {
                if let Some(win) = w.upgrade() {
                    super::preferences::present(&win, Some("accounts"));
                }
            })
            .build();
        let w = Rc::downgrade(self);
        let start = gio::ActionEntry::builder("start-daemon")
            .activate(move |_: &adw::ApplicationWindow, _, _| {
                if let Some(win) = w.upgrade() {
                    win.start_daemon();
                }
            })
            .build();
        let w = Rc::downgrade(self);
        let revoke = gio::ActionEntry::builder("revoke-device")
            .parameter_type(Some(glib::VariantTy::STRING))
            .activate(move |_: &adw::ApplicationWindow, _, param| {
                let (Some(win), Some(id)) = (w.upgrade(), param.and_then(|p| p.get::<String>()))
                else {
                    return;
                };
                let device = win
                    .data()
                    .and_then(|d| d.remote)
                    .and_then(|r| r.devices.into_iter().find(|d| d.id == id));
                if let Some(device) = device {
                    win.remote_action(RemoteAction::Revoke(device));
                }
            })
            .build();
        self.window.add_action_entries([
            refresh,
            range,
            granularity,
            spend_limit,
            plan_groups,
            start,
            revoke,
        ]);
    }

    fn connect_lifecycle(self: &Rc<Self>) {
        // Refresh every 30 seconds while the window is on screen.
        let w = Rc::downgrade(self);
        glib::timeout_add_local(AUTO_REFRESH, move || {
            let Some(win) = w.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if win.window.is_visible() && !win.window.is_suspended() {
                win.refresh(Refresh::Auto);
            }
            glib::ControlFlow::Continue
        });
        // And when it regains focus after a while.
        let w = Rc::downgrade(self);
        self.window.connect_is_active_notify(move |window| {
            let Some(win) = w.upgrade() else { return };
            let stale = win
                .last_refresh
                .get()
                .is_none_or(|t| t.elapsed() > Duration::from_secs(10));
            if window.is_active() && stale && win.in_flight.get() == 0 {
                win.refresh(Refresh::Auto);
            }
        });
        // A one-second tick for the pairing countdown and relative times.
        let w = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_secs(1), move || {
            let Some(win) = w.upgrade() else {
                return glib::ControlFlow::Break;
            };
            win.tick();
            glib::ControlFlow::Continue
        });
        let w = Rc::downgrade(self);
        self.window.connect_close_request(move |window| {
            if let Some(win) = w.upgrade() {
                let mut st = win.state.borrow_mut();
                st.maximized = window.is_maximized();
                if !st.maximized {
                    let (width, height) = window.default_size();
                    st.width = width;
                    st.height = height;
                }
                drop(st);
                win.save_state();
            }
            glib::Propagation::Proceed
        });
        let w = Rc::downgrade(self);
        self.banner.connect_button_clicked(move |_| {
            if let Some(win) = w.upgrade() {
                win.refresh(Refresh::User);
            }
        });
    }

    fn tick(self: &Rc<Self>) {
        let n = self.ticks.get() + 1;
        self.ticks.set(n);
        let expired = self.remote.tick();
        let on_remote = self.view_stack.visible_child_name().as_deref() == Some("remote");
        // Poll while a pairing code is showing, to see the device appear.
        if (expired || (on_remote && self.remote.has_active_invite() && n % 3 == 0))
            && self.data.borrow().is_some()
        {
            self.reload_remote();
        }
        if n % 15 == 0 {
            self.dashboard.tick(Utc::now());
        }
    }

    pub fn data(&self) -> Option<Dashboard> {
        self.data.borrow().clone()
    }

    pub fn toast(&self, text: &str) {
        self.toasts.add_toast(adw::Toast::new(text));
    }

    pub fn present(self: &Rc<Self>) {
        self.window.present();
        if self.last_refresh.get().is_none() {
            self.refresh(Refresh::Auto);
        }
    }

    /// Shows a range without saving it as the preferred one (screenshots).
    pub fn override_range(&self, range: TimeRange) {
        self.state.borrow_mut().range = range.id().into();
        self.range_button.set_label(range.short_label());
        if let Some(action) = self
            .window
            .lookup_action("range")
            .and_downcast::<gio::SimpleAction>()
        {
            action.set_state(&range.id().to_variant());
        }
        self.update_granularity_menu();
    }

    pub fn show_page(&self, name: &str) {
        self.view_stack.set_visible_child_name(name);
    }

    /// Runs `f` once the first refresh has finished, whatever its outcome
    /// (for screenshots).
    pub fn when_loaded(self: &Rc<Self>, f: impl FnOnce(&Rc<MainWindow>) + 'static) {
        if self.main_stack.visible_child_name().as_deref() != Some("loading") {
            f(self);
        } else {
            self.on_loaded.borrow_mut().push(Box::new(f));
        }
    }

    fn run_loaded_callbacks(self: &Rc<Self>) {
        let callbacks: Vec<Callback> = self.on_loaded.borrow_mut().drain(..).collect();
        for f in callbacks {
            f(self);
        }
    }

    /// Runs blocking client work off the main thread, then `done` on it.
    pub fn spawn<T: Send + 'static>(
        self: &Rc<Self>,
        work: impl FnOnce(Client) -> T + Send + 'static,
        done: impl FnOnce(&Rc<Self>, T) + 'static,
    ) {
        let client = self.client.clone();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let result = gio::spawn_blocking(move || work(client)).await;
            if let (Some(win), Ok(value)) = (weak.upgrade(), result) {
                done(&win, value);
            }
        });
    }

    fn set_busy(&self, delta: i32) {
        let n = (self.in_flight.get() as i32 + delta).max(0) as u32;
        self.in_flight.set(n);
        self.refresh_stack
            .set_visible_child_name(if n > 0 { "spinner" } else { "button" });
    }

    fn refresh(self: &Rc<Self>, mode: Refresh) {
        if mode == Refresh::Auto && self.in_flight.get() > 0 {
            return;
        }
        self.fetch(mode == Refresh::User);
    }

    /// Unlike timed refreshes, range and setting changes never wait for
    /// in-flight work: the newest request wins.
    fn force_refresh(self: &Rc<Self>) {
        self.fetch(false);
    }

    fn fetch(self: &Rc<Self>, rescan: bool) {
        let generation = self.generation.get() + 1;
        self.generation.set(generation);
        let range = self.state.borrow().range();
        let granularity = self.state.borrow().granularity(range);
        self.last_refresh.set(Some(Instant::now()));
        self.set_busy(1);
        self.spawn(
            move |client| {
                if rescan {
                    // A failed rescan still leaves the last report readable.
                    if let Err(e) = client.refresh(true) {
                        if e.is_unavailable() {
                            return Err(e);
                        }
                    }
                }
                client.dashboard(range, granularity, Local::now())
            },
            move |win, result| {
                win.set_busy(-1);
                if generation != win.generation.get() {
                    return; // A newer request (another range) is on its way.
                }
                match result {
                    Ok(d) => win.apply(d),
                    Err(e) => win.show_error(e),
                }
            },
        );
    }

    fn apply(self: &Rc<Self>, d: Dashboard) {
        self.main_stack.set_visible_child_name("content");
        let messages: Vec<String> = [d.status.last_error.clone(), d.status.pricing_error.clone()]
            .into_iter()
            .flatten()
            .collect();
        if messages.is_empty() {
            self.banner.set_revealed(false);
        } else {
            self.banner.set_title(&markup_escape(&messages.join(" · ")));
            self.banner.set_button_label(Some("Refresh"));
            self.banner.set_revealed(true);
        }
        let clock24 = self.clock24.get();
        self.dashboard.update(&d, clock24);
        self.accounts.update(&d);
        if let Some(remote) = &d.remote {
            self.remote.update(remote);
        }
        self.check_alerts(&d);
        *self.data.borrow_mut() = Some(d);
        self.run_loaded_callbacks();
    }

    fn show_error(self: &Rc<Self>, error: ClientError) {
        if error.is_unavailable() {
            *self.data.borrow_mut() = None;
            self.status_page.set_title("Start the PlanMeter Service");
            self.status_page.set_description(Some(
                "PlanMeter reads usage through <b>planmeterd</b>, a background service that scans your coding-agent transcripts. \
                 Start it now, or keep it running at login with\n<tt>systemctl --user enable --now planmeterd</tt>",
            ));
            self.start_button.set_visible(true);
            self.status_detail.set_label(&error.to_string());
            self.main_stack.set_visible_child_name("status");
            self.run_loaded_callbacks();
            return;
        }
        if self.data.borrow().is_some() {
            self.banner
                .set_title(&markup_escape(&format!("Couldn’t refresh: {error}")));
            self.banner.set_button_label(Some("Try Again"));
            self.banner.set_revealed(true);
        } else {
            self.status_page.set_title("Couldn’t Load Usage");
            self.status_page
                .set_description(Some("planmeterd is running but did not return a report."));
            self.start_button.set_visible(false);
            self.status_detail.set_label(&error.to_string());
            self.main_stack.set_visible_child_name("status");
        }
        self.run_loaded_callbacks();
    }

    fn set_range(self: &Rc<Self>, range: TimeRange) {
        {
            let mut st = self.state.borrow_mut();
            if st.range() == range && self.data.borrow().is_some() {
                return;
            }
            st.range = range.id().into();
        }
        self.save_state();
        self.range_button.set_label(range.short_label());
        self.update_granularity_menu();
        self.force_refresh();
    }

    fn set_granularity(self: &Rc<Self>, granularity: Resolution) {
        let range = self.state.borrow().range();
        {
            let mut st = self.state.borrow_mut();
            st.granularities
                .insert(range.id().into(), granularity.as_str().into());
        }
        self.save_state();
        self.update_granularity_menu();
        self.force_refresh();
    }

    fn update_granularity_menu(&self) {
        let (range, current) = {
            let st = self.state.borrow();
            (st.range(), st.granularity(st.range()))
        };
        let menu = gio::Menu::new();
        for g in range.granularities() {
            menu.append(
                Some(g.label()),
                Some(&format!("win.granularity::{}", g.as_str())),
            );
        }
        let button = &self.dashboard.granularity_button;
        button.set_menu_model(Some(&menu));
        button.set_label(current.label());
        button.set_sensitive(range.granularities().len() > 1);
        if let Some(action) = self
            .window
            .lookup_action("granularity")
            .and_downcast::<gio::SimpleAction>()
        {
            action.set_state(&current.as_str().to_variant());
        }
    }

    // MARK: Spend alerts

    pub fn notifications_enabled(&self) -> bool {
        self.state.borrow().notifications
    }

    pub fn set_notifications_enabled(&self, on: bool) {
        self.state.borrow_mut().notifications = on;
        self.save_state();
    }

    fn save_state(&self) {
        if self.persist.get() {
            self.state.borrow().save();
        }
    }

    /// Screenshots run with saved preferences read-only.
    pub fn disable_persistence(&self) {
        self.persist.set(false);
    }

    fn check_alerts(&self, d: &Dashboard) {
        let Some(threshold) = d.threshold() else {
            let mut st = self.state.borrow_mut();
            st.alerts.clear(d.range);
            return;
        };
        let spend = d.spend_total();
        let period = notify::period_key(d.range, d.summary.from, Local::now());
        let announce = {
            let mut st = self.state.borrow_mut();
            let before = st.alerts.clone();
            let announce = st.alerts.observe(d.range, &period, &threshold, spend);
            if st.alerts != before {
                self.persist_alerts.set(true);
            }
            announce
        };
        if self.persist_alerts.replace(false) {
            self.save_state();
        }
        let Some(status) = announce else { return };
        if !self.notifications_enabled() {
            return;
        }
        let groups = format::group_list(&d.settings.effective_spend_groups());
        if let Some((title, body)) = notify::message(status, d.range, &groups, spend, &threshold) {
            let notification = gio::Notification::new(&title);
            notification.set_body(Some(&body));
            notification.set_priority(if status == planmeter::models::SpendStatus::Reached {
                gio::NotificationPriority::High
            } else {
                gio::NotificationPriority::Normal
            });
            notification.set_icon(&gio::ThemedIcon::new(APP_ID));
            self.app
                .send_notification(Some(&format!("spend-{}", d.range.id())), &notification);
        }
    }

    // MARK: Host settings

    fn settings_saved(self: &Rc<Self>, settings: planmeter::models::HostSettings, regroup: bool) {
        if let Some(d) = self.data.borrow_mut().as_mut() {
            d.settings = settings;
        }
        if let Some(d) = self.data() {
            self.dashboard.update(&d, self.clock24.get());
            self.accounts.update(&d);
            self.check_alerts(&d);
        }
        if regroup {
            // Group changes move accounts between cards and totals.
            self.force_refresh();
        }
    }

    /// Saves spend settings. Errors show in the dialog while it is open, or
    /// in the window after a debounced save outlives it.
    pub fn save_spend(
        self: &Rc<Self>,
        groups: Option<Vec<String>>,
        thresholds: Option<BTreeMap<String, SpendThreshold>>,
        dialog: glib::WeakRef<adw::PreferencesDialog>,
    ) {
        self.spawn(
            move |client| client.set_spend(groups, thresholds),
            move |win, result| match result {
                Ok(settings) => win.settings_saved(settings, false),
                Err(e) => win.save_failed(&e, &dialog),
            },
        );
    }

    pub fn save_group(
        self: &Rc<Self>,
        account: String,
        group: Option<PlanGroup>,
        dialog: glib::WeakRef<adw::PreferencesDialog>,
    ) {
        self.spawn(
            move |client| client.set_group(&account, group),
            move |win, result| match result {
                Ok(settings) => win.settings_saved(settings, true),
                Err(e) => win.save_failed(&e, &dialog),
            },
        );
    }

    fn save_failed(&self, error: &ClientError, dialog: &glib::WeakRef<adw::PreferencesDialog>) {
        let text = format!("Couldn’t save: {error}");
        match dialog.upgrade() {
            Some(d) => d.add_toast(adw::Toast::new(&text)),
            None => self.toast(&text),
        }
    }

    // MARK: Remote access

    fn remote_updated(self: &Rc<Self>, status: RemoteStatus) {
        self.remote.update(&status);
        if let Some(d) = self.data.borrow_mut().as_mut() {
            d.remote = Some(status);
        }
    }

    fn reload_remote(self: &Rc<Self>) {
        self.spawn(
            |client| client.remote(),
            |win, result| {
                if let Ok(status) = result {
                    let before = win
                        .data()
                        .and_then(|d| d.remote)
                        .map(|r| r.devices.len())
                        .unwrap_or(0);
                    let paired = status.devices.len() > before;
                    let name = status.devices.last().map(|d| d.name.clone());
                    win.remote_updated(status);
                    if paired {
                        win.toast(&format!(
                            "Paired {}",
                            name.unwrap_or_else(|| "a new device".into())
                        ));
                    }
                }
            },
        );
    }

    fn remote_call(
        self: &Rc<Self>,
        work: impl FnOnce(&Client) -> Result<RemoteStatus, ClientError> + Send + 'static,
    ) {
        self.spawn(
            move |client| work(&client),
            |win, result| match result {
                Ok(status) => win.remote_updated(status),
                Err(e) => {
                    win.toast(&e.to_string());
                    // Put switches back to what the daemon says.
                    win.reload_remote();
                }
            },
        );
    }

    pub fn create_invite(self: &Rc<Self>) {
        self.remote_call(|c| c.create_invite());
    }

    fn remote_action(self: &Rc<Self>, action: RemoteAction) {
        match action {
            RemoteAction::SetEnabled(on) => self.remote_call(move |c| {
                c.set_remote(&RemoteSettingsBody {
                    enabled: Some(on),
                    ..Default::default()
                })
            }),
            RemoteAction::SetHttps(on) => self.remote_call(move |c| {
                c.set_remote(&RemoteSettingsBody {
                    https_enabled: Some(on),
                    ..Default::default()
                })
            }),
            RemoteAction::SetPort(port) => self.remote_call(move |c| {
                c.set_remote(&RemoteSettingsBody {
                    port: Some(port),
                    ..Default::default()
                })
            }),
            RemoteAction::Pair => self.create_invite(),
            RemoteAction::CancelInvite => self.remote_call(|c| c.cancel_invite()),
            RemoteAction::OpenUrl(url) => {
                gtk::UriLauncher::new(&url).launch(
                    Some(&self.window),
                    gio::Cancellable::NONE,
                    |_| {},
                );
            }
            RemoteAction::Revoke(device) => {
                let dialog = adw::AlertDialog::new(
                    Some(&format!("Revoke “{}”?", device.name)),
                    Some("This device can no longer read usage from this computer. Pair it again to restore access."),
                );
                dialog.add_responses(&[("cancel", "_Cancel"), ("revoke", "_Revoke")]);
                dialog.set_response_appearance("revoke", adw::ResponseAppearance::Destructive);
                dialog.set_default_response(Some("cancel"));
                dialog.set_close_response("cancel");
                let weak = Rc::downgrade(self);
                dialog.choose(
                    Some(&self.window),
                    gio::Cancellable::NONE,
                    move |response| {
                        if response != "revoke" {
                            return;
                        }
                        if let Some(win) = weak.upgrade() {
                            let id = device.id.clone();
                            let name = device.name.clone();
                            win.spawn(
                                move |client| client.revoke_device(&id),
                                move |win, result| match result {
                                    Ok(status) => {
                                        win.remote_updated(status);
                                        win.toast(&format!("Revoked {name}"));
                                    }
                                    Err(e) => win.toast(&e.to_string()),
                                },
                            );
                        }
                    },
                );
            }
        }
    }

    // MARK: Starting the daemon

    fn start_daemon(self: &Rc<Self>) {
        self.start_button.set_sensitive(false);
        self.start_button.set_label("Starting…");
        self.spawn(
            |client| {
                let how = start_daemon_process()?;
                // Wait for the socket to answer.
                for _ in 0..40 {
                    match client.status() {
                        Ok(_) => return Ok(how),
                        Err(e) if e.is_unavailable() => {
                            std::thread::sleep(Duration::from_millis(250))
                        }
                        Err(e) => return Err(e.to_string()),
                    }
                }
                Err(format!(
                    "Started planmeterd ({how}), but it is not answering at {}.",
                    client.socket().display()
                ))
            },
            |win, result: Result<&'static str, String>| {
                win.start_button.set_sensitive(true);
                win.start_button.set_label("Start Service");
                match result {
                    Ok(_) => win.refresh(Refresh::Auto),
                    Err(e) => {
                        win.status_detail.set_label(&e);
                        win.toast("Couldn’t start planmeterd");
                    }
                }
            },
        );
    }
}

/// `systemctl --user start planmeterd`, falling back to `planmeterd` from
/// PATH. Inside Flatpak both run on the host through `flatpak-spawn`.
fn start_daemon_process() -> Result<&'static str, String> {
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    let sandboxed = std::path::Path::new("/.flatpak-info").exists();
    let command = |args: &[&str]| {
        let mut c = if sandboxed {
            let mut c = Command::new("flatpak-spawn");
            c.arg("--host").args(args);
            c
        } else {
            let mut c = Command::new(args[0]);
            c.args(&args[1..]);
            c
        };
        c.stdin(Stdio::null());
        c
    };
    let systemd = match command(&["systemctl", "--user", "start", "planmeterd"])
        .stdout(Stdio::null())
        .output()
    {
        Ok(out) if out.status.success() => return Ok("systemd"),
        Ok(out) => String::from_utf8_lossy(&out.stderr).trim().to_string(),
        Err(e) => e.to_string(),
    };
    let mut daemon = command(&["planmeterd"]);
    daemon
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0);
    match daemon.spawn() {
        Ok(mut child) => {
            // Reap it if it exits early, so it never lingers as a zombie.
            std::thread::spawn(move || {
                let _ = child.wait();
            });
            Ok("spawned")
        }
        Err(e) => Err(format!(
            "systemctl --user start planmeterd: {systemd}\nplanmeterd: {e}"
        )),
    }
}
