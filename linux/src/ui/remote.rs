//! Remote access over Tailscale: the listener, Tailscale Serve HTTPS, pairing
//! QR codes, and paired devices.

use super::qr::qr_widget;
use super::widgets::*;
use adw::prelude::*;
use chrono::Utc;
use gtk::glib;
use planmeter::format;
use planmeter::models::{PairedDevice, RemoteInvite, RemoteStatus};
use std::cell::{Cell, RefCell};
use std::rc::Rc;

pub enum RemoteAction {
    SetEnabled(bool),
    SetHttps(bool),
    SetPort(i64),
    Pair,
    CancelInvite,
    Revoke(PairedDevice),
    OpenUrl(String),
}

type Handler = Rc<dyn Fn(RemoteAction)>;

pub struct RemotePage {
    pub root: gtk::ScrolledWindow,
    handler: Handler,
    toasts: adw::ToastOverlay,
    enabled_row: adw::SwitchRow,
    status_dot: gtk::Box,
    address_row: adw::ActionRow,
    address_copy: gtk::Button,
    dns_row: adw::ActionRow,
    dns_copy: gtk::Button,
    port_row: adw::SpinRow,
    tailscale_row: adw::ActionRow,
    https_row: adw::SwitchRow,
    url_row: adw::ActionRow,
    pair_group: adw::PreferencesGroup,
    pair_box: gtk::Box,
    countdown: RefCell<Option<(gtk::Label, chrono::DateTime<Utc>)>>,
    devices: gtk::ListBox,
    log: gtk::Label,
    updating: Cell<bool>,
    port_debounce: RefCell<Option<glib::SourceId>>,
    last: RefCell<Option<RemoteStatus>>,
}

fn device_icon(platform: &str) -> &'static str {
    let p = platform.to_lowercase();
    if p == "web" || p.contains("browser") || p.contains("safari") || p.contains("chrome") {
        "web-browser-symbolic"
    } else if p.contains("ipad") || p.contains("tablet") {
        "tablet-symbolic"
    } else if p.contains("iphone")
        || p.contains("android")
        || p.contains("phone")
        || p.contains("ios")
    {
        "phone-symbolic"
    } else {
        "computer-symbolic"
    }
}

impl RemotePage {
    pub fn new(toasts: &adw::ToastOverlay, handler: impl Fn(RemoteAction) + 'static) -> Rc<Self> {
        let handler: Handler = Rc::new(handler);
        let page = adw::PreferencesPage::new();

        let access = adw::PreferencesGroup::builder()
            .title("Remote Access")
            .description("Serve the PlanMeter iPhone, Android, and web apps over your tailnet only. Every request is end-to-end encrypted to this computer’s key and signed by the device’s key, on top of Tailscale’s WireGuard tunnel.")
            .build();
        let enabled_row = adw::SwitchRow::builder()
            .title("Remote Access")
            .subtitle("Off")
            .build();
        let status_dot = status_dot("");
        enabled_row.add_prefix(&status_dot);
        access.add(&enabled_row);
        let tailscale_row = row(
            "Tailscale isn’t connected",
            "Install Tailscale and run “tailscale up”. Remote access only listens on the tailnet.",
        );
        tailscale_row.add_prefix(&gtk::Image::from_icon_name("dialog-warning-symbolic"));
        access.add(&tailscale_row);
        page.add(&access);

        let pair_group = adw::PreferencesGroup::builder()
            .title("Pair a Device")
            .build();
        let pair_box = vbox(0);
        pair_group.add(&pair_box);
        page.add(&pair_group);

        let devices_group = adw::PreferencesGroup::builder()
            .title("Paired Devices")
            .build();
        let devices = boxed_list();
        devices_group.add(&devices);
        page.add(&devices_group);

        let connection = adw::PreferencesGroup::builder().title("Connection").build();
        let address_row = row("Tailnet Address", "");
        address_row.set_subtitle_selectable(true);
        let address_copy = icon_button("edit-copy-symbolic", "Copy Address");
        address_row.add_suffix(&address_copy);
        connection.add(&address_row);
        let dns_row = row("MagicDNS Name", "");
        dns_row.set_subtitle_selectable(true);
        let dns_copy = icon_button("edit-copy-symbolic", "Copy Name");
        dns_row.add_suffix(&dns_copy);
        connection.add(&dns_row);
        let port_row = adw::SpinRow::builder()
            .title("Port")
            .subtitle("Where the tailnet listener accepts connections")
            .adjustment(&gtk::Adjustment::new(
                7787.0, 1025.0, 65535.0, 1.0, 10.0, 0.0,
            ))
            .numeric(true)
            .build();
        connection.add(&port_row);
        let https_row = adw::SwitchRow::builder()
            .title("HTTPS with Tailscale Serve")
            .build();
        connection.add(&https_row);
        let url_row = row("Web App Address", "");
        url_row.set_subtitle_selectable(true);
        let open = icon_button("send-to-symbolic", "Open in Browser");
        url_row.add_suffix(&open);
        let url_copy = icon_button("edit-copy-symbolic", "Copy Address");
        url_row.add_suffix(&url_copy);
        connection.add(&url_row);
        page.add(&connection);

        let activity = adw::PreferencesGroup::new();
        let expander = adw::ExpanderRow::builder()
            .title("Activity")
            .subtitle("Recent remote access events")
            .build();
        let log = label_with("", &["log-text", "dim-label"]);
        log.set_selectable(true);
        log.set_wrap(true);
        log.set_wrap_mode(gtk::pango::WrapMode::WordChar);
        log.set_margin_top(10);
        log.set_margin_bottom(10);
        log.set_margin_start(12);
        log.set_margin_end(12);
        expander.add_row(
            &gtk::ListBoxRow::builder()
                .child(&log)
                .activatable(false)
                .build(),
        );
        let list = boxed_list();
        list.append(&expander);
        activity.add(&list);
        page.add(&activity);

        let root = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&page)
            .build();
        let this = Rc::new(RemotePage {
            root,
            handler,
            toasts: toasts.clone(),
            enabled_row,
            status_dot,
            address_row,
            address_copy,
            dns_row,
            dns_copy,
            port_row,
            tailscale_row,
            https_row,
            url_row,
            pair_group,
            pair_box,
            countdown: RefCell::new(None),
            devices,
            log,
            updating: Cell::new(false),
            port_debounce: RefCell::new(None),
            last: RefCell::new(None),
        });

        let weak = Rc::downgrade(&this);
        this.enabled_row.connect_active_notify(move |row| {
            if let Some(p) = weak.upgrade().filter(|p| !p.updating.get()) {
                (p.handler)(RemoteAction::SetEnabled(row.is_active()));
            }
        });
        let weak = Rc::downgrade(&this);
        this.https_row.connect_active_notify(move |row| {
            if let Some(p) = weak.upgrade().filter(|p| !p.updating.get()) {
                (p.handler)(RemoteAction::SetHttps(row.is_active()));
            }
        });
        let weak = Rc::downgrade(&this);
        this.port_row.connect_value_notify(move |row| {
            let Some(p) = weak.upgrade().filter(|p| !p.updating.get()) else {
                return;
            };
            if let Some(id) = p.port_debounce.borrow_mut().take() {
                id.remove();
            }
            let port = row.value() as i64;
            let weak = Rc::downgrade(&p);
            let id =
                glib::timeout_add_local_once(std::time::Duration::from_millis(900), move || {
                    if let Some(p) = weak.upgrade() {
                        p.port_debounce.borrow_mut().take();
                        if p.last.borrow().as_ref().is_some_and(|r| r.port != port) {
                            (p.handler)(RemoteAction::SetPort(port));
                        }
                    }
                });
            *p.port_debounce.borrow_mut() = Some(id);
        });
        let weak = Rc::downgrade(&this);
        open.connect_clicked(move |_| {
            if let Some(p) = weak.upgrade() {
                let url = p.last.borrow().as_ref().and_then(|r| r.https.url.clone());
                if let Some(url) = url {
                    (p.handler)(RemoteAction::OpenUrl(url));
                }
            }
        });
        for (button, which, what) in [
            (&this.address_copy, 0, "address"),
            (&this.dns_copy, 1, "name"),
            (&url_copy, 2, "address"),
        ] {
            let weak = Rc::downgrade(&this);
            button.connect_clicked(move |b| {
                let Some(p) = weak.upgrade() else { return };
                let text = {
                    let last = p.last.borrow();
                    let Some(r) = last.as_ref() else { return };
                    match which {
                        0 => r.tailscale.address.clone(),
                        1 => r.tailscale.dns_name.clone(),
                        _ => r.https.url.clone(),
                    }
                };
                if let Some(text) = text {
                    b.clipboard().set_text(&text);
                    let name = if what == "name" {
                        "MagicDNS name"
                    } else {
                        "Address"
                    };
                    p.toasts
                        .add_toast(adw::Toast::new(&format!("{name} copied")));
                }
            });
        }
        this
    }

    pub fn update(self: &Rc<Self>, r: &RemoteStatus) {
        let previous = self.last.borrow().clone();
        *self.last.borrow_mut() = Some(r.clone());
        self.updating.set(true);

        self.enabled_row.set_active(r.enabled);
        self.enabled_row.set_subtitle(&r.status);
        set_class(
            &self.status_dot,
            &["ok", "warning"],
            if r.is_listening() {
                "ok"
            } else if r.enabled {
                "warning"
            } else {
                ""
            },
        );
        self.tailscale_row.set_visible(!r.tailscale.available);
        let address = r
            .tailscale
            .address
            .clone()
            .or_else(|| r.bind_addresses.first().cloned());
        self.address_row.set_visible(address.is_some());
        self.address_row.set_subtitle(
            &address
                .map(|a| format!("{a}:{}", r.port))
                .unwrap_or_default(),
        );
        self.dns_row.set_visible(r.tailscale.dns_name.is_some());
        self.dns_row
            .set_subtitle(r.tailscale.dns_name.as_deref().unwrap_or(""));
        if self.port_debounce.borrow().is_none() {
            self.port_row.set_value(r.port as f64);
        }

        self.https_row.set_active(r.https.enabled);
        self.https_row
            .set_sensitive(r.is_listening() || r.https.enabled);
        let domain = r
            .tailscale
            .dns_name
            .clone()
            .unwrap_or_else(|| "<machine>.<tailnet>.ts.net".into());
        let https_subtitle = if r.https.active {
            "Serving the web app on your tailnet".to_string()
        } else if r.https.enabled {
            r.https
                .certificate_status
                .clone()
                .unwrap_or_else(|| "Waiting for Tailscale Serve…".into())
        } else {
            format!("Serve the web app at https://{domain}/ on your tailnet. Browsers need HTTPS for its encryption.")
        };
        self.https_row.set_subtitle(&https_subtitle);
        self.url_row
            .set_visible(r.https.active && r.https.url.is_some());
        self.url_row
            .set_subtitle(r.https.url.as_deref().unwrap_or(""));
        self.updating.set(false);

        let invite_changed = previous
            .as_ref()
            .map(|p| (&p.invite, p.is_listening(), p.https.active))
            != Some((&r.invite, r.is_listening(), r.https.active));
        if invite_changed {
            self.update_pairing(r);
        }
        if previous.as_ref().map(|p| &p.devices) != Some(&r.devices) {
            self.update_devices(r);
        } else {
            self.refresh_device_times(r);
        }
        let log = if r.log.is_empty() {
            "No events yet.".to_string()
        } else {
            r.log.join("\n")
        };
        set_text(&self.log, &log);
        self.tick();
    }

    pub fn has_active_invite(&self) -> bool {
        self.countdown
            .borrow()
            .as_ref()
            .is_some_and(|(_, at)| *at > Utc::now())
    }

    /// Updates the pairing countdown; returns true once the code expired.
    pub fn tick(&self) -> bool {
        let countdown = self.countdown.borrow().clone();
        let Some((label, expires)) = countdown else {
            return false;
        };
        let left = (expires - Utc::now()).num_seconds();
        if left <= 0 {
            // Back to "Pair a Device" without waiting for the daemon.
            let last = self.last.borrow().clone();
            if let Some(r) = last {
                self.update_pairing(&r);
            }
            return true;
        }
        set_text(
            &label,
            &format!("Expires in {} · Single use", format::countdown(left)),
        );
        false
    }

    fn update_pairing(&self, r: &RemoteStatus) {
        clear(&self.pair_box);
        *self.countdown.borrow_mut() = None;
        match r.invite.as_ref().filter(|i| i.expires_at > Utc::now()) {
            Some(invite) => {
                self.pair_group.set_description(Some(
                    "Scan a code with PlanMeter on iPhone or Android, or with the phone’s camera for the web app. Each code works once.",
                ));
                self.pair_box.append(&self.invite_card(invite));
            }
            None => {
                self.pair_group.set_description(None);
                self.pair_box.append(&self.intro_card(r));
            }
        }
    }

    fn intro_card(&self, r: &RemoteStatus) -> gtk::Box {
        let card = card(10);
        card.set_halign(gtk::Align::Fill);
        let inner = vbox(10);
        inner.set_halign(gtk::Align::Center);
        inner.set_margin_top(10);
        inner.set_margin_bottom(10);
        let icon = gtk::Image::from_icon_name("planmeter-remote-symbolic");
        icon.set_pixel_size(48);
        icon.add_css_class("dim-label");
        inner.append(&icon);
        let title = label_with("See usage from your phone", &["title-4"]);
        title.set_xalign(0.5);
        inner.append(&title);
        let text = caption(if r.is_listening() {
            "Show a single-use code for the PlanMeter app or the web app. It expires after five minutes."
        } else {
            "Turn on remote access to show a pairing code."
        });
        text.set_xalign(0.5);
        text.set_justify(gtk::Justification::Center);
        text.set_max_width_chars(52);
        inner.append(&text);
        let button = gtk::Button::builder()
            .label("Pair a Device")
            .halign(gtk::Align::Center)
            .sensitive(r.is_listening())
            .build();
        button.add_css_class("pill");
        button.add_css_class("suggested-action");
        button.set_margin_top(6);
        let handler = self.handler.clone();
        button.connect_clicked(move |_| handler(RemoteAction::Pair));
        inner.append(&button);
        card.append(&inner);
        card
    }

    fn invite_card(&self, invite: &RemoteInvite) -> gtk::Box {
        let card = card(16);
        let codes = flow(2, 24);
        codes.set_homogeneous(false);

        let app = vbox(10);
        app.set_halign(gtk::Align::Center);
        app.set_valign(gtk::Align::Start);
        let title = label_with("PlanMeter App", &["heading"]);
        title.set_xalign(0.5);
        app.append(&title);
        app.append(&qr_widget(
            &invite.url,
            196,
            "Pairing code for the PlanMeter app",
        ));
        let hint = caption("Scan with PlanMeter on iPhone or Android");
        hint.set_xalign(0.5);
        app.append(&hint);
        flow_append(&codes, &app);

        if invite.web_url.is_some() || invite.web_code.is_some() {
            let web = vbox(10);
            web.set_halign(gtk::Align::Center);
            web.set_valign(gtk::Align::Start);
            let title = label_with("Web App", &["heading"]);
            title.set_xalign(0.5);
            web.append(&title);
            match invite.web_url.as_deref() {
                Some(url) => {
                    web.append(&qr_widget(url, 196, "Pairing code for the web app"));
                    let hint = caption("Scan with the phone’s camera to open the web app");
                    hint.set_xalign(0.5);
                    web.append(&hint);
                }
                None => {
                    let hint = caption("Turn on HTTPS with Tailscale Serve to pair a browser: browsers only allow the encryption this needs on HTTPS pages.");
                    hint.set_xalign(0.5);
                    hint.set_justify(gtk::Justification::Center);
                    hint.set_max_width_chars(30);
                    web.append(&hint);
                }
            }
            if let Some(code) = invite.web_code.as_deref() {
                let already = caption("Web app already open? Enter this code:");
                already.set_xalign(0.5);
                web.append(&already);
                let code_label = label_with(&format::web_code(code), &["web-code"]);
                code_label.set_xalign(0.5);
                code_label.set_selectable(true);
                code_label.update_property(&[gtk::accessible::Property::Label(&format!(
                    "Web pairing code {}",
                    code.chars().map(String::from).collect::<Vec<_>>().join(" ")
                ))]);
                web.append(&code_label);
            }
            flow_append(&codes, &web);
        }
        card.append(&codes);

        let countdown = label_with("", &["dim-label", "numeric"]);
        countdown.set_xalign(0.5);
        card.append(&countdown);
        *self.countdown.borrow_mut() = Some((countdown, invite.expires_at));

        let buttons = hbox(12);
        buttons.set_halign(gtk::Align::Center);
        let copy = gtk::Button::builder().label("Copy App Link").build();
        copy.add_css_class("pill");
        let url = invite.url.clone();
        let toasts = self.toasts.downgrade();
        copy.connect_clicked(move |b| {
            b.clipboard().set_text(&url);
            if let Some(t) = toasts.upgrade() {
                t.add_toast(adw::Toast::new(
                    "Pairing link copied. It is a secret: share it only with your own device.",
                ));
            }
        });
        buttons.append(&copy);
        let cancel = gtk::Button::builder().label("Cancel").build();
        cancel.add_css_class("pill");
        let handler = self.handler.clone();
        cancel.connect_clicked(move |_| handler(RemoteAction::CancelInvite));
        buttons.append(&cancel);
        card.append(&buttons);
        card
    }

    fn device_subtitle(device: &PairedDevice) -> String {
        let now = Utc::now();
        let platform = if device.platform.eq_ignore_ascii_case("web") {
            "Web browser".to_string()
        } else {
            device.platform.clone()
        };
        match device.last_seen_at {
            Some(seen) => format!(
                "{platform} · Last seen {} · {} {}",
                format::relative(seen, now),
                format::grouped(device.request_count),
                if device.request_count == 1 {
                    "request"
                } else {
                    "requests"
                }
            ),
            None => format!(
                "{platform} · Paired {} · Not seen yet",
                format::relative(device.paired_at, now)
            ),
        }
    }

    fn update_devices(self: &Rc<Self>, r: &RemoteStatus) {
        self.devices.remove_all();
        if r.devices.is_empty() {
            self.devices.append(&row(
                "No paired devices",
                "Pair a phone to read this computer’s usage when you’re away from it.",
            ));
            return;
        }
        for device in &r.devices {
            let item = row(&device.name, &Self::device_subtitle(device));
            item.set_subtitle_lines(2);
            item.add_prefix(&gtk::Image::from_icon_name(device_icon(&device.platform)));
            item.set_tooltip_text(Some(&format!("Key {}", device.id)));
            let revoke = gtk::Button::builder()
                .label("Revoke…")
                .valign(gtk::Align::Center)
                .build();
            revoke.add_css_class("flat");
            revoke.add_css_class("error");
            revoke.update_property(&[gtk::accessible::Property::Label(&format!(
                "Revoke {}",
                device.name
            ))]);
            revoke.set_action_name(Some("win.revoke-device"));
            revoke.set_action_target_value(Some(&device.id.to_variant()));
            item.add_suffix(&revoke);
            self.devices.append(&item);
        }
    }

    fn refresh_device_times(&self, r: &RemoteStatus) {
        let mut i = 0;
        while let Some(row) = self.devices.row_at_index(i) {
            if let (Some(device), Ok(action)) =
                (r.devices.get(i as usize), row.downcast::<adw::ActionRow>())
            {
                let text = Self::device_subtitle(device);
                if action.subtitle().map(|s| s.to_string()) != Some(text.clone()) {
                    action.set_subtitle(&text);
                }
            }
            i += 1;
        }
    }
}
