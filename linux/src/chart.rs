//! Chart layout for the stacked per-account timeline, independent of Cairo:
//! zero-filled bars, stacking order (untimed workspace baselines first, as on
//! the iPhone), axis ticks, and hit testing.

use crate::format;
use crate::models::{RemoteAccount, RemoteTimeline, Timestamp};
use crate::range::Resolution;
use chrono::{DateTime, Local, Timelike};
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
pub struct Segment {
    /// Index into `ChartData::accounts`.
    pub account: usize,
    pub low: f64,
    pub high: f64,
    /// Workspace credits without timing, drawn lighter.
    pub baseline: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Bar {
    pub start: Timestamp,
    pub total: f64,
    pub tokens: i64,
    pub segments: Vec<Segment>,
    /// Cost per account in this bucket (including baseline), account order.
    pub by_account: Vec<(usize, f64)>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ChartData {
    pub bars: Vec<Bar>,
    pub accounts: Vec<RemoteAccount>,
    pub resolution: Resolution,
    pub max: f64,
    pub total: f64,
    pub has_baseline: bool,
}

impl ChartData {
    /// Builds bars from a timeline. Accounts keep the timeline's order, with
    /// any account that only appears in points appended.
    pub fn build(timeline: &RemoteTimeline) -> ChartData {
        let resolution = Resolution::parse(&timeline.resolution).unwrap_or(Resolution::Day);
        let mut accounts = timeline.accounts.clone();
        for p in &timeline.points {
            if !accounts.iter().any(|a| a.id == p.account_id) {
                accounts.push(RemoteAccount {
                    id: p.account_id.clone(),
                    name: p.account_id.clone(),
                    ..Default::default()
                });
            }
        }
        let index: BTreeMap<&str, usize> = accounts
            .iter()
            .enumerate()
            .map(|(i, a)| (a.id.as_str(), i))
            .collect();

        // Zero-filled periods, plus any point period the list missed.
        let mut starts: Vec<Timestamp> = timeline.periods.clone();
        for p in &timeline.points {
            starts.push(p.period);
        }
        starts.sort();
        starts.dedup();

        // (cost, baseline, tokens) per (period, account).
        let mut cells: BTreeMap<(Timestamp, usize), (f64, f64, i64)> = BTreeMap::new();
        for p in &timeline.points {
            let Some(&account) = index.get(p.account_id.as_str()) else {
                continue;
            };
            let cell = cells.entry((p.period, account)).or_default();
            cell.0 += p.cost_usd.max(0.0);
            cell.1 += p.baseline_cost_usd.unwrap_or(0.0).max(0.0);
            cell.2 += p.tokens;
        }

        let mut has_baseline = false;
        let mut bars = Vec::with_capacity(starts.len());
        for start in starts {
            let mut segments = Vec::new();
            let mut by_account = Vec::new();
            let mut top = 0.0;
            let mut tokens = 0;
            let row: Vec<(usize, f64, f64, i64)> = (0..accounts.len())
                .filter_map(|a| cells.get(&(start, a)).map(|c| (a, c.0, c.1.min(c.0), c.2)))
                .collect();
            for baseline in [true, false] {
                for &(account, cost, base, _) in &row {
                    let value = if baseline { base } else { cost - base };
                    if value <= 0.0 {
                        continue;
                    }
                    has_baseline |= baseline;
                    segments.push(Segment {
                        account,
                        low: top,
                        high: top + value,
                        baseline,
                    });
                    top += value;
                }
            }
            for &(account, cost, _, t) in &row {
                tokens += t;
                if cost > 0.0 {
                    by_account.push((account, cost));
                }
            }
            bars.push(Bar {
                start,
                total: top,
                tokens,
                segments,
                by_account,
            });
        }
        let max = bars.iter().map(|b| b.total).fold(0.0, f64::max);
        let total = bars.iter().map(|b| b.total).sum();
        ChartData {
            bars,
            accounts,
            resolution,
            max,
            total,
            has_baseline,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.total <= 0.0
    }

    /// The busiest bucket, for the accessible description.
    pub fn peak(&self) -> Option<&Bar> {
        self.bars
            .iter()
            .filter(|b| b.total > 0.0)
            .max_by(|a, b| a.total.total_cmp(&b.total))
    }

    /// Bar index under an x coordinate inside the plot.
    pub fn index_at(&self, x: f64, plot_x: f64, plot_width: f64) -> Option<usize> {
        if self.bars.is_empty() || plot_width <= 0.0 || x < plot_x || x >= plot_x + plot_width {
            return None;
        }
        let slot = plot_width / self.bars.len() as f64;
        Some((((x - plot_x) / slot) as usize).min(self.bars.len() - 1))
    }

    /// Screen-reader summary of the chart.
    pub fn describe(&self, multi_day: bool, clock24: bool) -> String {
        let unit = match self.resolution {
            Resolution::Minute => "one-minute",
            Resolution::FiveMinutes => "five-minute",
            Resolution::FifteenMinutes => "fifteen-minute",
            Resolution::Hour => "hourly",
            Resolution::Day => "daily",
        };
        if self.is_empty() {
            return format!(
                "No usage in this range. {} {unit} buckets.",
                self.bars.len()
            );
        }
        let mut text = format!(
            "Cost over time in {} {unit} buckets, stacked by account. Total {}.",
            self.bars.len(),
            format::usd(self.total)
        );
        if let Some(peak) = self.peak() {
            let label = format::period_label(
                peak.start.with_timezone(&Local),
                self.resolution,
                multi_day,
                clock24,
            );
            text.push_str(&format!(
                " Busiest: {label} with {}.",
                format::usd(peak.total)
            ));
        }
        let names: Vec<&str> = self.accounts.iter().map(|a| a.name.as_str()).collect();
        if !names.is_empty() {
            text.push_str(&format!(" Accounts: {}.", names.join(", ")));
        }
        text
    }
}

/// "Nice" y-axis ticks from zero to at least `max`: steps of 1, 2, 2.5, or 5
/// times a power of ten, about `target` intervals.
pub fn nice_ticks(max: f64, target: usize) -> (f64, Vec<f64>) {
    let target = target.max(1) as f64;
    let max = if max.is_finite() && max > 0.0 {
        max
    } else {
        1.0
    };
    let raw = max / target;
    let magnitude = 10f64.powf(raw.log10().floor());
    let step = [1.0, 2.0, 2.5, 5.0, 10.0]
        .iter()
        .map(|m| m * magnitude)
        .find(|s| *s >= raw - 1e-12)
        .unwrap_or(10.0 * magnitude);
    let count = (max / step - 1e-9).ceil().max(1.0) as usize;
    (step, (0..=count).map(|i| i as f64 * step).collect())
}

/// Candidate label spacings in seconds.
const LABEL_STEPS: [i64; 16] = [
    60, 120, 300, 600, 900, 1800, 3600, 7200, 10_800, 21_600, 43_200, 86_400, 172_800, 604_800,
    1_209_600, 2_592_000,
];

/// Bars that get an x-axis label: evenly spaced at a round local time, at
/// most `max_labels` of them.
pub fn x_label_indices(
    starts: &[Timestamp],
    resolution: Resolution,
    max_labels: usize,
) -> Vec<usize> {
    if starts.is_empty() || max_labels == 0 {
        return Vec::new();
    }
    let bucket = resolution.nominal_seconds();
    let span = bucket * starts.len() as i64;
    let spacing = LABEL_STEPS
        .iter()
        .copied()
        .filter(|s| *s >= bucket && s % bucket == 0)
        .find(|s| span / s <= max_labels as i64)
        .unwrap_or(*LABEL_STEPS.last().unwrap());
    let every = (spacing / 86_400).max(1) as usize;
    if resolution == Resolution::Day {
        // Count from the last bar so today is always labelled.
        let last = starts.len() - 1;
        return (0..starts.len())
            .filter(|i| (last - i) % every == 0)
            .collect();
    }
    if spacing >= 86_400 {
        // Sub-day buckets over several days: label local midnights.
        let midnights: Vec<usize> = starts
            .iter()
            .enumerate()
            .filter(|(_, s)| s.with_timezone(&Local).num_seconds_from_midnight() == 0)
            .map(|(i, _)| i)
            .collect();
        let count = midnights.len();
        return midnights
            .into_iter()
            .enumerate()
            .filter(|(n, _)| (count - 1 - n) % every == 0)
            .map(|(_, i)| i)
            .collect();
    }
    starts
        .iter()
        .enumerate()
        .filter(|(_, s)| {
            let local: DateTime<Local> = s.with_timezone(&Local);
            let secs = local.num_seconds_from_midnight() as i64;
            secs % spacing == 0
        })
        .map(|(i, _)| i)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::RemoteTimelinePoint;
    use chrono::{Duration, TimeZone, Utc};

    fn account(id: &str) -> RemoteAccount {
        RemoteAccount {
            id: id.into(),
            name: id.to_uppercase(),
            ..Default::default()
        }
    }

    fn timeline() -> RemoteTimeline {
        let t0 = Utc.with_ymd_and_hms(2026, 10, 19, 0, 0, 0).unwrap();
        let p = |h: i64, a: &str, cost: f64, base: Option<f64>| RemoteTimelinePoint {
            period: t0 + Duration::hours(h),
            account_id: a.into(),
            cost_usd: cost,
            tokens: (cost * 1000.0) as i64,
            baseline_cost_usd: base,
        };
        RemoteTimeline {
            days: 1,
            resolution: "hour".into(),
            periods: (0..24).map(|h| t0 + Duration::hours(h)).collect(),
            points: vec![
                p(1, "a", 2.0, None),
                p(1, "b", 3.0, Some(1.0)),
                p(5, "b", 4.0, None),
                p(30, "ghost", 1.0, None),
            ],
            accounts: vec![account("a"), account("b")],
            minutes: None,
        }
    }

    #[test]
    fn zero_fills_and_stacks_baselines_first() {
        let chart = ChartData::build(&timeline());
        // 24 periods plus the stray point's period.
        assert_eq!(chart.bars.len(), 25);
        assert_eq!(
            chart.accounts.len(),
            3,
            "accounts only in points are appended"
        );
        let bar = &chart.bars[1];
        assert_eq!(bar.total, 5.0);
        assert_eq!(
            bar.segments,
            vec![
                Segment {
                    account: 1,
                    low: 0.0,
                    high: 1.0,
                    baseline: true
                },
                Segment {
                    account: 0,
                    low: 1.0,
                    high: 3.0,
                    baseline: false
                },
                Segment {
                    account: 1,
                    low: 3.0,
                    high: 5.0,
                    baseline: false
                },
            ]
        );
        assert_eq!(bar.by_account, vec![(0, 2.0), (1, 3.0)]);
        assert!(chart.bars[0].segments.is_empty());
        assert_eq!(chart.max, 5.0);
        assert_eq!(chart.total, 10.0);
        assert!(chart.has_baseline);
        assert_eq!(chart.peak().unwrap().start, chart.bars[1].start);
    }

    #[test]
    fn baseline_never_exceeds_cost() {
        let mut t = timeline();
        t.points = vec![RemoteTimelinePoint {
            period: t.periods[0],
            account_id: "a".into(),
            cost_usd: 1.0,
            tokens: 1,
            baseline_cost_usd: Some(5.0),
        }];
        let chart = ChartData::build(&t);
        assert_eq!(chart.bars[0].total, 1.0);
        assert_eq!(chart.bars[0].segments.len(), 1);
    }

    #[test]
    fn hit_testing() {
        let chart = ChartData::build(&timeline());
        assert_eq!(chart.index_at(10.0, 10.0, 250.0), Some(0));
        assert_eq!(chart.index_at(259.9, 10.0, 250.0), Some(24));
        assert_eq!(chart.index_at(9.0, 10.0, 250.0), None);
        assert_eq!(chart.index_at(260.0, 10.0, 250.0), None);
    }

    #[test]
    fn nice_tick_steps() {
        assert_eq!(nice_ticks(9.3, 4), (2.5, vec![0.0, 2.5, 5.0, 7.5, 10.0]));
        assert_eq!(nice_ticks(100.0, 4).0, 25.0);
        assert_eq!(nice_ticks(0.0, 4).1.last().copied(), Some(1.0));
        let (step, ticks) = nice_ticks(0.042, 4);
        assert!((step - 0.02).abs() < 1e-12);
        assert!(*ticks.last().unwrap() >= 0.042);
        for max in [0.3, 7.0, 13.0, 999.0, 12345.0] {
            let (_, ticks) = nice_ticks(max, 4);
            assert!(
                ticks.len() <= 6 && *ticks.last().unwrap() >= max,
                "{max}: {ticks:?}"
            );
        }
    }

    #[test]
    fn x_labels_are_spaced_and_bounded() {
        let t0 = Local
            .with_ymd_and_hms(2026, 10, 19, 0, 0, 0)
            .unwrap()
            .with_timezone(&Utc);
        let hours: Vec<_> = (0..24).map(|h| t0 + Duration::hours(h)).collect();
        let picks = x_label_indices(&hours, Resolution::Hour, 8);
        assert_eq!(picks, vec![0, 3, 6, 9, 12, 15, 18, 21]);
        let minutes: Vec<_> = (0..1440).map(|m| t0 + Duration::minutes(m)).collect();
        let picks = x_label_indices(&minutes, Resolution::Minute, 6);
        assert!(picks.len() <= 6 && !picks.is_empty(), "{picks:?}");
        assert_eq!(picks[1] - picks[0], 360);
        let week: Vec<_> = (0..168).map(|h| t0 + Duration::hours(h)).collect();
        let picks = x_label_indices(&week, Resolution::Hour, 8);
        assert_eq!(picks, vec![0, 24, 48, 72, 96, 120, 144], "midnights");
        let days: Vec<_> = (0..90).map(|d| t0 + Duration::days(d)).collect();
        let picks = x_label_indices(&days, Resolution::Day, 7);
        assert!(picks.len() <= 7);
        assert_eq!(*picks.last().unwrap(), 89);
        assert!(x_label_indices(&[], Resolution::Day, 5).is_empty());
    }

    #[test]
    fn description_mentions_total_and_peak() {
        let chart = ChartData::build(&timeline());
        let text = chart.describe(false, true);
        assert!(text.contains("hourly"), "{text}");
        assert!(text.contains("Total $10.00"), "{text}");
        assert!(text.contains("with $5.00"), "{text}");
    }
}
