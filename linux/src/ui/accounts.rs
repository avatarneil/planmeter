//! Accounts, scanned sources, and the daemon's own status.

use super::widgets::*;
use adw::prelude::*;
use chrono::Utc;
use planmeter::client::Dashboard;
use planmeter::format;
use planmeter::models::PlanGroup;
use std::cell::RefCell;
use std::path::PathBuf;

pub struct AccountsPage {
    pub root: gtk::ScrolledWindow,
    accounts: gtk::ListBox,
    sources: gtk::ListBox,
    daemon: gtk::ListBox,
    socket: PathBuf,
    last: RefCell<Option<Dashboard>>,
}

fn provider_name(raw: &str) -> &str {
    match raw {
        "codex" => "Codex",
        "claude" => "Claude Code",
        "grok" => "Grok Build",
        "opencode" => "OpenCode",
        "antigravity" => "Antigravity",
        other => other,
    }
}

impl AccountsPage {
    pub fn new(socket: PathBuf) -> Self {
        let page = adw::PreferencesPage::new();

        let accounts_group = adw::PreferencesGroup::builder()
            .title("Accounts")
            .description("planmeterd reads the login stored in each provider home. If T3 Code is installed, its provider instances add homes, names, and colors.")
            .build();
        let change = gtk::Button::builder()
            .label("Change Groups…")
            .action_name("win.plan-groups")
            .valign(gtk::Align::Center)
            .build();
        change.add_css_class("flat");
        accounts_group.set_header_suffix(Some(&change));
        let accounts = boxed_list();
        accounts_group.add(&accounts);
        page.add(&accounts_group);

        let sources_group = adw::PreferencesGroup::builder()
            .title("Scanned Sources")
            .description("Transcript folders and databases planmeterd reads. Prompts and transcripts never leave this computer.")
            .build();
        let sources = boxed_list();
        sources_group.add(&sources);
        page.add(&sources_group);

        let daemon_group = adw::PreferencesGroup::builder().title("Daemon").build();
        let daemon = boxed_list();
        daemon_group.add(&daemon);
        page.add(&daemon_group);

        let root = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&page)
            .build();
        AccountsPage {
            root,
            accounts,
            sources,
            daemon,
            socket,
            last: RefCell::new(None),
        }
    }

    pub fn update(&self, d: &Dashboard) {
        let unchanged = self
            .last
            .borrow()
            .as_ref()
            .is_some_and(|p| p.accounts == d.accounts && p.settings == d.settings);
        if !unchanged {
            self.update_accounts(d);
            self.update_sources(d);
        }
        *self.last.borrow_mut() = Some(d.clone());
        self.update_daemon(d);
    }

    fn update_accounts(&self, d: &Dashboard) {
        self.accounts.remove_all();
        let all = d.all_accounts();
        if all.is_empty() {
            self.accounts.append(&row(
                "No accounts discovered",
                "Run Codex, Claude Code, or OpenCode once, then refresh.",
            ));
        }
        for a in &all {
            let mut parts = vec![if a.provider_name.is_empty() {
                provider_name(&a.provider).to_string()
            } else {
                a.provider_name.clone()
            }];
            if let Some(email) = a.email.as_deref().filter(|e| !e.is_empty()) {
                parts.push(email.to_string());
            }
            let r = row(&a.name, &parts.join(" · "));
            r.add_prefix(&dot(&format::account_color(&all, &a.id), 10));
            if let Some(plan) = a.plan.as_deref().filter(|p| !p.is_empty()) {
                r.add_suffix(&tag(plan, &[]));
            }
            let group = PlanGroup::parse(&a.group);
            let group_tag = tag(group.display_name(), &[&format!("group-{}", group.id())]);
            if d.settings.group_overrides.contains_key(&a.id) {
                group_tag.set_tooltip_text(Some("Assigned in Preferences"));
            } else {
                group_tag.set_tooltip_text(Some(
                    "Suggested from the account name, email domain, or plan",
                ));
            }
            r.add_suffix(&group_tag);
            self.accounts.append(&r);
        }
    }

    fn update_sources(&self, d: &Dashboard) {
        self.sources.remove_all();
        if d.accounts.sources.is_empty() {
            self.sources.append(&row("No sources found", ""));
        }
        for s in &d.accounts.sources {
            let r = row(provider_name(&s.provider), &s.path);
            r.set_subtitle_lines(1);
            r.set_subtitle_selectable(true);
            let (dot_class, text) = match s.status.as_str() {
                "ok" => ("ok", "Scanned"),
                "partial" => ("warning", "Partial"),
                "failed" => ("error", "Failed"),
                "missing" => ("", "Not found"),
                other => ("", other),
            };
            r.add_prefix(&status_dot(dot_class));
            r.add_suffix(&label_with(text, &["dim-label", "caption"]));
            self.sources.append(&r);
        }
    }

    fn update_daemon(&self, d: &Dashboard) {
        self.daemon.remove_all();
        let now = Utc::now();
        let s = &d.status;
        self.daemon.append(&row(
            "Server",
            if s.server_name.is_empty() {
                "–"
            } else {
                &s.server_name
            },
        ));
        let version = if s.version.is_empty() {
            format!("API v{}", s.api_version)
        } else {
            format!("{} · API v{}", s.version, s.api_version)
        };
        self.daemon.append(&row("Version", &version));
        let scan = match (s.is_scanning, s.last_scan_at) {
            (true, _) => "Scanning now…".to_string(),
            (false, Some(at)) => format!(
                "{} ({})",
                format::relative(at, now),
                format::date_time(at, true)
            ),
            (false, None) => "Not yet".into(),
        };
        self.daemon.append(&row("Last scan", &scan));
        let pricing = match (&s.pricing_error, &s.pricing_source) {
            (Some(err), _) => err.clone(),
            (None, Some(src)) => format!("Token prices from {src}"),
            (None, None) => "Token prices unavailable".into(),
        };
        let pricing_row = row("Pricing", &pricing);
        if s.pricing_error.is_some() {
            pricing_row.add_prefix(&gtk::Image::from_icon_name("dialog-warning-symbolic"));
        }
        self.daemon.append(&pricing_row);
        if let Some(err) = &s.last_error {
            let r = row("Last error", err);
            r.add_prefix(&gtk::Image::from_icon_name("dialog-warning-symbolic"));
            self.daemon.append(&r);
        }
        let socket = row("Control socket", &self.socket.display().to_string());
        socket.set_subtitle_selectable(true);
        self.daemon.append(&socket);
    }
}
