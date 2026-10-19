//! Number, currency, and time formatting shared by every screen. Rules match
//! the Mac and iPhone `Format`/`Fmt` helpers.

use crate::range::Resolution;
use chrono::{DateTime, Local, Timelike, Utc};

/// Groups an integer's digits with thousands separators: `1284` → `1,284`.
pub fn grouped(value: i64) -> String {
    let digits = value.unsigned_abs().to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3 + 1);
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    if value < 0 {
        format!("-{out}")
    } else {
        out
    }
}

/// US dollars: `$0.00`, `<$0.01`, `$12.34`, `$1,234` (no cents from $1,000).
pub fn usd(value: f64) -> String {
    if !value.is_finite() {
        return "–".into();
    }
    if value == 0.0 {
        return "$0.00".into();
    }
    if value > 0.0 && value < 0.005 {
        return "<$0.01".into();
    }
    let sign = if value < 0.0 { "-" } else { "" };
    let abs = value.abs();
    if abs >= 1000.0 {
        return format!("{sign}${}", grouped(abs.round() as i64));
    }
    let cents = (abs * 100.0).round() as i64;
    format!("{sign}${}.{:02}", grouped(cents / 100), cents % 100)
}

/// Axis labels: as few digits as the tick step needs.
pub fn usd_axis(value: f64, step: f64) -> String {
    if value == 0.0 {
        return "$0".into();
    }
    if value >= 10_000.0 && step >= 1000.0 {
        let k = value / 1000.0;
        return if (k - k.round()).abs() < 1e-9 {
            format!("${}K", k.round() as i64)
        } else {
            format!("${k:.1}K")
        };
    }
    if step >= 1.0 && (value - value.round()).abs() < 1e-9 {
        return format!("${}", grouped(value.round() as i64));
    }
    if step >= 0.1 {
        return format!("${value:.1}");
    }
    format!("${value:.2}")
}

/// Token counts: `999`, `1.2K`, `12K`, `1.2M`, `1.23B`.
pub fn tokens(value: i64) -> String {
    let v = value as f64;
    if v >= 1_000_000_000.0 {
        format!("{:.2}B", v / 1_000_000_000.0)
    } else if v >= 1_000_000.0 {
        format!("{:.1}M", v / 1_000_000.0)
    } else if v >= 10_000.0 {
        format!("{:.0}K", v / 1_000.0)
    } else if v >= 1_000.0 {
        format!("{:.1}K", v / 1_000.0)
    } else {
        value.to_string()
    }
}

/// A fraction as a whole percentage: `0.642` → `64%`.
pub fn percent(fraction: f64) -> String {
    if !fraction.is_finite() {
        return "–".into();
    }
    format!("{:.0}%", fraction * 100.0)
}

/// Short relative time: `just now`, `5 min ago`, `in 2 hr`, `3 days ago`.
pub fn relative(date: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let seconds = (date - now).num_seconds();
    let future = seconds > 0;
    let s = seconds.abs();
    if s < 45 {
        return if future {
            "in a moment".into()
        } else {
            "just now".into()
        };
    }
    let (amount, unit) = if s < 3600 {
        (((s as f64) / 60.0).round().max(1.0) as i64, "min")
    } else if s < 86_400 {
        if future && s < 10 * 3600 {
            // "in 2 hr 15 min" reads better for limit resets.
            let mut h = s / 3600;
            let mut m = ((s % 3600) as f64 / 60.0).round() as i64;
            if m == 60 {
                h += 1;
                m = 0;
            }
            return if m == 0 {
                format!("in {h} hr")
            } else {
                format!("in {h} hr {m} min")
            };
        }
        ((s as f64 / 3600.0).round() as i64, "hr")
    } else {
        let days = (s as f64 / 86_400.0).round() as i64;
        (days, if days == 1 { "day" } else { "days" })
    };
    if future {
        format!("in {amount} {unit}")
    } else {
        format!("{amount} {unit} ago")
    }
}

/// `Updated just now`, `Updated 5 min ago`.
pub fn updated(date: DateTime<Utc>, now: DateTime<Utc>) -> String {
    format!("Updated {}", relative(date, now))
}

/// A countdown as `m:ss`.
pub fn countdown(seconds: i64) -> String {
    let s = seconds.max(0);
    format!("{}:{:02}", s / 60, s % 60)
}

/// The Mac's names for Codex rate-limit windows.
pub fn window_name(minutes: i64) -> String {
    match minutes {
        10080 => "Weekly".into(),
        300 => "5-hour".into(),
        60 => "Hourly".into(),
        1440 => "Daily".into(),
        m if m > 0 && m % 1440 == 0 => format!("{}-day", m / 1440),
        m if m > 0 && m % 60 == 0 => format!("{}-hour", m / 60),
        m => format!("{m}-minute"),
    }
}

pub fn group_name(raw: &str) -> &'static str {
    crate::models::PlanGroup::parse(raw).display_name()
}

/// Human list of plan groups: `Personal`, `Personal and Work`, `All groups`.
pub fn group_list(groups: &[String]) -> String {
    let names: Vec<&str> = crate::models::PlanGroup::ALL
        .iter()
        .filter(|g| groups.iter().any(|s| s == g.id()))
        .map(|g| g.display_name())
        .collect();
    match names.len() {
        0 | 3 => "All groups".into(),
        1 => names[0].into(),
        _ => names.join(" and "),
    }
}

/// A paired device's platform for display: `web` → `Web browser`,
/// `android` → `Android`; descriptive names pass through.
pub fn platform_name(raw: &str) -> String {
    match raw.trim() {
        "" => "Unknown device".into(),
        p if p.eq_ignore_ascii_case("web") => "Web browser".into(),
        p if p.eq_ignore_ascii_case("ios") => "iOS".into(),
        p if p.chars().all(|c| c.is_ascii_lowercase()) => {
            let mut chars = p.chars();
            chars
                .next()
                .map(|c| c.to_ascii_uppercase().to_string() + chars.as_str())
                .unwrap_or_default()
        }
        p => p.to_string(),
    }
}

/// `12345678` → `1234 5678`, as the Mac shows the web pairing code.
pub fn web_code(code: &str) -> String {
    if code.len() == 8 && code.is_ascii() {
        format!("{} {}", &code[..4], &code[4..])
    } else {
        code.to_string()
    }
}

/// Parses `#rrggbb` or `#rrggbbaa` into sRGB components in `0..=1`.
pub fn parse_hex(hex: &str) -> Option<(f64, f64, f64, f64)> {
    let s = hex.trim().trim_start_matches('#');
    if !(s.len() == 6 || s.len() == 8) || !s.is_ascii() {
        return None;
    }
    let value = u32::from_str_radix(s, 16).ok()?;
    let (r, g, b, a) = if s.len() == 8 {
        (
            (value >> 24) & 0xff,
            (value >> 16) & 0xff,
            (value >> 8) & 0xff,
            value & 0xff,
        )
    } else {
        (
            (value >> 16) & 0xff,
            (value >> 8) & 0xff,
            value & 0xff,
            0xff,
        )
    };
    Some((
        r as f64 / 255.0,
        g as f64 / 255.0,
        b as f64 / 255.0,
        a as f64 / 255.0,
    ))
}

/// Fallback series colors when an account has no unique accent.
pub const SERIES_PALETTE: [&str; 8] = [
    "#4f7cff", "#f0883e", "#2fb87a", "#c06ad9", "#e5484d", "#0aa8a7", "#d9a400", "#8b8f98",
];

/// The account's accent when it is unique among `accounts`, otherwise a
/// palette color by position, as the Mac and iPhone pick series colors.
pub fn account_color(accounts: &[crate::models::RemoteAccount], id: &str) -> String {
    let Some(index) = accounts.iter().position(|a| a.id == id) else {
        return "#8b8f98".into();
    };
    if let Some(hex) = accounts[index].accent_color_hex.as_deref() {
        let lower = hex.to_ascii_lowercase();
        let unique = accounts
            .iter()
            .filter(|a| {
                a.accent_color_hex
                    .as_deref()
                    .map(str::to_ascii_lowercase)
                    .as_deref()
                    == Some(lower.as_str())
            })
            .count()
            == 1;
        if unique && parse_hex(hex).is_some() {
            return hex.to_string();
        }
    }
    SERIES_PALETTE[index % SERIES_PALETTE.len()].to_string()
}

/// Clock time for labels, honoring the desktop's 12/24-hour preference.
pub fn clock(date: DateTime<Local>, clock24: bool, with_minutes: bool) -> String {
    if clock24 {
        return format!("{:02}:{:02}", date.hour(), date.minute());
    }
    let (pm, h) = date.hour12();
    let suffix = if pm { "PM" } else { "AM" };
    if with_minutes || date.minute() != 0 {
        format!("{h}:{:02} {suffix}", date.minute())
    } else {
        format!("{h} {suffix}")
    }
}

/// Chart axis and tooltip labels for a bucket start.
pub fn period_label(
    date: DateTime<Local>,
    resolution: Resolution,
    multi_day: bool,
    clock24: bool,
) -> String {
    match resolution {
        Resolution::Day => date.format("%b %-d").to_string(),
        Resolution::Hour | Resolution::FifteenMinutes => {
            let time = clock(
                date,
                clock24,
                resolution == Resolution::FifteenMinutes && date.minute() != 0,
            );
            if multi_day && date.hour() == 0 && date.minute() == 0 {
                // Midnight ticks name the day instead of the time.
                date.format("%a %-d").to_string()
            } else if multi_day {
                format!("{} {time}", date.format("%a"))
            } else {
                time
            }
        }
        Resolution::Minute | Resolution::FiveMinutes => clock(date, clock24, true),
    }
}

/// Tooltip heading for a bucket: the full span it covers.
pub fn period_span(start: DateTime<Local>, resolution: Resolution, clock24: bool) -> String {
    match resolution {
        Resolution::Day => start.format("%A, %B %-d").to_string(),
        _ => {
            let end = start + chrono::Duration::seconds(resolution.nominal_seconds());
            format!(
                "{} {} – {}",
                start.format("%a %b %-d,"),
                clock(start, clock24, true),
                clock(end, clock24, true)
            )
        }
    }
}

/// Local date and time, e.g. `Oct 19, 14:05`.
pub fn date_time(date: DateTime<Utc>, clock24: bool) -> String {
    let local = date.with_timezone(&Local);
    format!(
        "{}, {}",
        local.format("%b %-d"),
        clock(local, clock24, true)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn currency_matches_the_mac() {
        assert_eq!(usd(0.0), "$0.00");
        assert_eq!(usd(0.004), "<$0.01");
        assert_eq!(usd(0.005), "$0.01");
        assert_eq!(usd(12.345), "$12.35");
        assert_eq!(usd(999.994), "$999.99");
        assert_eq!(usd(1234.56), "$1,235");
        assert_eq!(usd(1_234_567.0), "$1,234,567");
        assert_eq!(usd(-3.5), "-$3.50");
        assert_eq!(usd(f64::NAN), "–");
    }

    #[test]
    fn axis_labels_are_compact() {
        assert_eq!(usd_axis(0.0, 5.0), "$0");
        assert_eq!(usd_axis(15.0, 5.0), "$15");
        assert_eq!(usd_axis(2500.0, 500.0), "$2,500");
        assert_eq!(usd_axis(20_000.0, 5000.0), "$20K");
        assert_eq!(usd_axis(0.5, 0.25), "$0.5");
        assert_eq!(usd_axis(0.05, 0.05), "$0.05");
    }

    #[test]
    fn token_counts() {
        assert_eq!(tokens(999), "999");
        assert_eq!(tokens(1_234), "1.2K");
        assert_eq!(tokens(45_600), "46K");
        assert_eq!(tokens(48_200_000), "48.2M");
        assert_eq!(tokens(1_230_000_000), "1.23B");
    }

    #[test]
    fn percents_and_grouping() {
        assert_eq!(percent(0.642), "64%");
        assert_eq!(percent(f64::INFINITY), "–");
        assert_eq!(grouped(1284), "1,284");
        assert_eq!(grouped(-1_000_000), "-1,000,000");
        assert_eq!(grouped(12), "12");
    }

    #[test]
    fn relative_times() {
        let now = Utc.with_ymd_and_hms(2026, 10, 19, 12, 0, 0).unwrap();
        let ago = |s: i64| relative(now - chrono::Duration::seconds(s), now);
        let ahead = |s: i64| relative(now + chrono::Duration::seconds(s), now);
        assert_eq!(ago(10), "just now");
        assert_eq!(ago(300), "5 min ago");
        assert_eq!(ago(7200), "2 hr ago");
        assert_eq!(ago(3 * 86_400), "3 days ago");
        assert_eq!(ahead(7200), "in 2 hr");
        assert_eq!(ahead(2 * 3600 + 13 * 60), "in 2 hr 13 min");
        assert_eq!(ahead(86_400), "in 1 day");
    }

    #[test]
    fn window_names_match_the_mac() {
        assert_eq!(window_name(300), "5-hour");
        assert_eq!(window_name(10080), "Weekly");
        assert_eq!(window_name(2880), "2-day");
        assert_eq!(window_name(120), "2-hour");
        assert_eq!(window_name(45), "45-minute");
    }

    #[test]
    fn hex_colors() {
        assert_eq!(parse_hex("#ff0000"), Some((1.0, 0.0, 0.0, 1.0)));
        assert_eq!(
            parse_hex("00ff0080").map(|c| (c.1, (c.3 * 255.0).round())),
            Some((1.0, 128.0))
        );
        assert_eq!(parse_hex("#12"), None);
        assert_eq!(parse_hex("#zzzzzz"), None);
    }

    #[test]
    fn account_colors_prefer_unique_accents() {
        use crate::models::RemoteAccount;
        let mk = |id: &str, hex: Option<&str>| RemoteAccount {
            id: id.into(),
            accent_color_hex: hex.map(Into::into),
            ..Default::default()
        };
        let accounts = vec![
            mk("a", Some("#123456")),
            mk("b", Some("#ABCDEF")),
            mk("c", Some("#abcdef")),
            mk("d", None),
        ];
        assert_eq!(account_color(&accounts, "a"), "#123456");
        assert_eq!(account_color(&accounts, "b"), SERIES_PALETTE[1]);
        assert_eq!(account_color(&accounts, "d"), SERIES_PALETTE[3]);
        assert_eq!(account_color(&accounts, "missing"), "#8b8f98");
    }

    #[test]
    fn labels_and_codes() {
        let t = Local.with_ymd_and_hms(2026, 10, 19, 14, 5, 0).unwrap();
        assert_eq!(period_label(t, Resolution::Minute, false, true), "14:05");
        assert_eq!(
            period_label(t, Resolution::FiveMinutes, false, false),
            "2:05 PM"
        );
        let h = Local.with_ymd_and_hms(2026, 10, 19, 14, 0, 0).unwrap();
        assert_eq!(period_label(h, Resolution::Hour, false, false), "2 PM");
        assert_eq!(period_label(h, Resolution::Hour, true, true), "Mon 14:00");
        let midnight = Local.with_ymd_and_hms(2026, 10, 19, 0, 0, 0).unwrap();
        assert_eq!(
            period_label(midnight, Resolution::Hour, true, true),
            "Mon 19"
        );
        assert_eq!(period_label(h, Resolution::Day, true, true), "Oct 19");
        assert_eq!(web_code("12345678"), "1234 5678");
        assert_eq!(platform_name("android"), "Android");
        assert_eq!(platform_name("web"), "Web browser");
        assert_eq!(platform_name("iPhone · iOS 26.1"), "iPhone · iOS 26.1");
        assert_eq!(platform_name(""), "Unknown device");
        assert_eq!(web_code("123"), "123");
        assert_eq!(countdown(272), "4:32");
        assert_eq!(
            group_list(&["work".into(), "personal".into()]),
            "Personal and Work"
        );
        assert_eq!(
            group_list(&["personal".into(), "work".into(), "other".into()]),
            "All groups"
        );
    }
}
