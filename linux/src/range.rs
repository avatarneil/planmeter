//! Report ranges and chart granularities, matching the Mac's `TimeRange`
//! (`Sources/PlanMeter/AppModel.swift`) and how the iPhone turns a range into
//! `RemoteRequest`s (`MobileModel.swift`).

use crate::models::{RemoteMethod, RemoteRequest, RemoteTimeline};
use chrono::{DateTime, Duration, Local, NaiveTime, TimeZone, Utc};

/// Bucket sizes, coarsest last.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Resolution {
    Minute,
    FiveMinutes,
    FifteenMinutes,
    Hour,
    Day,
}

impl Resolution {
    pub const ALL: [Resolution; 5] = [
        Self::Minute,
        Self::FiveMinutes,
        Self::FifteenMinutes,
        Self::Hour,
        Self::Day,
    ];

    /// The wire value used in `RemoteRequest.resolution`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Minute => "minute",
            Self::FiveMinutes => "5m",
            Self::FifteenMinutes => "15m",
            Self::Hour => "hour",
            Self::Day => "day",
        }
    }

    pub fn parse(raw: &str) -> Option<Resolution> {
        Self::ALL.into_iter().find(|r| r.as_str() == raw)
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Minute => "1 min",
            Self::FiveMinutes => "5 min",
            Self::FifteenMinutes => "15 min",
            Self::Hour => "1 hour",
            Self::Day => "1 day",
        }
    }

    /// Fixed bucket length; `None` for local calendar days.
    pub fn step_seconds(self) -> Option<i64> {
        RemoteTimeline::step_seconds(self.as_str())
    }

    /// Nominal length, counting a day as 24 hours.
    pub fn nominal_seconds(self) -> i64 {
        self.step_seconds().unwrap_or(86_400)
    }
}

/// The dashboard range; ids are the Mac's `TimeRange.id`, which also key the
/// host's spend thresholds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TimeRange {
    LastHour,
    Today,
    Day,
    Week,
    Month,
    Quarter,
}

impl TimeRange {
    pub const ALL: [TimeRange; 6] = [
        Self::LastHour,
        Self::Today,
        Self::Day,
        Self::Week,
        Self::Month,
        Self::Quarter,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Self::LastHour => "lastHour",
            Self::Today => "today",
            Self::Day => "day",
            Self::Week => "week",
            Self::Month => "month",
            Self::Quarter => "quarter",
        }
    }

    pub fn from_id(id: &str) -> Option<TimeRange> {
        Self::ALL.into_iter().find(|r| r.id() == id)
    }

    /// Compact label for the range button.
    pub fn short_label(self) -> &'static str {
        match self {
            Self::LastHour => "1 hour",
            Self::Today => "Today",
            Self::Day => "24 hours",
            Self::Week => "7 days",
            Self::Month => "30 days",
            Self::Quarter => "90 days",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::LastHour => "Last Hour",
            Self::Today => "Today",
            Self::Day => "Last 24 Hours",
            Self::Week => "Last 7 Days",
            Self::Month => "Last 30 Days",
            Self::Quarter => "Last 90 Days",
        }
    }

    /// Lowercase phrase for sentences ("spend for the last 7 days").
    pub fn phrase(self) -> &'static str {
        match self {
            Self::LastHour => "the last hour",
            Self::Today => "today",
            Self::Day => "the last 24 hours",
            Self::Week => "the last 7 days",
            Self::Month => "the last 30 days",
            Self::Quarter => "the last 90 days",
        }
    }

    /// Chart granularities that keep each range readable (at most ~1,500 bars).
    pub fn granularities(self) -> &'static [Resolution] {
        use Resolution::*;
        match self {
            Self::LastHour => &[Minute, FiveMinutes],
            Self::Today | Self::Day => &[Minute, FiveMinutes, FifteenMinutes, Hour],
            Self::Week => &[FifteenMinutes, Hour, Day],
            Self::Month => &[Hour, Day],
            Self::Quarter => &[Day],
        }
    }

    pub fn default_granularity(self) -> Resolution {
        match self {
            Self::LastHour => Resolution::Minute,
            Self::Today | Self::Day => Resolution::Hour,
            _ => Resolution::Day,
        }
    }

    /// A saved choice if this range offers it, otherwise the default.
    pub fn resolve_granularity(self, saved: Option<Resolution>) -> Resolution {
        saved
            .filter(|g| self.granularities().contains(g))
            .unwrap_or(self.default_granularity())
    }

    pub fn day_count(self) -> i64 {
        match self {
            Self::LastHour | Self::Today | Self::Day => 1,
            Self::Week => 7,
            Self::Month => 30,
            Self::Quarter => 90,
        }
    }

    /// Whether the chart spans several calendar days (labels add a weekday).
    pub fn is_multi_day(self) -> bool {
        self.day_count() > 1
    }

    /// The sub-day window in minutes sent as `RemoteRequest.minutes`. The host
    /// ends sub-day windows at the next five-minute boundary, so Today asks for
    /// exactly the minutes from local midnight to that boundary.
    pub fn minutes(self, now: DateTime<Local>) -> Option<i64> {
        match self {
            Self::LastHour => Some(60),
            Self::Today => {
                let end = next_five_minute_boundary(now.with_timezone(&Utc));
                let midnight = local_midnight(now);
                Some(((end - midnight.with_timezone(&Utc)).num_minutes()).clamp(5, 1440))
            }
            _ => None,
        }
    }

    /// The request for one report method over this range.
    pub fn request(
        self,
        method: RemoteMethod,
        granularity: Option<Resolution>,
        now: DateTime<Local>,
    ) -> RemoteRequest {
        let mut request = RemoteRequest::new(method);
        match method {
            RemoteMethod::Limits | RemoteMethod::Accounts => return request,
            _ => {}
        }
        request.days = Some(self.day_count());
        request.minutes = self.minutes(now);
        if method == RemoteMethod::Timeline {
            request.resolution = Some(self.resolve_granularity(granularity).as_str().to_string());
        }
        request
    }

    /// `[from, to)` as the host computes it for this range, for chart domains
    /// and bar-count checks.
    pub fn window(self, now: DateTime<Local>) -> (DateTime<Utc>, DateTime<Utc>) {
        let utc = now.with_timezone(&Utc);
        match self {
            Self::LastHour | Self::Today => {
                let end = next_five_minute_boundary(utc);
                let minutes = self.minutes(now).unwrap_or(60);
                (end - Duration::minutes(minutes), end)
            }
            Self::Day => {
                let hour = DateTime::from_timestamp(utc.timestamp().div_euclid(3600) * 3600, 0)
                    .unwrap_or(utc);
                (hour - Duration::hours(23), hour + Duration::hours(1))
            }
            _ => {
                let today = local_midnight(now);
                let to = add_local_days(today, 1);
                let from = add_local_days(today, -(self.day_count() - 1));
                (from.with_timezone(&Utc), to.with_timezone(&Utc))
            }
        }
    }

    /// How many bars a granularity would draw over this range.
    pub fn bar_count(self, granularity: Resolution, now: DateTime<Local>) -> i64 {
        let (from, to) = self.window(now);
        let span = (to - from).num_seconds();
        let step = granularity.nominal_seconds();
        (span + step - 1) / step
    }
}

pub fn next_five_minute_boundary(now: DateTime<Utc>) -> DateTime<Utc> {
    let end = (now.timestamp().div_euclid(300) + 1) * 300;
    DateTime::from_timestamp(end, 0).unwrap_or(now)
}

pub fn local_midnight(now: DateTime<Local>) -> DateTime<Local> {
    let naive = now.date_naive().and_time(NaiveTime::MIN);
    Local.from_local_datetime(&naive).earliest().unwrap_or(now)
}

fn add_local_days(day: DateTime<Local>, days: i64) -> DateTime<Local> {
    let date = day.date_naive() + Duration::days(days);
    Local
        .from_local_datetime(&date.and_time(NaiveTime::MIN))
        .earliest()
        .unwrap_or(day + Duration::days(days))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(h: u32, m: u32) -> DateTime<Local> {
        Local
            .with_ymd_and_hms(2026, 10, 19, h, m, 30)
            .earliest()
            .unwrap()
    }

    #[test]
    fn ids_match_the_mac() {
        let ids: Vec<_> = TimeRange::ALL.iter().map(|r| r.id()).collect();
        assert_eq!(
            ids,
            ["lastHour", "today", "day", "week", "month", "quarter"]
        );
        for r in TimeRange::ALL {
            assert_eq!(TimeRange::from_id(r.id()), Some(r));
        }
    }

    #[test]
    fn every_granularity_stays_under_1500_bars() {
        for hour in [0, 9, 23] {
            let now = at(hour, 58);
            for range in TimeRange::ALL {
                for g in range.granularities() {
                    let bars = range.bar_count(*g, now);
                    assert!(bars <= 1500, "{range:?} {g:?} draws {bars} bars");
                    assert!(bars >= 1);
                }
                assert!(range.granularities().contains(&range.default_granularity()));
            }
        }
    }

    #[test]
    fn today_asks_for_minutes_since_midnight() {
        assert_eq!(TimeRange::Today.minutes(at(0, 1)), Some(5));
        assert_eq!(TimeRange::Today.minutes(at(10, 2)), Some(605));
        assert_eq!(TimeRange::Today.minutes(at(23, 58)), Some(1440));
        let (from, _) = TimeRange::Today.window(at(10, 2));
        assert_eq!(from, local_midnight(at(10, 2)).with_timezone(&Utc));
    }

    #[test]
    fn requests_match_the_phone() {
        let now = at(10, 2);
        let s = TimeRange::Week.request(RemoteMethod::Summary, None, now);
        assert_eq!(
            (s.days, s.minutes, s.resolution.as_deref()),
            (Some(7), None, None)
        );
        let t = TimeRange::LastHour.request(RemoteMethod::Timeline, Some(Resolution::Day), now);
        assert_eq!(
            (t.days, t.minutes, t.resolution.as_deref()),
            (Some(1), Some(60), Some("minute"))
        );
        let d = TimeRange::Day.request(
            RemoteMethod::Timeline,
            Some(Resolution::FifteenMinutes),
            now,
        );
        assert_eq!(
            (d.days, d.minutes, d.resolution.as_deref()),
            (Some(1), None, Some("15m"))
        );
        let l = TimeRange::Month.request(RemoteMethod::Limits, None, now);
        assert_eq!(l, RemoteRequest::new(RemoteMethod::Limits));
    }

    #[test]
    fn rolling_day_is_hour_aligned() {
        let (from, to) = TimeRange::Day.window(at(10, 2));
        assert_eq!((to - from).num_hours(), 24);
        assert_eq!(from.timestamp() % 3600, 0);
    }
}
