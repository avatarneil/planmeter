//! A stand-in for `planmeterd` during development and tests: the control API
//! from `docs/cross-platform.md` over a Unix socket, answering with
//! deterministic synthetic usage for five accounts, mutable settings, and
//! remote access with pairing invites and device revoke.

use crate::http;
use crate::models::*;
use chrono::{DateTime, Datelike, Duration, Local, NaiveTime, TimeZone, Timelike, Utc, Weekday};
use serde::Serialize;
use std::collections::BTreeMap;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};

const MAX_DAYS: i64 = 365;

#[derive(Debug, Clone, Copy, PartialEq)]
enum Profile {
    /// Weekday office hours.
    Work,
    /// Evenings and weekends.
    Evening,
    /// A little, any time.
    Anytime,
}

impl Profile {
    fn weight(self, hour: u32, weekday: Weekday) -> f64 {
        let weekend = matches!(weekday, Weekday::Sat | Weekday::Sun);
        match self {
            Profile::Work if weekend => 0.06,
            Profile::Work => match hour {
                9..=11 | 13..=17 => 1.0,
                12 | 18 => 0.6,
                8 | 19..=21 => 0.3,
                _ => 0.02,
            },
            Profile::Evening if weekend => match hour {
                10..=23 => 0.7,
                _ => 0.05,
            },
            Profile::Evening => match hour {
                19..=23 => 1.0,
                7 | 8 => 0.35,
                12 => 0.4,
                _ => 0.04,
            },
            Profile::Anytime => 0.25,
        }
    }

    /// Mean active minutes per day, so `daily_cost` is the average spend.
    fn active_minutes_per_day(self) -> f64 {
        let days = [
            Weekday::Mon,
            Weekday::Tue,
            Weekday::Wed,
            Weekday::Thu,
            Weekday::Fri,
            Weekday::Sat,
            Weekday::Sun,
        ];
        let total: f64 = days
            .iter()
            .flat_map(|d| (0..24).map(move |h| self.weight(h, *d)))
            .sum();
        total / 7.0 * 60.0 * ACTIVITY
    }
}

/// Chance a minute is active at weight 1.
const ACTIVITY: f64 = 0.35;

#[derive(Debug, Clone)]
struct MockAccount {
    account: RemoteAccount,
    suggested: PlanGroup,
    daily_cost: f64,
    profile: Profile,
    /// Model name, share of tokens, priced.
    models: &'static [(&'static str, f64, bool)],
    /// Untimed workspace credits per working hour.
    baseline_per_hour: f64,
    /// Extra activity right around launch, so short ranges have data.
    boost: f64,
}

#[derive(Debug, Clone, Copy, Default)]
struct Usage {
    cost: f64,
    baseline: f64,
    tokens: i64,
    input: i64,
    cached: i64,
    output: i64,
    savings: f64,
}

impl Usage {
    fn add(&mut self, o: &Usage) {
        self.cost += o.cost;
        self.baseline += o.baseline;
        self.tokens += o.tokens;
        self.input += o.input;
        self.cached += o.cached;
        self.output += o.output;
        self.savings += o.savings;
    }

    fn totals(&self, sessions: i64) -> RemoteTotals {
        RemoteTotals {
            cost_usd: self.cost,
            tokens: self.tokens,
            input_tokens: self.input,
            cached_input_tokens: self.cached,
            output_tokens: self.output,
            sessions,
            cache_savings_usd: self.savings,
        }
    }
}

/// Local calendar facts for one UTC hour.
#[derive(Debug, Clone, Copy)]
struct HourContext {
    hour: u32,
    weekday: Weekday,
    day_start: i64,
}

fn splitmix(mut x: u64) -> u64 {
    x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    x = (x ^ (x >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    x ^ (x >> 31)
}

fn unit(seed: u64) -> f64 {
    (splitmix(seed) >> 11) as f64 / (1u64 << 53) as f64
}

fn ts(secs: i64) -> Timestamp {
    DateTime::from_timestamp(secs, 0).unwrap_or_default()
}

fn local_day_start(secs: i64) -> i64 {
    let local = ts(secs).with_timezone(&Local);
    let midnight = local.date_naive().and_time(NaiveTime::MIN);
    Local
        .from_local_datetime(&midnight)
        .earliest()
        .map(|d| d.timestamp())
        .unwrap_or(secs - secs.rem_euclid(86_400))
}

fn next_local_day(day_start: i64) -> i64 {
    let local = ts(day_start).with_timezone(&Local);
    let next = (local.date_naive() + Duration::days(1)).and_time(NaiveTime::MIN);
    Local
        .from_local_datetime(&next)
        .earliest()
        .map(|d| d.timestamp())
        .unwrap_or(day_start + 86_400)
}

pub fn base64(data: &[u8], url_safe: bool) -> String {
    let table: &[u8; 64] = if url_safe {
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    } else {
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    };
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let n = (chunk[0] as u32) << 16
            | (*chunk.get(1).unwrap_or(&0) as u32) << 8
            | *chunk.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(table[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else if !url_safe {
                out.push('=');
            }
        }
    }
    out
}

fn bytes(seed: u64, len: usize) -> Vec<u8> {
    (0..len)
        .map(|i| (splitmix(seed.wrapping_add(i as u64)) & 0xff) as u8)
        .collect()
}

/// The mock daemon's state.
pub struct MockDaemon {
    accounts: Vec<MockAccount>,
    pub settings: HostSettings,
    pub remote: RemoteStatus,
    started_at: i64,
    last_scan: i64,
    server_name: String,
    seed: u64,
    /// Pretend a device scanned the invite this many seconds after it was issued.
    pub auto_pair_after: Option<i64>,
    invite_issued: Option<i64>,
    /// When set, `/v1/rpc` answers with this error.
    pub rpc_error: Option<String>,
}

impl MockDaemon {
    pub fn new(now: DateTime<Utc>) -> Self {
        let now_s = now.timestamp();
        let account = |id: &str,
                       name: &str,
                       provider: &str,
                       provider_name: &str,
                       email: Option<&str>,
                       plan: Option<&str>,
                       accent: Option<&str>| RemoteAccount {
            id: id.into(),
            name: name.into(),
            provider: provider.into(),
            provider_name: provider_name.into(),
            group: String::new(),
            email: email.map(Into::into),
            plan: plan.map(Into::into),
            accent_color_hex: accent.map(Into::into),
        };
        let accounts = vec![
            MockAccount {
                account: account(
                    "codex:plan:personal",
                    "Codex",
                    "codex",
                    "Codex",
                    Some("neil@example.com"),
                    Some("Plus"),
                    Some("#10a37f"),
                ),
                suggested: PlanGroup::Personal,
                daily_cost: 4.2,
                profile: Profile::Evening,
                models: &[("gpt-5.5-codex", 0.78, true), ("gpt-5.4-mini", 0.22, true)],
                baseline_per_hour: 0.0,
                boost: 0.5,
            },
            MockAccount {
                account: account(
                    "claude:personal",
                    "Claude",
                    "claude",
                    "Claude Code",
                    Some("neil@example.com"),
                    Some("Max"),
                    Some("#d97757"),
                ),
                suggested: PlanGroup::Personal,
                daily_cost: 9.5,
                profile: Profile::Evening,
                models: &[
                    ("claude-opus-4-5", 0.55, true),
                    ("claude-sonnet-4-5", 0.38, true),
                    ("claude-haiku-4-5", 0.07, true),
                ],
                baseline_per_hour: 0.0,
                boost: 0.0,
            },
            MockAccount {
                account: account(
                    "codex:plan:work",
                    "Codex Work",
                    "codex",
                    "Codex",
                    Some("neil@acme.dev"),
                    Some("Business"),
                    Some("#4f7cff"),
                ),
                suggested: PlanGroup::Work,
                daily_cost: 22.0,
                profile: Profile::Work,
                models: &[
                    ("gpt-5.5-codex", 0.84, true),
                    ("gpt-5.5-codex-max", 0.16, true),
                ],
                baseline_per_hour: 0.55,
                boost: 0.9,
            },
            MockAccount {
                account: account(
                    "claude:work",
                    "Claude Work",
                    "claude",
                    "Claude Code",
                    Some("neil@acme.dev"),
                    Some("Team"),
                    Some("#c06ad9"),
                ),
                suggested: PlanGroup::Work,
                daily_cost: 31.0,
                profile: Profile::Work,
                models: &[
                    ("claude-sonnet-4-5", 0.71, true),
                    ("claude-opus-4-5", 0.29, true),
                ],
                baseline_per_hour: 0.0,
                boost: 0.4,
            },
            MockAccount {
                account: account(
                    "opencode", "OpenCode", "opencode", "OpenCode", None, None, None,
                ),
                suggested: PlanGroup::Other,
                daily_cost: 0.9,
                profile: Profile::Anytime,
                models: &[
                    ("openrouter/qwen3-coder", 0.6, true),
                    ("local/llama-4-scout", 0.4, false),
                ],
                baseline_per_hour: 0.0,
                boost: 0.0,
            },
        ];
        let mut thresholds = BTreeMap::new();
        thresholds.insert("today".to_string(), SpendThreshold::new(60.0, 80.0));
        thresholds.insert("week".to_string(), SpendThreshold::new(400.0, 75.0));
        thresholds.insert("month".to_string(), SpendThreshold::new(1500.0, 85.0));
        let settings = HostSettings {
            group_overrides: BTreeMap::new(),
            spend_groups: vec!["personal".into(), "work".into()],
            spend_thresholds: thresholds,
        };
        let devices = vec![
            PairedDevice {
                id: "Xk3fQ9vR2mLp8sT1uW4yZa".into(),
                name: "Neil’s iPhone".into(),
                platform: "iPhone · iOS 26.1".into(),
                public_key: base64(&bytes(1, 65), false),
                paired_at: ts(now_s - 41 * 86_400),
                last_seen_at: Some(ts(now_s - 180)),
                request_count: 12_840,
            },
            PairedDevice {
                id: "pQ7nB2cD5eF8gH1jK4mN6r".into(),
                name: "Pixel 9 Pro".into(),
                platform: "Android 16".into(),
                public_key: base64(&bytes(2, 65), false),
                paired_at: ts(now_s - 6 * 86_400),
                last_seen_at: Some(ts(now_s - 2 * 3600)),
                request_count: 1_204,
            },
            PairedDevice {
                id: "wE9rT6yU3iO0pA7sD4fG1h".into(),
                name: "Safari".into(),
                platform: "web".into(),
                public_key: base64(&bytes(3, 65), false),
                paired_at: ts(now_s - 2 * 86_400),
                last_seen_at: None,
                request_count: 0,
            },
        ];
        let mut daemon = MockDaemon {
            accounts,
            settings,
            remote: RemoteStatus::default(),
            started_at: now_s,
            last_scan: now_s,
            server_name: "devbox".into(),
            seed: 0x504c_414e,
            auto_pair_after: None,
            invite_issued: None,
            rpc_error: None,
        };
        daemon.remote = RemoteStatus {
            enabled: true,
            port: 7787,
            status: String::new(),
            message: None,
            bind_addresses: vec![],
            tailscale: TailscaleStatus {
                available: true,
                address: Some("100.101.102.103".into()),
                dns_name: Some("devbox.tail1234.ts.net".into()),
            },
            https: HttpsStatus {
                enabled: true,
                active: true,
                url: Some("https://devbox.tail1234.ts.net/".into()),
                certificate_status: Some("valid".into()),
            },
            devices,
            invite: None,
            log: vec![],
        };
        daemon.apply_remote_state(now_s);
        daemon.log(now_s - 3 * 3600, "100.101.102.103: listening");
        daemon.log(
            now_s - 3 * 3600 + 2,
            "tailscale serve on: https://devbox.tail1234.ts.net/",
        );
        daemon.log(now_s - 180, "rpc summary from Neil’s iPhone");
        daemon
    }

    fn log(&mut self, at: i64, line: &str) {
        let stamp = ts(at).with_timezone(&Local).format("%H:%M:%S");
        self.remote.log.insert(0, format!("{stamp}  {line}"));
        self.remote.log.truncate(50);
    }

    fn apply_remote_state(&mut self, now: i64) {
        let address = self.remote.tailscale.address.clone().unwrap_or_default();
        if self.remote.enabled {
            self.remote.bind_addresses = vec![address.clone()];
            self.remote.status = "listening".into();
        } else {
            self.remote.bind_addresses.clear();
            self.remote.status = "off".into();
            self.remote.invite = None;
        }
        let dns = self.remote.tailscale.dns_name.clone().unwrap_or_default();
        self.remote.https.active = self.remote.enabled && self.remote.https.enabled;
        self.remote.https.url = self.remote.https.active.then(|| format!("https://{dns}/"));
        if let Some(invite) = &self.remote.invite {
            if invite.expires_at.timestamp() <= now {
                self.remote.invite = None;
                self.invite_issued = None;
            }
        }
    }

    fn effective_group(&self, account: &MockAccount) -> PlanGroup {
        self.settings
            .group_overrides
            .get(&account.account.id)
            .copied()
            .unwrap_or(account.suggested)
    }

    fn remote_account(&self, i: usize) -> RemoteAccount {
        let mut a = self.accounts[i].account.clone();
        a.group = self.effective_group(&self.accounts[i]).id().to_string();
        a
    }

    fn minute_usage(&self, index: usize, minute: i64, ctx: &HourContext) -> Usage {
        let account = &self.accounts[index];
        let mut weight = account.profile.weight(ctx.hour, ctx.weekday);
        if account.boost > 0.0
            && minute >= self.started_at - 80 * 60
            && minute <= self.started_at + 3600
        {
            weight += account.boost;
        }
        let seed = self.seed ^ ((index as u64) << 56) ^ (minute as u64 / 60);
        let mut usage = Usage::default();
        if unit(seed) < (weight * ACTIVITY).min(0.95) {
            let intensity = 0.35 + 1.3 * unit(seed ^ 0xA5A5);
            let cost = account.daily_cost / account.profile.active_minutes_per_day() * intensity;
            let tokens = (cost * 410_000.0 * (0.8 + 0.4 * unit(seed ^ 0x5A5A))) as i64;
            usage.cost = cost;
            usage.tokens = tokens;
            usage.input = tokens * 92 / 100;
            usage.cached = usage.input * 71 / 100;
            usage.output = tokens - usage.input;
            usage.savings = usage.cached as f64 * 1.1e-6;
        }
        let reported_until = self.started_at - 3 * 3600;
        let working =
            !matches!(ctx.weekday, Weekday::Sat | Weekday::Sun) && (8..20).contains(&ctx.hour);
        if account.baseline_per_hour > 0.0 && working && minute < reported_until {
            let b = account.baseline_per_hour / 60.0;
            usage.baseline = b;
            usage.cost += b;
        }
        usage
    }

    /// Calls `f(account, minute, usage, hour)` for every active minute in `[from, to)`.
    fn each_minute(&self, from: i64, to: i64, mut f: impl FnMut(usize, i64, &Usage, &HourContext)) {
        let mut hour = from.div_euclid(3600) * 3600;
        while hour < to {
            let local = ts(hour).with_timezone(&Local);
            let ctx = HourContext {
                hour: local.hour(),
                weekday: local.weekday(),
                day_start: local_day_start(hour),
            };
            let start = hour.max(from.div_euclid(60) * 60);
            let end = (hour + 3600).min(to);
            let mut minute = start;
            while minute < end {
                for index in 0..self.accounts.len() {
                    let usage = self.minute_usage(index, minute, &ctx);
                    if usage.cost > 0.0 || usage.tokens > 0 {
                        f(index, minute, &usage, &ctx);
                    }
                }
                minute += 60;
            }
            hour += 3600;
        }
    }

    /// Per-account usage and session counts (active half hours) over a window.
    fn usage_by_account(&self, from: i64, to: i64) -> Vec<(Usage, i64)> {
        let mut out = vec![(Usage::default(), 0i64); self.accounts.len()];
        let mut last_block = vec![i64::MIN; self.accounts.len()];
        self.each_minute(from, to, |i, minute, usage, _| {
            out[i].0.add(usage);
            if usage.tokens > 0 {
                let block = minute.div_euclid(1800);
                if block != last_block[i] {
                    last_block[i] = block;
                    out[i].1 += 1;
                }
            }
        });
        for (u, sessions) in &mut out {
            *sessions = (*sessions + 1) / 2;
            if u.tokens == 0 {
                *sessions = 0;
            }
        }
        out
    }

    /// The host's window for a request: sub-day minutes, rolling 24 hours, or local days.
    fn window(request: &RemoteRequest, now: i64) -> (i64, i64, &'static str) {
        let days = request.days.unwrap_or(30).clamp(1, MAX_DAYS);
        if let Some(minutes) = request.minutes {
            let minutes = minutes.clamp(5, 1440);
            let end = (now.div_euclid(300) + 1) * 300;
            return (end - minutes * 60, end, "hour");
        }
        if days == 1 {
            let hour = now.div_euclid(3600) * 3600;
            return (hour - 23 * 3600, hour + 3600, "hour");
        }
        let today = local_day_start(now);
        let to = next_local_day(today);
        let mut from = today;
        for _ in 0..(days - 1) {
            from = local_day_start(from - 1);
        }
        (from, to, "day")
    }

    /// The requested resolution, coarsened to the window and ~1,500 periods.
    fn resolution(requested: &str, from: i64, to: i64, coarsest: &str) -> &'static str {
        const ORDER: [&str; 5] = ["minute", "5m", "15m", "hour", "day"];
        let position = |r: &str| {
            ORDER
                .iter()
                .position(|o| *o == r)
                .unwrap_or(ORDER.len() - 1)
        };
        let mut index = position(requested).min(position(coarsest));
        while index < ORDER.len() - 1 {
            let Some(step) = RemoteTimeline::step_seconds(ORDER[index]) else {
                break;
            };
            if (to - from) / step <= 1500 || (ORDER[index + 1] == "day" && coarsest != "day") {
                break;
            }
            index += 1;
        }
        ORDER[index]
    }

    fn periods(from: i64, to: i64, resolution: &str) -> Vec<i64> {
        let mut out = Vec::new();
        if let Some(step) = RemoteTimeline::step_seconds(resolution) {
            let mut cursor = from.div_euclid(step) * step;
            while cursor < to {
                out.push(cursor);
                cursor += step;
            }
        } else {
            let mut cursor = local_day_start(from);
            while cursor < to {
                out.push(cursor);
                cursor = next_local_day(cursor);
            }
        }
        out
    }

    pub fn summary(&self, request: &RemoteRequest, now: i64) -> RemoteSummary {
        let (from, to, _) = Self::window(request, now);
        let usage = self.usage_by_account(from, to.min(now));
        let mut groups = Vec::new();
        let mut total = RemoteTotals::default();
        for group in PlanGroup::ALL {
            let members: Vec<usize> = (0..self.accounts.len())
                .filter(|&i| self.effective_group(&self.accounts[i]) == group)
                .collect();
            if members.is_empty() {
                continue;
            }
            let mut group_totals = RemoteTotals::default();
            let mut rows: Vec<RemoteAccountUsage> = members
                .iter()
                .map(|&i| {
                    let totals = usage[i].0.totals(usage[i].1);
                    group_totals.add(&totals);
                    RemoteAccountUsage {
                        account: self.remote_account(i),
                        totals,
                    }
                })
                .collect();
            rows.sort_by(|a, b| {
                b.totals
                    .cost_usd
                    .total_cmp(&a.totals.cost_usd)
                    .then(b.totals.tokens.cmp(&a.totals.tokens))
            });
            if group == PlanGroup::Other && group_totals.tokens == 0 && group_totals.cost_usd == 0.0
            {
                continue;
            }
            total.add(&group_totals);
            groups.push(RemoteGroupUsage {
                group: group.id().into(),
                totals: group_totals,
                accounts: rows,
            });
        }
        let today_start = local_day_start(now);
        let today_cost = self
            .usage_by_account(today_start, now)
            .iter()
            .map(|(u, _)| u.cost)
            .sum();
        RemoteSummary {
            days: request.days.unwrap_or(30).clamp(1, MAX_DAYS),
            from: ts(from),
            to: ts(to),
            groups,
            total,
            today_cost_usd: today_cost,
            generated_at: ts(self.last_scan),
            server_name: self.server_name.clone(),
            pricing_source: "litellm".into(),
            uses_provider_dates: None,
            minutes: request.minutes.map(|m| m.clamp(5, 1440)),
        }
    }

    pub fn timeline(&self, request: &RemoteRequest, now: i64) -> RemoteTimeline {
        let (from, to, coarsest) = Self::window(request, now);
        let requested = request.resolution.as_deref().unwrap_or("day");
        let resolution = Self::resolution(requested, from, to, coarsest);
        let step = RemoteTimeline::step_seconds(resolution);
        let mut cells: BTreeMap<(i64, usize), Usage> = BTreeMap::new();
        self.each_minute(from, to.min(now), |i, minute, usage, ctx| {
            let period = match step {
                Some(step) => minute.div_euclid(step) * step,
                None => ctx.day_start,
            };
            cells.entry((period, i)).or_default().add(usage);
        });
        let mut used = vec![false; self.accounts.len()];
        let points = cells
            .into_iter()
            .map(|((period, i), u)| {
                used[i] = true;
                RemoteTimelinePoint {
                    period: ts(period),
                    account_id: self.accounts[i].account.id.clone(),
                    cost_usd: u.cost,
                    tokens: u.tokens,
                    baseline_cost_usd: (u.baseline > 0.0).then_some(u.baseline),
                }
            })
            .collect();
        RemoteTimeline {
            days: request.days.unwrap_or(30).clamp(1, MAX_DAYS),
            resolution: resolution.into(),
            periods: Self::periods(from, to, resolution)
                .into_iter()
                .map(ts)
                .collect(),
            points,
            accounts: (0..self.accounts.len())
                .filter(|&i| used[i])
                .map(|i| self.remote_account(i))
                .collect(),
            minutes: request.minutes.map(|m| m.clamp(5, 1440)),
        }
    }

    pub fn models(&self, request: &RemoteRequest, now: i64) -> Vec<RemoteModelRow> {
        let (from, to, _) = Self::window(request, now);
        let usage = self.usage_by_account(from, to.min(now));
        let filter = request.account.as_deref().map(str::to_lowercase);
        let mut rows = Vec::new();
        for (i, (u, sessions)) in usage.iter().enumerate() {
            let account = self.remote_account(i);
            if let Some(f) = &filter {
                if !(account.id.to_lowercase().contains(f)
                    || account.name.to_lowercase().contains(f)
                    || account.provider == *f)
                {
                    continue;
                }
            }
            if u.tokens == 0 {
                continue;
            }
            let priced_share: f64 = self.accounts[i]
                .models
                .iter()
                .filter(|m| m.2)
                .map(|m| m.1)
                .sum();
            for (name, share, priced) in self.accounts[i].models {
                let cost = if *priced {
                    u.cost * share / priced_share
                } else {
                    0.0
                };
                let part = |v: i64| (v as f64 * share) as i64;
                rows.push(RemoteModelRow {
                    account_id: account.id.clone(),
                    account_name: account.name.clone(),
                    group: account.group.clone(),
                    provider: account.provider.clone(),
                    model: name.to_string(),
                    totals: RemoteTotals {
                        cost_usd: cost,
                        tokens: part(u.tokens),
                        input_tokens: part(u.input),
                        cached_input_tokens: part(u.cached),
                        output_tokens: part(u.output),
                        sessions: ((*sessions as f64) * share).ceil() as i64,
                        cache_savings_usd: u.savings * share,
                    },
                    priced: *priced,
                });
            }
        }
        rows.sort_by(|a, b| {
            b.totals
                .cost_usd
                .total_cmp(&a.totals.cost_usd)
                .then(b.totals.tokens.cmp(&a.totals.tokens))
        });
        rows
    }

    pub fn limits(&self) -> RemoteLimits {
        let s = self.started_at;
        let window = |label: &str, used: f64, minutes: i64, resets_in: i64| RemoteLimitWindow {
            label: label.into(),
            used_percent: used,
            window_minutes: minutes,
            resets_at: ts(s + resets_in),
        };
        let mut accounts = Vec::new();
        for (i, a) in self.accounts.iter().enumerate() {
            if a.account.provider != "codex" {
                continue;
            }
            let entry = if a.account.id.ends_with("work") {
                RemoteAccountLimits {
                    account: self.remote_account(i),
                    windows: vec![
                        window("5-hour", 76.0, 300, 47 * 60),
                        window("Weekly", 93.0, 10_080, 26 * 3600),
                    ],
                    note: None,
                    as_of: Some(ts(s - 4 * 60)),
                }
            } else {
                RemoteAccountLimits {
                    account: self.remote_account(i),
                    windows: vec![
                        window("5-hour", 42.0, 300, 2 * 3600 + 13 * 60),
                        window("Weekly", 61.0, 10_080, 3 * 86_400 + 4 * 3600),
                    ],
                    note: None,
                    as_of: Some(ts(s - 38 * 60)),
                }
            };
            accounts.push(entry);
        }
        RemoteLimits { accounts, note: "Codex windows come from the last session each account ran. Claude Code does not store limits locally.".into() }
    }

    pub fn accounts_reply(&self) -> RemoteAccounts {
        let source = |provider: &str, path: &str, status: &str| RemoteSource {
            provider: provider.into(),
            path: path.into(),
            status: status.into(),
        };
        RemoteAccounts {
            accounts: (0..self.accounts.len())
                .map(|i| self.remote_account(i))
                .collect(),
            sources: vec![
                source("codex", "/home/neil/.codex/sessions", "ok"),
                source("codex", "/home/neil/.codex-work/sessions", "ok"),
                source("claude", "/home/neil/.claude/projects", "ok"),
                source("claude", "/home/neil/.claude-work/projects", "partial"),
                source(
                    "opencode",
                    "/home/neil/.local/share/opencode/opencode.db",
                    "ok",
                ),
                source("grok", "/home/neil/.grok/sessions", "missing"),
            ],
            scanned_at: Some(ts(self.last_scan)),
        }
    }

    pub fn status(&self) -> DaemonStatus {
        DaemonStatus {
            api_version: 1,
            version: "0.3.6".into(),
            server_name: self.server_name.clone(),
            is_scanning: false,
            last_scan_at: Some(ts(self.last_scan)),
            last_error: None,
            pricing_source: Some("litellm".into()),
            pricing_error: None,
            account_count: self.accounts.len() as i64,
        }
    }

    pub fn reply(&self, request: &RemoteRequest, now: i64) -> RemoteReply {
        if let Some(error) = &self.rpc_error {
            return RemoteReply {
                error: Some(error.clone()),
                ..Default::default()
            };
        }
        match request.method {
            RemoteMethod::Summary => RemoteReply {
                summary: Some(self.summary(request, now)),
                ..Default::default()
            },
            RemoteMethod::Timeline => RemoteReply {
                timeline: Some(self.timeline(request, now)),
                ..Default::default()
            },
            RemoteMethod::Models => RemoteReply {
                models: Some(self.models(request, now)),
                ..Default::default()
            },
            RemoteMethod::Limits => RemoteReply {
                limits: Some(self.limits()),
                ..Default::default()
            },
            RemoteMethod::Accounts => RemoteReply {
                accounts: Some(self.accounts_reply()),
                ..Default::default()
            },
        }
    }

    fn new_invite(&mut self, now: i64) -> Result<(), (u16, String)> {
        if !self.remote.is_listening() {
            return Err((409, "Turn on remote access first.".into()));
        }
        let host = self
            .remote
            .tailscale
            .dns_name
            .clone()
            .unwrap_or_else(|| self.remote.bind_addresses[0].clone());
        let seed = splitmix(now as u64 ^ self.seed);
        let key = {
            let mut k = vec![4u8];
            k.extend(bytes(seed, 64));
            base64(&k, true)
        };
        let token = base64(&bytes(seed ^ 0xFEED, 32), true);
        let expires = now + 300;
        let name = &self.server_name;
        let port = self.remote.port;
        let query = |h: &str| {
            format!("planmeter://pair?h={h}&p={port}&n={name}&k={key}&t={token}&e={expires}")
        };
        let web_url = self
            .remote
            .https
            .url
            .clone()
            .filter(|_| self.remote.https.active)
            .map(|origin| format!("{origin}#k={key}&t={token}&e={expires}&n={name}"));
        self.remote.invite = Some(RemoteInvite {
            url: query(&host),
            local_url: Some(query("127.0.0.1")),
            web_url,
            web_code: Some(format!("{:08}", splitmix(seed ^ 0xC0DE) % 100_000_000)),
            expires_at: ts(expires),
        });
        self.invite_issued = Some(now);
        self.log(now, "pairing code issued, expires in 5 min");
        Ok(())
    }

    /// Simulates a phone completing pairing, for `--auto-pair`.
    fn maybe_auto_pair(&mut self, now: i64) {
        let (Some(after), Some(issued)) = (self.auto_pair_after, self.invite_issued) else {
            return;
        };
        if self.remote.invite.is_none() || now < issued + after {
            return;
        }
        let n = self.remote.devices.len() as u64;
        let key = bytes(now as u64 ^ n, 65);
        self.remote.devices.push(PairedDevice {
            id: base64(&bytes(now as u64 ^ 0xD1, 16), true)[..22].to_string(),
            name: "Galaxy Tab S10".into(),
            platform: "Android 16 · tablet".into(),
            public_key: base64(&key, false),
            paired_at: ts(now),
            last_seen_at: Some(ts(now)),
            request_count: 1,
        });
        self.remote.invite = None;
        self.invite_issued = None;
        self.log(
            now,
            "paired Galaxy Tab S10 (Android 16 · tablet) from 100.88.1.20",
        );
    }

    /// Routes one control API request; returns status and JSON body.
    pub fn route(
        &mut self,
        method: &str,
        path: &str,
        body: &[u8],
        now: DateTime<Utc>,
    ) -> (u16, Vec<u8>) {
        let now_s = now.timestamp();
        self.apply_remote_state(now_s);
        self.maybe_auto_pair(now_s);
        let path = path.split('?').next().unwrap_or(path);
        let segments: Vec<String> = path
            .trim_matches('/')
            .split('/')
            .map(http::decode_segment)
            .collect();
        let segments: Vec<&str> = segments.iter().map(String::as_str).collect();
        fn ok<T: Serialize>(value: &T) -> (u16, Vec<u8>) {
            (200, serde_json::to_vec(value).unwrap_or_default())
        }
        fn err(status: u16, message: &str) -> (u16, Vec<u8>) {
            (
                status,
                serde_json::to_vec(&ErrorBody {
                    error: message.into(),
                })
                .unwrap_or_default(),
            )
        }
        fn parse<T: serde::de::DeserializeOwned>(body: &[u8]) -> Result<T, (u16, Vec<u8>)> {
            serde_json::from_slice(body).map_err(|e| err(400, &format!("invalid body: {e}")))
        }
        match (method, segments.as_slice()) {
            ("GET", ["v1", "status"]) => ok(&self.status()),
            ("POST", ["v1", "refresh"]) => {
                if !body.is_empty() {
                    if let Err(e) = parse::<RefreshBody>(body) {
                        return e;
                    }
                }
                self.last_scan = now_s;
                ok(&self.status())
            }
            ("POST", ["v1", "rpc"]) => match parse::<RemoteRequest>(body) {
                Ok(request) => ok(&self.reply(&request, now_s)),
                Err(e) => e,
            },
            ("GET", ["v1", "settings"]) => ok(&self.settings),
            ("PUT", ["v1", "settings", "groups", id]) => {
                let Some(index) = self.accounts.iter().position(|a| a.account.id == *id) else {
                    return err(404, "unknown account");
                };
                match parse::<GroupOverrideBody>(body) {
                    Ok(GroupOverrideBody { group }) => {
                        match group {
                            Some(g) if g != self.accounts[index].suggested => {
                                self.settings.group_overrides.insert(id.to_string(), g);
                            }
                            _ => {
                                self.settings.group_overrides.remove(*id);
                            }
                        }
                        ok(&self.settings)
                    }
                    Err(e) => e,
                }
            }
            ("PUT", ["v1", "settings", "spend"]) => match parse::<SpendSettingsBody>(body) {
                Ok(update) => {
                    if let Some(groups) = update.groups {
                        let valid: Vec<String> = groups
                            .into_iter()
                            .filter(|g| PlanGroup::ALL.iter().any(|p| p.id() == g))
                            .collect();
                        if valid.is_empty() {
                            return err(400, "at least one plan group must count toward the total");
                        }
                        self.settings.spend_groups = valid;
                    }
                    if let Some(thresholds) = update.thresholds {
                        if let Some((range, _)) = thresholds.iter().find(|(_, t)| !t.is_valid()) {
                            return err(400, &format!("invalid spend limit for {range}"));
                        }
                        self.settings.spend_thresholds = thresholds;
                    }
                    ok(&self.settings)
                }
                Err(e) => e,
            },
            ("GET", ["v1", "remote"]) => ok(&self.remote),
            ("PUT", ["v1", "remote"]) => match parse::<RemoteSettingsBody>(body) {
                Ok(update) => {
                    if let Some(port) = update.port {
                        if !(1025..=65535).contains(&port) {
                            return err(400, "port must be between 1025 and 65535");
                        }
                        self.remote.port = port;
                        self.remote.invite = None;
                    }
                    if let Some(enabled) = update.enabled {
                        self.remote.enabled = enabled;
                        let line = if enabled {
                            "remote access on"
                        } else {
                            "remote access off"
                        };
                        self.log(now_s, line);
                    }
                    if let Some(https) = update.https_enabled {
                        self.remote.https.enabled = https;
                        let line = if https {
                            "tailscale serve on"
                        } else {
                            "tailscale serve off"
                        };
                        self.log(now_s, line);
                    }
                    self.apply_remote_state(now_s);
                    ok(&self.remote)
                }
                Err(e) => e,
            },
            ("POST", ["v1", "remote", "invite"]) => match self.new_invite(now_s) {
                Ok(()) => ok(&self.remote),
                Err((status, message)) => err(status, &message),
            },
            ("DELETE", ["v1", "remote", "invite"]) => {
                self.remote.invite = None;
                self.invite_issued = None;
                ok(&self.remote)
            }
            ("DELETE", ["v1", "remote", "devices", id]) => {
                let Some(index) = self.remote.devices.iter().position(|d| d.id == *id) else {
                    return err(404, "unknown device");
                };
                let device = self.remote.devices.remove(index);
                self.log(now_s, &format!("revoked {}", device.name));
                ok(&self.remote)
            }
            (_, ["v1", ..]) if matches!(method, "GET" | "PUT" | "POST" | "DELETE") => {
                err(404, "not found")
            }
            _ => err(405, "method not allowed"),
        }
    }
}

/// Handles one connection: one request, one response.
pub fn handle_connection(
    stream: UnixStream,
    daemon: &Mutex<MockDaemon>,
    delay: std::time::Duration,
) {
    let Ok(request) = http::read_request(&stream) else {
        return;
    };
    if !delay.is_zero()
        && (request.path.starts_with("/v1/rpc") || request.path.starts_with("/v1/refresh"))
    {
        std::thread::sleep(delay);
    }
    let (status, body) = match daemon.lock() {
        Ok(mut d) => d.route(&request.method, &request.path, &request.body, Utc::now()),
        Err(_) => (500, br#"{"error":"mock state poisoned"}"#.to_vec()),
    };
    let mut stream = stream;
    let _ = http::write_response(&mut stream, status, &body);
}

/// Serves until the listener fails; each connection on its own thread.
pub fn serve(listener: UnixListener, daemon: Arc<Mutex<MockDaemon>>, delay: std::time::Duration) {
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let daemon = Arc::clone(&daemon);
        std::thread::spawn(move || handle_connection(stream, &daemon, delay));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn daemon() -> (MockDaemon, i64) {
        let now = Utc::now();
        (MockDaemon::new(now), now.timestamp())
    }

    #[test]
    fn base64_variants() {
        assert_eq!(base64(b"hello", false), "aGVsbG8=");
        assert_eq!(base64(b"hello", true), "aGVsbG8");
        assert_eq!(base64(&[0xfb, 0xff], true), "-_8");
    }

    #[test]
    fn summary_totals_add_up_and_today_matches() {
        let (d, now) = daemon();
        let mut req = RemoteRequest::new(RemoteMethod::Summary);
        req.days = Some(7);
        let s = d.summary(&req, now);
        let group_sum: f64 = s.groups.iter().map(|g| g.totals.cost_usd).sum();
        assert!((group_sum - s.total.cost_usd).abs() < 1e-6);
        assert!(
            s.total.cost_usd > 50.0,
            "a week of usage: {}",
            s.total.cost_usd
        );
        assert!(s.total.cached_input_tokens < s.total.input_tokens);
        assert!(s.today_cost_usd <= s.total.cost_usd + 1e-6);
    }

    #[test]
    fn timeline_matches_summary_and_respects_resolution() {
        let (d, now) = daemon();
        let mut req = RemoteRequest::new(RemoteMethod::Timeline);
        req.days = Some(1);
        req.resolution = Some("15m".into());
        let t = d.timeline(&req, now);
        assert_eq!(t.resolution, "15m");
        assert_eq!(t.periods.len(), 96);
        let mut s_req = RemoteRequest::new(RemoteMethod::Summary);
        s_req.days = Some(1);
        let s = d.summary(&s_req, now);
        let sum: f64 = t.points.iter().map(|p| p.cost_usd).sum();
        assert!(
            (sum - s.total.cost_usd).abs() < 1e-6,
            "{sum} vs {}",
            s.total.cost_usd
        );
        // Minute buckets over 90 days are coarsened to days.
        req.days = Some(90);
        req.resolution = Some("minute".into());
        let t = d.timeline(&req, now);
        assert_eq!(t.resolution, "day");
        assert!(t.periods.len() >= 90 && t.periods.len() <= 91);
    }

    #[test]
    fn group_override_moves_accounts() {
        let (mut d, now) = daemon();
        let (status, _) = d.route(
            "PUT",
            "/v1/settings/groups/opencode",
            br#"{"group":"work"}"#,
            Utc::now(),
        );
        assert_eq!(status, 200);
        let mut req = RemoteRequest::new(RemoteMethod::Summary);
        req.days = Some(30);
        let s = d.summary(&req, now);
        assert!(s
            .group("work")
            .unwrap()
            .accounts
            .iter()
            .any(|a| a.account.id == "opencode"));
        assert!(s.group("other").is_none());
        let (_, body) = d.route(
            "PUT",
            "/v1/settings/groups/opencode",
            br#"{"group":null}"#,
            Utc::now(),
        );
        let settings: HostSettings = serde_json::from_slice(&body).unwrap();
        assert!(settings.group_overrides.is_empty());
    }

    #[test]
    fn invites_and_revoke() {
        let (mut d, _) = daemon();
        let (status, body) = d.route("POST", "/v1/remote/invite", b"", Utc::now());
        assert_eq!(status, 200);
        let remote: RemoteStatus = serde_json::from_slice(&body).unwrap();
        let invite = remote.invite.unwrap();
        assert!(invite
            .url
            .starts_with("planmeter://pair?h=devbox.tail1234.ts.net&p=7787"));
        assert!(invite
            .web_url
            .unwrap()
            .starts_with("https://devbox.tail1234.ts.net/#k="));
        assert_eq!(invite.web_code.unwrap().len(), 8);
        let (status, body) = d.route(
            "DELETE",
            "/v1/remote/devices/Xk3fQ9vR2mLp8sT1uW4yZa",
            b"",
            Utc::now(),
        );
        assert_eq!(status, 200);
        let remote: RemoteStatus = serde_json::from_slice(&body).unwrap();
        assert_eq!(remote.devices.len(), 2);
        assert_eq!(
            d.route("DELETE", "/v1/remote/devices/nope", b"", Utc::now())
                .0,
            404
        );
        // Turning remote access off drops the invite and refuses new ones.
        d.route("POST", "/v1/remote/invite", b"", Utc::now());
        let (_, body) = d.route("PUT", "/v1/remote", br#"{"enabled":false}"#, Utc::now());
        let remote: RemoteStatus = serde_json::from_slice(&body).unwrap();
        assert!(remote.invite.is_none() && remote.status == "off");
        assert_eq!(d.route("POST", "/v1/remote/invite", b"", Utc::now()).0, 409);
    }

    #[test]
    fn rejects_bad_requests() {
        let (mut d, _) = daemon();
        assert_eq!(d.route("POST", "/v1/rpc", b"{nope", Utc::now()).0, 400);
        assert_eq!(d.route("GET", "/v1/unknown", b"", Utc::now()).0, 404);
        assert_eq!(
            d.route("PUT", "/v1/settings/spend", br#"{"groups":[]}"#, Utc::now())
                .0,
            400
        );
        let bad = br#"{"thresholds":{"today":{"limit":0,"warningPercent":80}}}"#;
        assert_eq!(d.route("PUT", "/v1/settings/spend", bad, Utc::now()).0, 400);
    }
}
