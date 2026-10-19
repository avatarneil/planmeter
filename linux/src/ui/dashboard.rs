//! The dashboard: total spend, spend-limit progress, Personal / Work / Other
//! cards, the timeline chart, models, and Codex limits.

use super::chart::ChartView;
use super::widgets::*;
use adw::prelude::*;
use chrono::{DateTime, Utc};
use planmeter::chart::ChartData;
use planmeter::client::Dashboard;
use planmeter::format;
use planmeter::models::*;
use planmeter::range::Resolution;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

const MODELS_PREVIEW: usize = 6;

struct Stat {
    value: gtk::Label,
    root: gtk::Box,
}

fn stat(title: &str, tooltip: &str) -> Stat {
    let root = vbox(2);
    root.set_width_request(118);
    root.append(&label_with(title, &["caption", "dim-label"]));
    let value = label_with("–", &["stat-value", "numeric"]);
    root.append(&value);
    root.set_tooltip_text(Some(tooltip));
    Stat { value, root }
}

pub struct DashboardPage {
    pub root: gtk::ScrolledWindow,
    /// Orientation flips in narrow windows.
    pub hero_row: gtk::Box,
    pub lower_row: gtk::Box,
    pub limits_column: gtk::Box,
    pub content: gtk::Box,
    pub limit_stack: gtk::Stack,
    hero_title: gtk::Label,
    hero_amount: gtk::Label,
    hero_caption: gtk::Label,
    stat_today: Stat,
    stat_tokens: Stat,
    stat_cached: Stat,
    stat_savings: Stat,
    stat_sessions: Stat,
    limit_scope: gtk::Label,
    limit_amount: gtk::Label,
    limit_of: gtk::Label,
    limit_percent: gtk::Label,
    limit_bar: gtk::ProgressBar,
    limit_icon: gtk::Image,
    limit_status: gtk::Label,
    limit_empty_text: gtk::Label,
    groups: gtk::FlowBox,
    chart: ChartView,
    chart_title: gtk::Label,
    pub granularity_button: gtk::MenuButton,
    chart_notes: gtk::Box,
    legend: gtk::Label,
    models_group: adw::PreferencesGroup,
    models_list: gtk::ListBox,
    models_toggle: gtk::Button,
    show_all_models: Cell<bool>,
    limits_group: adw::PreferencesGroup,
    limits_list: gtk::ListBox,
    footer: gtk::Label,
    last: RefCell<Option<Dashboard>>,
    clock24: Cell<bool>,
}

impl DashboardPage {
    pub fn new() -> Rc<Self> {
        let content = vbox(18);
        content.set_margin_top(18);
        content.set_margin_bottom(24);
        content.set_margin_start(18);
        content.set_margin_end(18);

        // Hero: total spend, headline stats, and the spend limit.
        let hero = card(16);
        hero.remove_css_class("dashboard-card");
        hero.add_css_class("hero-card");
        let hero_row = hbox(24);
        let hero_left = vbox(2);
        hero_left.set_hexpand(true);
        let hero_title = label_with("Total spend", &["heading", "dim-label"]);
        let hero_amount = label_with("–", &["hero-amount", "numeric"]);
        hero_amount.set_selectable(true);
        hero_amount.set_can_focus(false);
        let hero_caption = label_with("", &["dim-label"]);
        hero_caption.set_wrap(true);
        hero_left.append(&hero_title);
        hero_left.append(&hero_amount);
        hero_left.append(&hero_caption);

        let stats = flow(5, 12);
        stats.set_homogeneous(false);
        stats.set_margin_top(14);
        let stat_today = stat("Today", "Spend since local midnight, across every account");
        let stat_tokens = stat("Tokens", "Input and output tokens in this range");
        let stat_cached = stat("Cached input", "Share of input tokens served from cache");
        let stat_savings = stat(
            "Cache savings",
            "What caching saved at standard model rates",
        );
        let stat_sessions = stat("Sessions", "Known sessions with usage in this range");
        for s in [
            &stat_today,
            &stat_tokens,
            &stat_cached,
            &stat_savings,
            &stat_sessions,
        ] {
            flow_append(&stats, &s.root);
        }
        hero_left.append(&stats);
        hero_row.append(&hero_left);

        let limit_stack = gtk::Stack::builder()
            .vhomogeneous(false)
            .hhomogeneous(true)
            .valign(gtk::Align::Start)
            .build();
        limit_stack.set_width_request(320);
        // Explicit, or the spacers inside would make it share the extra width.
        limit_stack.set_hexpand(false);
        limit_stack.add_css_class("limit-panel");
        let limit_box = vbox(6);
        let limit_head = hbox(6);
        limit_head.append(&label_with("Spend limit", &["heading"]));
        limit_head.append(&spacer());
        let limit_percent = label_with("", &["heading", "numeric"]);
        limit_head.append(&limit_percent);
        let edit = gtk::Button::builder()
            .icon_name("document-edit-symbolic")
            .tooltip_text("Edit Spend Limit")
            .action_name("win.spend-limit")
            .build();
        edit.add_css_class("flat");
        edit.add_css_class("circular");
        edit.update_property(&[gtk::accessible::Property::Label("Edit spend limit")]);
        limit_head.append(&edit);
        limit_box.append(&limit_head);
        let limit_scope = caption("");
        limit_box.append(&limit_scope);
        let amount_row = hbox(6);
        let limit_amount = label_with("", &["title-2", "numeric"]);
        let limit_of = label_with("", &["dim-label", "numeric"]);
        limit_of.set_valign(gtk::Align::Baseline);
        limit_amount.set_valign(gtk::Align::Baseline);
        amount_row.append(&limit_amount);
        amount_row.append(&limit_of);
        limit_box.append(&amount_row);
        let limit_bar = thin_bar(0.0, "spend-comfortable");
        limit_bar.update_property(&[gtk::accessible::Property::Label("Spend limit used")]);
        limit_box.append(&limit_bar);
        let status_row = hbox(6);
        let limit_icon = gtk::Image::from_icon_name("object-select-symbolic");
        let limit_status = label_with("", &["caption-heading"]);
        status_row.append(&limit_icon);
        status_row.append(&limit_status);
        limit_box.append(&status_row);
        limit_box.append(&caption(
            "Estimated usage cost · A personal target, not a billing cap.",
        ));
        limit_stack.add_named(&limit_box, Some("limit"));

        let empty_box = vbox(8);
        empty_box.append(&label_with("Spend limit", &["heading"]));
        let limit_empty_text = caption("");
        empty_box.append(&limit_empty_text);
        let set_limit = gtk::Button::builder()
            .label("Set Limit…")
            .action_name("win.spend-limit")
            .halign(gtk::Align::Start)
            .build();
        set_limit.add_css_class("suggested-action");
        empty_box.append(&set_limit);
        limit_stack.add_named(&empty_box, Some("none"));
        hero_row.append(&limit_stack);
        hero.append(&hero_row);
        content.append(&hero);

        // Chart.
        let chart_card = card(12);
        let chart_head = hbox(6);
        let chart_title = label_with("Cost over time", &["heading"]);
        chart_head.append(&chart_title);
        chart_head.append(&spacer());
        let granularity_button = gtk::MenuButton::builder()
            .label("1 hour")
            .always_show_arrow(true)
            .tooltip_text("Bucket size")
            .build();
        granularity_button.add_css_class("flat");
        chart_head.append(&granularity_button);
        chart_card.append(&chart_head);
        let chart = ChartView::new();
        chart_card.append(&chart.area);
        let chart_notes = vbox(4);
        chart_card.append(&chart_notes);
        // One wrapping label: flows like text at any width on every GTK
        // version, and reads naturally to screen readers.
        let legend = label_with("", &["caption", "legend"]);
        legend.set_wrap(true);
        legend.set_wrap_mode(gtk::pango::WrapMode::Word);
        legend.set_use_markup(true);
        chart_card.append(&legend);
        content.append(&chart_card);

        // Plan groups.
        let groups = flow(3, 18);
        content.append(&groups);

        // Models and limits.
        let lower_row = hbox(18);
        let models_group = adw::PreferencesGroup::builder()
            .title("Models")
            .hexpand(true)
            .valign(gtk::Align::Start)
            .build();
        let models_toggle = gtk::Button::builder()
            .label("Show All")
            .valign(gtk::Align::Center)
            .build();
        models_toggle.add_css_class("flat");
        models_group.set_header_suffix(Some(&models_toggle));
        let models_list = boxed_list();
        models_group.add(&models_list);
        lower_row.append(&models_group);
        let limits_column = vbox(0);
        limits_column.set_width_request(380);
        // Explicit, so the boxed list inside does not make it grab space.
        limits_column.set_hexpand(false);
        let limits_group = adw::PreferencesGroup::builder()
            .title("Codex Limits")
            .valign(gtk::Align::Start)
            .build();
        let limits_list = boxed_list();
        limits_group.add(&limits_list);
        limits_column.append(&limits_group);
        lower_row.append(&limits_column);
        content.append(&lower_row);

        let footer = caption("");
        footer.set_justify(gtk::Justification::Center);
        footer.set_xalign(0.5);
        footer.set_margin_top(6);
        content.append(&footer);

        let clamp = adw::Clamp::builder()
            .maximum_size(1240)
            .tightening_threshold(960)
            .child(&content)
            .build();
        let root = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&clamp)
            .build();

        let page = Rc::new(DashboardPage {
            root,
            hero_row,
            lower_row,
            limits_column,
            content: content.clone(),
            hero_title,
            hero_amount,
            hero_caption,
            stat_today,
            stat_tokens,
            stat_cached,
            stat_savings,
            stat_sessions,
            limit_stack,
            limit_scope,
            limit_amount,
            limit_of,
            limit_percent,
            limit_bar,
            limit_icon,
            limit_status,
            limit_empty_text,
            groups,
            chart,
            chart_title,
            granularity_button,
            chart_notes,
            legend,
            models_group,
            models_list,
            models_toggle,
            show_all_models: Cell::new(false),
            limits_group,
            limits_list,
            footer,
            last: RefCell::new(None),
            clock24: Cell::new(true),
        });
        let weak = Rc::downgrade(&page);
        page.models_toggle.connect_clicked(move |_| {
            if let Some(p) = weak.upgrade() {
                p.show_all_models.set(!p.show_all_models.get());
                if let Some(d) = p.last.borrow().as_ref() {
                    p.update_models(d);
                }
            }
        });
        page
    }

    /// Renders a snapshot. Sections whose inputs did not change are left
    /// alone, so focus and scroll position survive the 30-second refresh.
    pub fn update(&self, d: &Dashboard, clock24: bool) {
        let previous = self.last.borrow().clone();
        let clock_changed = self.clock24.replace(clock24) != clock24;
        let changed =
            |f: &dyn Fn(&Dashboard) -> bool| previous.as_ref().is_none_or(f) || clock_changed;

        self.update_hero(d);
        if changed(&|p| {
            p.summary != d.summary || p.settings != d.settings || p.accounts != d.accounts
        }) {
            self.update_groups(d);
        }
        if changed(&|p| p.timeline != d.timeline || p.accounts != d.accounts) {
            self.update_chart(d, clock24);
        }
        if changed(&|p| p.models != d.models) {
            self.update_models(d);
        }
        if changed(&|p| p.limits != d.limits) {
            self.update_limits(d);
        }
        *self.last.borrow_mut() = Some(d.clone());
        self.tick(Utc::now());
    }

    /// Relative times ("Updated 2 min ago").
    pub fn tick(&self, now: DateTime<Utc>) {
        let Some(d) = self.last.borrow().clone() else {
            return;
        };
        let scanned = d.status.last_scan_at.unwrap_or(d.summary.generated_at);
        let mut first = format!(
            "From {}",
            if d.summary.server_name.is_empty() {
                &d.status.server_name
            } else {
                &d.summary.server_name
            }
        );
        if !d.status.version.is_empty() {
            first.push_str(&format!(" · planmeterd {}", d.status.version));
        }
        first.push_str(&format!(" · Data as of {}", format::relative(scanned, now)));
        let text = format!("{first}\nEstimated costs: API-equivalent token prices, or workspace credits where reported.");
        set_text(&self.footer, &text);
        if !d.limits.accounts.is_empty() {
            // Reset countdowns move with time.
            self.update_limits(&d);
        }
    }

    fn update_hero(&self, d: &Dashboard) {
        let s = &d.summary;
        set_text(
            &self.hero_title,
            &format!("Total spend · {}", d.range.display_name()),
        );
        set_text(&self.hero_amount, &format::usd(s.total.cost_usd));
        self.hero_amount
            .update_property(&[gtk::accessible::Property::Label(&format!(
                "Total spend for {}: {}",
                d.range.phrase(),
                format::usd(s.total.cost_usd)
            ))]);
        let accounts = s.account_count();
        let groups = s.groups.len();
        set_text(
            &self.hero_caption,
            &format!(
                "{} {} in {} plan {}",
                accounts,
                if accounts == 1 { "account" } else { "accounts" },
                groups,
                if groups == 1 { "group" } else { "groups" }
            ),
        );
        set_text(&self.stat_today.value, &format::usd(s.today_cost_usd));
        set_text(&self.stat_tokens.value, &format::tokens(s.total.tokens));
        set_text(
            &self.stat_cached.value,
            &format::percent(s.total.cached_share()),
        );
        set_text(
            &self.stat_savings.value,
            &format::usd(s.total.cache_savings_usd),
        );
        set_text(
            &self.stat_sessions.value,
            &format::grouped(s.total.sessions),
        );

        let groups = d.settings.effective_spend_groups();
        let scope = format::group_list(&groups);
        let spend = d.spend_total();
        match d.threshold() {
            Some(t) => {
                self.limit_stack.set_visible_child_name("limit");
                set_text(
                    &self.limit_scope,
                    &format!("{scope} · {}", d.range.display_name()),
                );
                set_text(&self.limit_amount, &format::usd(spend));
                set_text(&self.limit_of, &format!("of {}", format::usd(t.limit)));
                let fraction = t.fraction(spend);
                set_text(&self.limit_percent, &format::percent(fraction));
                self.limit_bar.set_fraction(fraction.min(1.0));
                self.limit_bar
                    .update_property(&[gtk::accessible::Property::ValueText(&format!(
                        "{} of {} used",
                        format::usd(spend),
                        format::usd(t.limit)
                    ))]);
                let status = t.status(spend);
                let class = match status {
                    SpendStatus::Comfortable => "spend-comfortable",
                    SpendStatus::Approaching => "spend-approaching",
                    SpendStatus::Reached => "spend-reached",
                };
                let classes = ["spend-comfortable", "spend-approaching", "spend-reached"];
                set_class(&self.limit_bar, &classes, class);
                set_class(&self.limit_status, &classes, class);
                set_class(&self.limit_icon, &classes, class);
                self.limit_icon.set_icon_name(Some(match status {
                    SpendStatus::Comfortable => "object-select-symbolic",
                    SpendStatus::Approaching => "dialog-warning-symbolic",
                    SpendStatus::Reached => "dialog-error-symbolic",
                }));
                let text = if spend >= t.limit {
                    if spend == t.limit {
                        "Limit reached".to_string()
                    } else {
                        format!("{} over limit", format::usd(spend - t.limit))
                    }
                } else {
                    let close = if status == SpendStatus::Approaching {
                        " · Getting close"
                    } else {
                        ""
                    };
                    format!("{} left{close}", format::usd(t.limit - spend))
                };
                set_text(&self.limit_status, &text);
            }
            None => {
                self.limit_stack.set_visible_child_name("none");
                let who = if scope == "All groups" {
                    "Spend".to_string()
                } else {
                    format!("{scope} spend")
                };
                set_text(
                    &self.limit_empty_text,
                    &format!(
                        "{who} for {} is {}. Set a target to see progress here and get a notification as you near it.",
                        d.range.phrase(),
                        format::usd(spend)
                    ),
                );
            }
        }
    }

    fn update_groups(&self, d: &Dashboard) {
        self.groups.remove_all();
        let s = &d.summary;
        if s.groups.is_empty() {
            let empty = card(8);
            empty.append(&label_with("No accounts discovered", &["heading"]));
            empty.append(&caption(
                "planmeterd reads the logins in ~/.codex, ~/.claude, and OpenCode’s database. Run a coding agent once, then refresh.",
            ));
            flow_append(&self.groups, &empty);
            return;
        }
        let total = s.total.cost_usd;
        let colors = d.all_accounts();
        for group in &s.groups {
            let plan = PlanGroup::parse(&group.group);
            let share = if total > 0.0 {
                group.totals.cost_usd / total
            } else {
                0.0
            };
            let card = card(10);
            card.set_width_request(270);
            card.set_valign(gtk::Align::Fill);
            let head = hbox(8);
            head.append(&dot(plan.color_hex(), 10));
            head.append(&label_with(plan.display_name(), &["heading"]));
            head.append(&spacer());
            let share_label = label_with(&format::percent(share), &["dim-label", "numeric"]);
            share_label.set_tooltip_text(Some("Share of total spend"));
            head.append(&share_label);
            card.append(&head);

            let amount = hbox(10);
            let value = label_with(
                &format::usd(group.totals.cost_usd),
                &["group-amount", "numeric"],
            );
            value.set_valign(gtk::Align::Baseline);
            let tokens = label_with(
                &format!("{} tokens", format::tokens(group.totals.tokens)),
                &["dim-label", "numeric"],
            );
            tokens.set_valign(gtk::Align::Baseline);
            amount.append(&value);
            amount.append(&tokens);
            card.append(&amount);
            let bar = thin_bar(share, &format!("group-{}", plan.id()));
            bar.update_property(&[
                gtk::accessible::Property::Label(&format!(
                    "{} share of spend",
                    plan.display_name()
                )),
                gtk::accessible::Property::ValueText(&format::percent(share)),
            ]);
            card.append(&bar);
            let t = &group.totals;
            let stats = caption(&format!(
                "{} {} · {} cached · {} saved",
                format::grouped(t.sessions),
                if t.sessions == 1 {
                    "session"
                } else {
                    "sessions"
                },
                format::percent(t.cached_share()),
                format::usd(t.cache_savings_usd)
            ));
            stats.add_css_class("numeric");
            stats.set_tooltip_text(Some("Known sessions, the share of input served from cache, and what caching saved at standard model rates."));
            card.append(&stats);
            card.append(&gtk::Separator::new(gtk::Orientation::Horizontal));

            let rows = vbox(8);
            for usage in &group.accounts {
                let a = &usage.account;
                let row = hbox(8);
                row.append(&dot(&format::account_color(&colors, &a.id), 8));
                let name = label(&a.name);
                name.set_ellipsize(gtk::pango::EllipsizeMode::End);
                row.append(&name);
                if let Some(plan) = a.plan.as_deref().filter(|p| !p.is_empty()) {
                    row.append(&tag(plan, &[]));
                }
                row.append(&spacer());
                let cost = label_with(&format::usd(usage.totals.cost_usd), &["numeric"]);
                if usage.totals.tokens == 0 {
                    cost.add_css_class("dim-label");
                }
                row.append(&cost);
                row.set_tooltip_text(Some(&format!(
                    "{} · {} tokens · {} sessions",
                    a.provider_name,
                    format::tokens(usage.totals.tokens),
                    format::grouped(usage.totals.sessions)
                )));
                rows.append(&row);
            }
            if group.accounts.is_empty() {
                rows.append(&caption("No accounts assigned"));
            }
            card.append(&rows);
            flow_append(&self.groups, &card);
        }
    }

    fn update_chart(&self, d: &Dashboard, clock24: bool) {
        let data = ChartData::build(&d.timeline);
        let accounts = d.all_accounts();
        let colors: Vec<String> = data
            .accounts
            .iter()
            .map(|a| format::account_color(&accounts, &a.id))
            .collect();

        let legend: Vec<String> = data
            .accounts
            .iter()
            .zip(&colors)
            .map(|(account, color)| {
                // A non-breaking space keeps each dot with its name; items
                // wrap at the spaces between them.
                format!(
                    "<span foreground=\"{color}\" size=\"larger\">\u{25CF}</span>\u{00A0}{}",
                    markup_escape(&account.name).replace(' ', "\u{00A0}")
                )
            })
            .collect();
        self.legend.set_markup(&legend.join("\u{2003} "));
        self.legend.set_visible(!legend.is_empty());
        clear(&self.chart_notes);
        let shown = Resolution::parse(&d.timeline.resolution);
        if shown.is_some_and(|r| r != d.granularity) {
            self.chart_notes.append(&caption(&format!(
                "Showing {} buckets; this version of planmeterd doesn’t offer finer ones for this range.",
                shown.map(|r| r.label()).unwrap_or("coarser")
            )));
        }
        if data.has_baseline {
            self.chart_notes.append(&caption(
                "Lighter bars: workspace credits without timing (Chat, voice, image), spread evenly over the hours the provider reported.",
            ));
        }
        self.chart_notes
            .set_visible(self.chart_notes.first_child().is_some());
        self.chart
            .set_data(data, colors, d.range.is_multi_day(), clock24);
        set_text(&self.chart_title, "Cost over time");
    }

    fn update_models(&self, d: &Dashboard) {
        self.models_list.remove_all();
        let rows = &d.models;
        let show_all = self.show_all_models.get();
        self.models_toggle.set_visible(rows.len() > MODELS_PREVIEW);
        let toggle = if show_all {
            "Show Less".to_string()
        } else {
            format!("Show All {}", rows.len())
        };
        self.models_toggle.set_label(&toggle);
        if rows.is_empty() {
            let row = row("No usage in this range", "");
            row.add_css_class("dim-label");
            self.models_list.append(&row);
            return;
        }
        for m in rows
            .iter()
            .take(if show_all { rows.len() } else { MODELS_PREVIEW })
        {
            let mut subtitle = format!(
                "{} · {} tokens",
                m.account_name,
                format::tokens(m.totals.tokens)
            );
            if m.totals.input_tokens > 0 {
                subtitle.push_str(&format!(
                    " · {} cached",
                    format::percent(m.totals.cached_share())
                ));
            }
            let row = row(&m.model, &subtitle);
            row.set_title_lines(1);
            row.set_subtitle_lines(1);
            row.add_prefix(&dot(PlanGroup::parse(&m.group).color_hex(), 8));
            if m.priced {
                let cost = label_with(&format::usd(m.totals.cost_usd), &["numeric"]);
                row.add_suffix(&cost);
            } else {
                let unpriced = tag("Unpriced", &["unpriced"]);
                unpriced
                    .set_tooltip_text(Some("No rate found for this model; its cost shows as $0."));
                row.add_suffix(&unpriced);
            }
            self.models_list.append(&row);
        }
        self.models_group.set_description(None);
    }

    fn update_limits(&self, d: &Dashboard) {
        self.limits_list.remove_all();
        let now = Utc::now();
        // Group descriptions are Pango markup; the note comes from the daemon.
        let note = Some(markup_escape(&d.limits.note)).filter(|n| !n.is_empty());
        self.limits_group.set_description(note.as_deref());
        if d.limits.accounts.is_empty() {
            let row = row(
                "No Codex accounts",
                "Claude Code doesn’t store limits locally.",
            );
            self.limits_list.append(&row);
            return;
        }
        for entry in &d.limits.accounts {
            let item = vbox(8);
            item.set_margin_top(12);
            item.set_margin_bottom(12);
            item.set_margin_start(14);
            item.set_margin_end(14);
            let head = hbox(8);
            head.append(&dot(PlanGroup::parse(&entry.account.group).color_hex(), 8));
            let name = label_with(&entry.account.name, &["heading"]);
            name.set_ellipsize(gtk::pango::EllipsizeMode::End);
            head.append(&name);
            if let Some(plan) = entry.account.plan.as_deref() {
                head.append(&label_with(plan, &["dim-label", "caption"]));
            }
            head.append(&spacer());
            if let Some(as_of) = entry.as_of {
                head.append(&label_with(
                    &format!("as of {}", format::relative(as_of, now)),
                    &["dim-label", "caption"],
                ));
            }
            item.append(&head);
            for w in &entry.windows {
                let line = hbox(6);
                line.append(&label_with(&w.label, &["caption"]));
                line.append(&spacer());
                let reset = if w.resets_at > now {
                    format!("resets {}", format::relative(w.resets_at, now))
                } else {
                    "reset pending".into()
                };
                line.append(&label_with(
                    &format!("{}% used · {reset}", w.used_percent.round() as i64),
                    &["caption", "numeric", "dim-label"],
                ));
                item.append(&line);
                let class = if w.used_percent > 90.0 {
                    "limit-critical"
                } else if w.used_percent > 70.0 {
                    "limit-warning"
                } else {
                    ""
                };
                let bar = thin_bar(w.used_percent / 100.0, class);
                bar.update_property(&[
                    gtk::accessible::Property::Label(&format!(
                        "{} {} limit",
                        entry.account.name, w.label
                    )),
                    gtk::accessible::Property::ValueText(&format!(
                        "{}% used, {reset}",
                        w.used_percent.round() as i64
                    )),
                ]);
                item.append(&bar);
            }
            if let Some(note) = entry.note.as_deref() {
                item.append(&caption(note));
            }
            let row = gtk::ListBoxRow::builder()
                .child(&item)
                .activatable(false)
                .build();
            self.limits_list.append(&row);
        }
    }
}
