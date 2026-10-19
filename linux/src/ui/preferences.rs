//! Preferences: which plan groups count toward the spend total, spend limits
//! per range, alerts, and per-account plan groups. Host settings are saved
//! to `planmeterd` as they change.

use super::widgets::*;
use super::window::MainWindow;
use adw::prelude::*;
use gtk::glib;
use planmeter::format;
use planmeter::models::{PlanGroup, SpendThreshold};
use planmeter::range::TimeRange;
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::rc::Rc;

fn default_limit(range: TimeRange) -> f64 {
    match range {
        TimeRange::LastHour => 10.0,
        TimeRange::Today | TimeRange::Day => 50.0,
        TimeRange::Week => 250.0,
        TimeRange::Month => 1000.0,
        TimeRange::Quarter => 3000.0,
    }
}

fn threshold_summary(t: Option<&SpendThreshold>) -> String {
    match t {
        Some(t) => format!(
            "{} · warn at {:.0}%",
            format::usd(t.limit),
            t.warning_percent
        ),
        None => "No limit".into(),
    }
}

pub fn present(win: &Rc<MainWindow>, page: Option<&str>) {
    let Some(data) = win.data() else {
        win.toast("Preferences are available once planmeterd is running.");
        return;
    };
    let dialog = adw::PreferencesDialog::new();
    dialog.set_search_enabled(false);

    // MARK: Spending
    let spending = adw::PreferencesPage::builder()
        .name("spending")
        .title("Spending")
        .icon_name("planmeter-dashboard-symbolic")
        .build();

    let total_group = adw::PreferencesGroup::builder()
        .title("Spend Total")
        .description("Plan groups that count toward the spend total, its limits, and alerts. The dashboard still shows every group.")
        .build();
    let groups = Rc::new(RefCell::new(data.settings.effective_spend_groups()));
    let reverting = Rc::new(Cell::new(false));
    for plan in PlanGroup::ALL {
        let row = adw::SwitchRow::builder()
            .title(plan.display_name())
            .active(groups.borrow().iter().any(|g| g == plan.id()))
            .build();
        row.add_prefix(&dot(plan.color_hex(), 10));
        let (win, dialog_weak, groups, reverting) = (
            win.clone(),
            dialog.downgrade(),
            groups.clone(),
            reverting.clone(),
        );
        row.connect_active_notify(move |row| {
            if reverting.get() {
                return;
            }
            let Some(dialog) = dialog_weak.upgrade() else {
                return;
            };
            let mut selected: Vec<String> = groups.borrow().clone();
            if row.is_active() {
                if !selected.iter().any(|g| g == plan.id()) {
                    selected.push(plan.id().into());
                }
            } else {
                selected.retain(|g| g != plan.id());
            }
            if selected.is_empty() {
                reverting.set(true);
                row.set_active(true);
                reverting.set(false);
                dialog.add_toast(super::widgets::plain_toast(
                    "At least one plan group counts toward the total",
                ));
                return;
            }
            let ordered: Vec<String> = PlanGroup::ALL
                .iter()
                .map(|g| g.id().to_string())
                .filter(|g| selected.contains(g))
                .collect();
            *groups.borrow_mut() = ordered.clone();
            win.save_spend(Some(ordered), None, dialog.downgrade());
        });
        total_group.add(&row);
    }
    spending.add(&total_group);

    let limits_group = adw::PreferencesGroup::builder()
        .title("Spend Limits")
        .description("A personal target for estimated usage cost per range, not a billing cap. The dashboard shows progress for the selected range.")
        .build();
    let thresholds: Rc<RefCell<BTreeMap<String, SpendThreshold>>> = Rc::new(RefCell::new(
        data.settings
            .spend_thresholds
            .iter()
            .filter(|(_, t)| t.is_valid())
            .map(|(k, v)| (k.clone(), *v))
            .collect(),
    ));
    let debounce: Rc<RefCell<Option<glib::SourceId>>> = Rc::new(RefCell::new(None));
    let save_now: Rc<dyn Fn()> = {
        let (win, dialog_weak, thresholds) = (win.clone(), dialog.downgrade(), thresholds.clone());
        Rc::new(move || {
            win.save_spend(None, Some(thresholds.borrow().clone()), dialog_weak.clone());
        })
    };
    let save_thresholds = {
        let (save_now, debounce) = (save_now.clone(), debounce.clone());
        Rc::new(move |delay: bool| {
            if let Some(id) = debounce.borrow_mut().take() {
                id.remove();
            }
            if delay {
                let (save_now, debounce2) = (save_now.clone(), debounce.clone());
                let id = glib::timeout_add_local_once(
                    std::time::Duration::from_millis(700),
                    move || {
                        debounce2.borrow_mut().take();
                        save_now();
                    },
                );
                *debounce.borrow_mut() = Some(id);
            } else {
                save_now();
            }
        })
    };
    // Save a pending edit right away when the dialog or the window closes,
    // rather than when the debounce would have fired: the app quits with
    // its window.
    let flush = {
        let (save_now, debounce) = (save_now.clone(), debounce.clone());
        move || {
            let pending = debounce.borrow_mut().take();
            if let Some(id) = pending {
                id.remove();
                save_now();
            }
        }
    };
    let flush_on_quit = flush.clone();
    let window_handler = win.window.connect_close_request(move |_| {
        flush_on_quit();
        glib::Propagation::Proceed
    });
    let window_weak = win.window.downgrade();
    let window_handler = RefCell::new(Some(window_handler));
    dialog.connect_closed(move |_| {
        flush();
        if let (Some(window), Some(id)) = (window_weak.upgrade(), window_handler.take()) {
            window.disconnect(id);
        }
    });
    for range in TimeRange::ALL {
        let existing = thresholds.borrow().get(range.id()).copied();
        let expander = adw::ExpanderRow::builder()
            .title(range.display_name())
            .subtitle(threshold_summary(existing.as_ref()))
            .show_enable_switch(true)
            .enable_expansion(existing.is_some())
            .expanded(false)
            .build();
        let initial = existing.unwrap_or(SpendThreshold::new(default_limit(range), 80.0));
        let limit = adw::SpinRow::builder()
            .title("Limit")
            .subtitle("US dollars")
            .adjustment(&gtk::Adjustment::new(
                initial.limit,
                SpendThreshold::MIN_LIMIT,
                SpendThreshold::MAX_LIMIT,
                1.0,
                10.0,
                0.0,
            ))
            .digits(2)
            .numeric(true)
            .build();
        let warn = adw::SpinRow::builder()
            .title("Warn At")
            .subtitle("Percent of the limit")
            .adjustment(&gtk::Adjustment::new(
                initial.warning_percent,
                1.0,
                99.0,
                1.0,
                5.0,
                0.0,
            ))
            .digits(0)
            .numeric(true)
            .build();
        expander.add_row(&limit);
        expander.add_row(&warn);

        let apply = {
            let (thresholds, expander_weak, limit, warn, save) = (
                thresholds.clone(),
                expander.downgrade(),
                limit.downgrade(),
                warn.downgrade(),
                save_thresholds.clone(),
            );
            Rc::new(move |delay: bool| {
                let (Some(expander), Some(limit), Some(warn)) =
                    (expander_weak.upgrade(), limit.upgrade(), warn.upgrade())
                else {
                    return;
                };
                let value = SpendThreshold::new(
                    (limit.value() * 100.0).round() / 100.0,
                    warn.value().round(),
                );
                {
                    let mut map = thresholds.borrow_mut();
                    if expander.enables_expansion() && value.is_valid() {
                        map.insert(range.id().into(), value);
                    } else {
                        map.remove(range.id());
                    }
                    expander.set_subtitle(&threshold_summary(map.get(range.id())));
                }
                save(delay);
            })
        };
        let a = apply.clone();
        expander.connect_enable_expansion_notify(move |row| {
            if row.enables_expansion() {
                row.set_expanded(true);
            }
            a(false);
        });
        let a = apply.clone();
        limit.connect_value_notify(move |_| a(true));
        let a = apply.clone();
        warn.connect_value_notify(move |_| a(true));
        limits_group.add(&expander);
    }
    spending.add(&limits_group);

    let alerts = adw::PreferencesGroup::builder()
        .title("Notifications")
        .build();
    let alert_row = adw::SwitchRow::builder()
        .title("Spend Alerts")
        .subtitle(
            "While PlanMeter is open, notify when spend for any range with a limit reaches its warning level or the limit, once per crossing",
        )
        .active(win.notifications_enabled())
        .build();
    let w = win.clone();
    alert_row.connect_active_notify(move |row| w.set_notifications_enabled(row.is_active()));
    alerts.add(&alert_row);
    spending.add(&alerts);
    dialog.add(&spending);

    // MARK: Plan groups
    let accounts_page = adw::PreferencesPage::builder()
        .name("accounts")
        .title("Plan Groups")
        .icon_name("system-users-symbolic")
        .build();
    let plan_group = adw::PreferencesGroup::builder()
        .title("Plan Groups")
        .description("Assign each account to Personal or Work. Automatic uses the suggestion from the account name, email domain, or plan type.")
        .build();
    let reset = gtk::Button::builder()
        .label("Use Suggestions")
        .valign(gtk::Align::Center)
        .build();
    reset.add_css_class("flat");
    plan_group.set_header_suffix(Some(&reset));
    let choices = ["Automatic", "Personal", "Work", "Other"];
    let mut combos: Vec<(String, adw::ComboRow)> = Vec::new();
    let resetting = Rc::new(Cell::new(false));
    let accounts = data.all_accounts();
    for account in &accounts {
        let override_group = data.settings.group_overrides.get(&account.id).copied();
        let selected = match override_group {
            None => 0,
            Some(PlanGroup::Personal) => 1,
            Some(PlanGroup::Work) => 2,
            Some(PlanGroup::Other) => 3,
        };
        let provider = if account.provider_name.is_empty() {
            account.provider.clone()
        } else {
            account.provider_name.clone()
        };
        let subtitle = match override_group {
            None => format!(
                "{provider} · Suggested: {}",
                PlanGroup::parse(&account.group).display_name()
            ),
            Some(_) => provider,
        };
        let combo = adw::ComboRow::builder()
            .title(account.name.as_str())
            .subtitle(subtitle)
            .use_markup(false)
            .model(&gtk::StringList::new(&choices))
            .selected(selected)
            .build();
        combo.add_prefix(&dot(&format::account_color(&accounts, &account.id), 10));
        let (win, dialog_weak, id, resetting) = (
            win.clone(),
            dialog.downgrade(),
            account.id.clone(),
            resetting.clone(),
        );
        combo.connect_selected_notify(move |row| {
            if resetting.get() {
                return;
            }
            let group = match row.selected() {
                1 => Some(PlanGroup::Personal),
                2 => Some(PlanGroup::Work),
                3 => Some(PlanGroup::Other),
                _ => None,
            };
            if let Some(dialog) = dialog_weak.upgrade() {
                win.save_group(id.clone(), group, dialog.downgrade());
            }
        });
        plan_group.add(&combo);
        combos.push((account.id.clone(), combo));
    }
    if accounts.is_empty() {
        plan_group.add(&row("No accounts discovered", ""));
    }
    let combos = Rc::new(combos);
    let (w, dialog_weak) = (win.clone(), dialog.downgrade());
    reset.connect_clicked(move |_| {
        let Some(dialog) = dialog_weak.upgrade() else {
            return;
        };
        resetting.set(true);
        let overridden: Vec<String> = w
            .data()
            .map(|d| d.settings.group_overrides.keys().cloned().collect())
            .unwrap_or_default();
        for (id, combo) in combos.iter() {
            combo.set_selected(0);
            if overridden.contains(id) {
                w.save_group(id.clone(), None, dialog.downgrade());
            }
        }
        resetting.set(false);
    });
    accounts_page.add(&plan_group);
    dialog.add(&accounts_page);

    if let Some(name) = page {
        dialog.set_visible_page_name(name);
    }
    dialog.present(Some(&win.window));
}
