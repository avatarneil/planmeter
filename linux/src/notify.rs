//! Spend alerts: decide when the selected spend total has crossed the warning
//! level or the limit, so the UI notifies once per crossing per period.

use crate::models::{SpendStatus, SpendThreshold};
use crate::range::TimeRange;
use chrono::{DateTime, Local, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    period: String,
    /// 0 comfortable, 1 warned, 2 reached.
    level: u8,
}

/// What has already been announced, per range. Persisted between launches so
/// restarting the app does not repeat an alert.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AlertLedger {
    entries: BTreeMap<String, Entry>,
}

fn level(status: SpendStatus) -> u8 {
    match status {
        SpendStatus::Comfortable => 0,
        SpendStatus::Approaching => 1,
        SpendStatus::Reached => 2,
    }
}

/// The period an alert belongs to. Day-or-shorter ranges reset at local
/// midnight; longer ranges when their window moves to a new first day.
pub fn period_key(range: TimeRange, window_from: DateTime<Utc>, now: DateTime<Local>) -> String {
    match range {
        TimeRange::LastHour | TimeRange::Today | TimeRange::Day => {
            format!("{}:{}", range.id(), now.format("%Y-%m-%d"))
        }
        _ => format!(
            "{}:{}",
            range.id(),
            window_from.with_timezone(&Local).format("%Y-%m-%d")
        ),
    }
}

impl AlertLedger {
    /// Records the latest spend and returns the status to announce, if this
    /// reading escalates past what was already announced in the period.
    /// Falling back below a level (a raised limit, a new period) re-arms it.
    pub fn observe(
        &mut self,
        range: TimeRange,
        period: &str,
        threshold: &SpendThreshold,
        spend: f64,
    ) -> Option<SpendStatus> {
        if !threshold.is_valid() || !spend.is_finite() {
            return None;
        }
        let status = threshold.status(spend);
        let now = level(status);
        let entry = self.entries.entry(range.id().to_string()).or_default();
        let previous = if entry.period == period {
            entry.level
        } else {
            0
        };
        entry.period = period.to_string();
        entry.level = now;
        (now > previous).then_some(status)
    }

    /// Forget a range, e.g. when its limit is removed.
    pub fn clear(&mut self, range: TimeRange) {
        self.entries.remove(range.id());
    }
}

/// Notification text for a crossing.
pub fn message(
    status: SpendStatus,
    range: TimeRange,
    groups: &str,
    spend: f64,
    threshold: &SpendThreshold,
) -> Option<(String, String)> {
    use crate::format::{percent, usd};
    let scope = if groups == "All groups" {
        "Spend".to_string()
    } else {
        format!("{groups} spend")
    };
    match status {
        SpendStatus::Comfortable => None,
        SpendStatus::Approaching => Some((
            "Approaching Your Spend Limit".into(),
            format!(
                "{scope} for {} is {}, {} of your {} limit.",
                range.phrase(),
                usd(spend),
                percent(threshold.fraction(spend)),
                usd(threshold.limit)
            ),
        )),
        SpendStatus::Reached => Some((
            "Spend Limit Reached".into(),
            if spend > threshold.limit {
                format!(
                    "{scope} for {} is {}, {} over your {} limit.",
                    range.phrase(),
                    usd(spend),
                    usd(spend - threshold.limit),
                    usd(threshold.limit)
                )
            } else {
                format!(
                    "{scope} for {} reached your {} limit.",
                    range.phrase(),
                    usd(threshold.limit)
                )
            },
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notifies_once_per_crossing() {
        let t = SpendThreshold::new(100.0, 80.0);
        let mut ledger = AlertLedger::default();
        let r = TimeRange::Today;
        assert_eq!(ledger.observe(r, "p1", &t, 10.0), None);
        assert_eq!(
            ledger.observe(r, "p1", &t, 85.0),
            Some(SpendStatus::Approaching)
        );
        assert_eq!(ledger.observe(r, "p1", &t, 90.0), None);
        assert_eq!(
            ledger.observe(r, "p1", &t, 120.0),
            Some(SpendStatus::Reached)
        );
        assert_eq!(ledger.observe(r, "p1", &t, 130.0), None);
        // A raised limit drops below the warning; crossing again re-notifies.
        let raised = SpendThreshold::new(1000.0, 80.0);
        assert_eq!(ledger.observe(r, "p1", &raised, 130.0), None);
        assert_eq!(
            ledger.observe(r, "p1", &raised, 900.0),
            Some(SpendStatus::Approaching)
        );
    }

    #[test]
    fn new_period_rearms() {
        let t = SpendThreshold::new(50.0, 80.0);
        let mut ledger = AlertLedger::default();
        assert_eq!(
            ledger.observe(TimeRange::Today, "d1", &t, 60.0),
            Some(SpendStatus::Reached)
        );
        assert_eq!(ledger.observe(TimeRange::Today, "d1", &t, 61.0), None);
        assert_eq!(
            ledger.observe(TimeRange::Today, "d2", &t, 61.0),
            Some(SpendStatus::Reached)
        );
        // Ranges are independent.
        assert_eq!(
            ledger.observe(TimeRange::Week, "w1", &t, 45.0),
            Some(SpendStatus::Approaching)
        );
    }

    #[test]
    fn invalid_thresholds_never_notify() {
        let mut ledger = AlertLedger::default();
        assert_eq!(
            ledger.observe(TimeRange::Today, "d", &SpendThreshold::new(0.0, 80.0), 5.0),
            None
        );
        assert_eq!(
            ledger.observe(
                TimeRange::Today,
                "d",
                &SpendThreshold::new(10.0, 80.0),
                f64::NAN
            ),
            None
        );
    }

    #[test]
    fn ledger_round_trips() {
        let mut ledger = AlertLedger::default();
        ledger.observe(TimeRange::Week, "w", &SpendThreshold::new(10.0, 50.0), 6.0);
        let json = serde_json::to_string(&ledger).unwrap();
        assert_eq!(serde_json::from_str::<AlertLedger>(&json).unwrap(), ledger);
    }

    #[test]
    fn messages() {
        let t = SpendThreshold::new(50.0, 80.0);
        let (title, body) = message(
            SpendStatus::Approaching,
            TimeRange::Today,
            "Personal and Work",
            42.0,
            &t,
        )
        .unwrap();
        assert_eq!(title, "Approaching Your Spend Limit");
        assert_eq!(
            body,
            "Personal and Work spend for today is $42.00, 84% of your $50.00 limit."
        );
        let (_, body) = message(
            SpendStatus::Reached,
            TimeRange::Week,
            "All groups",
            61.5,
            &t,
        )
        .unwrap();
        assert_eq!(
            body,
            "Spend for the last 7 days is $61.50, $11.50 over your $50.00 limit."
        );
        assert!(message(SpendStatus::Comfortable, TimeRange::Week, "Work", 1.0, &t).is_none());
    }
}
