//! Wire models for the remote protocol (`RemoteRequest` / `RemoteReply`, as
//! in `Sources/PlanMeterRemote/RemoteModels.swift`) and the `planmeterd`
//! control API (`docs/cross-platform.md`).
//!
//! Decoding is deliberately tolerant: unknown fields are ignored, optional
//! fields are `Option`, and most structs fall back to defaults for missing
//! fields so a newer or older daemon still renders. Dates are ISO-8601
//! (`2026-10-19T12:00:00Z`); `Data` fields stay standard base64 strings.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub type Timestamp = DateTime<Utc>;

/// Serializes dates without fractional seconds: Swift's `.iso8601` decoder
/// rejects them. Decoding accepts any RFC 3339 form.
pub mod iso8601 {
    use super::Timestamp;
    use chrono::SecondsFormat;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(value: &Timestamp, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&value.to_rfc3339_opts(SecondsFormat::Secs, true))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Timestamp, D::Error> {
        let raw = String::deserialize(deserializer)?;
        parse(&raw).map_err(serde::de::Error::custom)
    }

    pub fn parse(raw: &str) -> Result<Timestamp, String> {
        chrono::DateTime::parse_from_rfc3339(raw.trim())
            .map(|d| d.with_timezone(&chrono::Utc))
            .map_err(|e| format!("invalid date {raw:?}: {e}"))
    }

    pub mod option {
        use super::Timestamp;
        use serde::{Deserialize, Deserializer, Serializer};

        pub fn serialize<S: Serializer>(
            value: &Option<Timestamp>,
            serializer: S,
        ) -> Result<S::Ok, S::Error> {
            match value {
                Some(v) => super::serialize(v, serializer),
                None => serializer.serialize_none(),
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(
            deserializer: D,
        ) -> Result<Option<Timestamp>, D::Error> {
            match Option::<String>::deserialize(deserializer)? {
                Some(raw) => super::parse(&raw)
                    .map(Some)
                    .map_err(serde::de::Error::custom),
                None => Ok(None),
            }
        }
    }

    pub mod vec {
        use super::Timestamp;
        use serde::ser::SerializeSeq;
        use serde::{Deserialize, Deserializer, Serializer};

        pub fn serialize<S: Serializer>(
            values: &[Timestamp],
            serializer: S,
        ) -> Result<S::Ok, S::Error> {
            let mut seq = serializer.serialize_seq(Some(values.len()))?;
            for v in values {
                seq.serialize_element(&v.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))?;
            }
            seq.end()
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(
            deserializer: D,
        ) -> Result<Vec<Timestamp>, D::Error> {
            Vec::<String>::deserialize(deserializer)?
                .iter()
                .map(|raw| super::parse(raw).map_err(serde::de::Error::custom))
                .collect()
        }
    }
}

fn epoch() -> Timestamp {
    DateTime::<Utc>::UNIX_EPOCH
}

// MARK: - Remote protocol

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RemoteMethod {
    Summary,
    Models,
    Timeline,
    Limits,
    Accounts,
}

impl RemoteMethod {
    pub const ALL: [RemoteMethod; 5] = [
        Self::Summary,
        Self::Models,
        Self::Timeline,
        Self::Limits,
        Self::Accounts,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Summary => "summary",
            Self::Models => "models",
            Self::Timeline => "timeline",
            Self::Limits => "limits",
            Self::Accounts => "accounts",
        }
    }
}

/// One RPC shape for every report, as phones send it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteRequest {
    pub method: RemoteMethod,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub days: Option<i64>,
    /// "minute", "5m", "15m", "hour", or "day"; timeline only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    /// Account filter for `models`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
    /// A window shorter than a day, in minutes, ending now; overrides `days`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub minutes: Option<i64>,
}

impl RemoteRequest {
    pub fn new(method: RemoteMethod) -> Self {
        Self {
            method,
            days: None,
            resolution: None,
            account: None,
            minutes: None,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteTotals {
    pub cost_usd: f64,
    pub tokens: i64,
    pub input_tokens: i64,
    pub cached_input_tokens: i64,
    pub output_tokens: i64,
    pub sessions: i64,
    pub cache_savings_usd: f64,
}

impl RemoteTotals {
    /// Share of input tokens served from cache.
    pub fn cached_share(&self) -> f64 {
        if self.input_tokens > 0 {
            self.cached_input_tokens as f64 / self.input_tokens as f64
        } else {
            0.0
        }
    }

    pub fn add(&mut self, other: &RemoteTotals) {
        self.cost_usd += other.cost_usd;
        self.tokens += other.tokens;
        self.input_tokens += other.input_tokens;
        self.cached_input_tokens += other.cached_input_tokens;
        self.output_tokens += other.output_tokens;
        self.sessions += other.sessions;
        self.cache_savings_usd += other.cache_savings_usd;
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteAccount {
    pub id: String,
    pub name: String,
    pub provider: String,
    pub provider_name: String,
    /// "personal", "work", or "other" after the host's overrides.
    pub group: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accent_color_hex: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteAccountUsage {
    pub account: RemoteAccount,
    pub totals: RemoteTotals,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteGroupUsage {
    pub group: String,
    pub totals: RemoteTotals,
    pub accounts: Vec<RemoteAccountUsage>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteSummary {
    pub days: i64,
    #[serde(with = "iso8601")]
    pub from: Timestamp,
    #[serde(with = "iso8601")]
    pub to: Timestamp,
    pub groups: Vec<RemoteGroupUsage>,
    pub total: RemoteTotals,
    pub today_cost_usd: f64,
    #[serde(with = "iso8601")]
    pub generated_at: Timestamp,
    pub server_name: String,
    pub pricing_source: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub uses_provider_dates: Option<bool>,
    /// Set for windows shorter than a day.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minutes: Option<i64>,
}

impl Default for RemoteSummary {
    fn default() -> Self {
        Self {
            days: 1,
            from: epoch(),
            to: epoch(),
            groups: Vec::new(),
            total: RemoteTotals::default(),
            today_cost_usd: 0.0,
            generated_at: epoch(),
            server_name: String::new(),
            pricing_source: String::new(),
            uses_provider_dates: None,
            minutes: None,
        }
    }
}

impl RemoteSummary {
    pub fn group(&self, name: &str) -> Option<&RemoteGroupUsage> {
        self.groups.iter().find(|g| g.group == name)
    }

    /// Totals of the given plan groups only.
    pub fn totals_for_groups(&self, groups: &[String]) -> RemoteTotals {
        let mut out = RemoteTotals::default();
        for g in self
            .groups
            .iter()
            .filter(|g| groups.iter().any(|s| s == &g.group))
        {
            out.add(&g.totals);
        }
        out
    }

    pub fn account_count(&self) -> usize {
        self.groups.iter().map(|g| g.accounts.len()).sum()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteModelRow {
    pub account_id: String,
    pub account_name: String,
    pub group: String,
    pub provider: String,
    pub model: String,
    pub totals: RemoteTotals,
    pub priced: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteTimelinePoint {
    #[serde(with = "iso8601")]
    pub period: Timestamp,
    pub account_id: String,
    pub cost_usd: f64,
    pub tokens: i64,
    /// The part of `cost_usd` from workspace credits without timing, spread
    /// evenly over the hours the provider reported.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub baseline_cost_usd: Option<f64>,
}

impl Default for RemoteTimelinePoint {
    fn default() -> Self {
        Self {
            period: epoch(),
            account_id: String::new(),
            cost_usd: 0.0,
            tokens: 0,
            baseline_cost_usd: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteTimeline {
    pub days: i64,
    pub resolution: String,
    #[serde(with = "iso8601::vec")]
    pub periods: Vec<Timestamp>,
    pub points: Vec<RemoteTimelinePoint>,
    pub accounts: Vec<RemoteAccount>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minutes: Option<i64>,
}

impl Default for RemoteTimeline {
    fn default() -> Self {
        Self {
            days: 1,
            resolution: "day".into(),
            periods: Vec::new(),
            points: Vec::new(),
            accounts: Vec::new(),
            minutes: None,
        }
    }
}

impl RemoteTimeline {
    /// Bucket length in seconds for fixed-step resolutions; `None` for calendar days.
    pub fn step_seconds(resolution: &str) -> Option<i64> {
        match resolution {
            "minute" => Some(60),
            "5m" => Some(300),
            "15m" => Some(900),
            "hour" => Some(3600),
            _ => None,
        }
    }

    /// Whether a fixed-step timeline can be re-bucketed into `target`.
    pub fn coarsens(source: &str, target: &str) -> bool {
        match (Self::step_seconds(source), Self::step_seconds(target)) {
            (Some(step), Some(wide)) => wide > step && wide % step == 0,
            _ => false,
        }
    }

    /// Re-buckets a fixed-step timeline into a coarser fixed step, e.g. 5m
    /// into 15m. Returns `None` when the target is not a whole multiple.
    pub fn rebucketed(&self, target: &str) -> Option<RemoteTimeline> {
        if target == self.resolution {
            return Some(self.clone());
        }
        if !Self::coarsens(&self.resolution, target) {
            return None;
        }
        let wide = Self::step_seconds(target)?;
        let floor = |d: &Timestamp| -> Timestamp {
            let secs = d.timestamp().div_euclid(wide) * wide;
            DateTime::from_timestamp(secs, 0).unwrap_or(*d)
        };
        let mut merged: BTreeMap<(Timestamp, String), RemoteTimelinePoint> = BTreeMap::new();
        for point in &self.points {
            let key = (floor(&point.period), point.account_id.clone());
            let entry = merged
                .entry(key.clone())
                .or_insert_with(|| RemoteTimelinePoint {
                    period: key.0,
                    account_id: key.1.clone(),
                    ..Default::default()
                });
            entry.cost_usd += point.cost_usd;
            entry.tokens += point.tokens;
            if let Some(b) = point.baseline_cost_usd {
                entry.baseline_cost_usd = Some(entry.baseline_cost_usd.unwrap_or(0.0) + b);
            }
        }
        let mut periods: Vec<Timestamp> = Vec::new();
        for p in self.periods.iter().map(floor) {
            if periods.last() != Some(&p) {
                periods.push(p);
            }
        }
        Some(RemoteTimeline {
            days: self.days,
            resolution: target.to_string(),
            periods,
            points: merged.into_values().collect(),
            accounts: self.accounts.clone(),
            minutes: self.minutes,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteLimitWindow {
    pub label: String,
    pub used_percent: f64,
    pub window_minutes: i64,
    #[serde(with = "iso8601")]
    pub resets_at: Timestamp,
}

impl Default for RemoteLimitWindow {
    fn default() -> Self {
        Self {
            label: String::new(),
            used_percent: 0.0,
            window_minutes: 0,
            resets_at: epoch(),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteAccountLimits {
    pub account: RemoteAccount,
    pub windows: Vec<RemoteLimitWindow>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(with = "iso8601::option", skip_serializing_if = "Option::is_none")]
    pub as_of: Option<Timestamp>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteLimits {
    pub accounts: Vec<RemoteAccountLimits>,
    pub note: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteSource {
    pub provider: String,
    pub path: String,
    /// "ok", "missing", "partial", or "failed".
    pub status: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteAccounts {
    pub accounts: Vec<RemoteAccount>,
    pub sources: Vec<RemoteSource>,
    #[serde(with = "iso8601::option", skip_serializing_if = "Option::is_none")]
    pub scanned_at: Option<Timestamp>,
}

/// Union reply: exactly one payload field is set for a successful call.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteReply {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<RemoteSummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub models: Option<Vec<RemoteModelRow>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeline: Option<RemoteTimeline>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limits: Option<RemoteLimits>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accounts: Option<RemoteAccounts>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// What the host keeps per paired phone or browser.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PairedDevice {
    pub id: String,
    pub name: String,
    pub platform: String,
    /// Raw P-256 public key, standard base64.
    pub public_key: String,
    #[serde(with = "iso8601")]
    pub paired_at: Timestamp,
    #[serde(with = "iso8601::option", skip_serializing_if = "Option::is_none")]
    pub last_seen_at: Option<Timestamp>,
    pub request_count: i64,
}

impl Default for PairedDevice {
    fn default() -> Self {
        Self {
            id: String::new(),
            name: String::new(),
            platform: String::new(),
            public_key: String::new(),
            paired_at: epoch(),
            last_seen_at: None,
            request_count: 0,
        }
    }
}

// MARK: - Plan groups and spend thresholds

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PlanGroup {
    Personal,
    Work,
    Other,
}

impl PlanGroup {
    pub const ALL: [PlanGroup; 3] = [Self::Personal, Self::Work, Self::Other];

    pub fn id(self) -> &'static str {
        match self {
            Self::Personal => "personal",
            Self::Work => "work",
            Self::Other => "other",
        }
    }

    /// Unknown names fall back to Other, as the Swift clients do.
    pub fn parse(raw: &str) -> PlanGroup {
        match raw {
            "personal" => Self::Personal,
            "work" => Self::Work,
            _ => Self::Other,
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Personal => "Personal",
            Self::Work => "Work",
            Self::Other => "Other",
        }
    }

    /// The Mac's group colors.
    pub fn color_hex(self) -> &'static str {
        match self {
            Self::Personal => "#0891b2",
            Self::Work => "#7c3aed",
            Self::Other => "#8b8f98",
        }
    }
}

impl<'de> Deserialize<'de> for PlanGroup {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(PlanGroup::parse(&String::deserialize(deserializer)?))
    }
}

/// A personal target for estimated usage cost, not a provider-enforced cap.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpendThreshold {
    pub limit: f64,
    #[serde(default = "SpendThreshold::default_warning")]
    pub warning_percent: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SpendStatus {
    Comfortable,
    Approaching,
    Reached,
}

impl SpendThreshold {
    pub const MIN_LIMIT: f64 = 0.01;
    pub const MAX_LIMIT: f64 = 1_000_000_000.0;

    fn default_warning() -> f64 {
        80.0
    }

    pub fn new(limit: f64, warning_percent: f64) -> Self {
        Self {
            limit,
            warning_percent,
        }
    }

    pub fn is_valid(&self) -> bool {
        self.limit.is_finite()
            && (Self::MIN_LIMIT..=Self::MAX_LIMIT).contains(&self.limit)
            && self.warning_percent.is_finite()
            && (1.0..=99.0).contains(&self.warning_percent)
    }

    pub fn status(&self, spend: f64) -> SpendStatus {
        if spend >= self.limit {
            SpendStatus::Reached
        } else if spend >= self.limit * self.warning_percent / 100.0 {
            SpendStatus::Approaching
        } else {
            SpendStatus::Comfortable
        }
    }

    pub fn fraction(&self, spend: f64) -> f64 {
        if !self.is_valid() || !spend.is_finite() {
            return 0.0;
        }
        (spend / self.limit).max(0.0)
    }
}

// MARK: - Control API

/// `GET /v1/status`, `POST /v1/refresh`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DaemonStatus {
    pub api_version: i64,
    pub version: String,
    pub server_name: String,
    pub is_scanning: bool,
    #[serde(with = "iso8601::option")]
    pub last_scan_at: Option<Timestamp>,
    pub last_error: Option<String>,
    pub pricing_source: Option<String>,
    pub pricing_error: Option<String>,
    pub account_count: i64,
}

impl Default for DaemonStatus {
    fn default() -> Self {
        Self {
            api_version: 1,
            version: String::new(),
            server_name: String::new(),
            is_scanning: false,
            last_scan_at: None,
            last_error: None,
            pricing_source: None,
            pricing_error: None,
            account_count: 0,
        }
    }
}

/// `GET /v1/settings`. Range keys match the Mac's `TimeRange` ids.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HostSettings {
    pub group_overrides: BTreeMap<String, PlanGroup>,
    pub spend_groups: Vec<String>,
    pub spend_thresholds: BTreeMap<String, SpendThreshold>,
}

impl Default for HostSettings {
    fn default() -> Self {
        Self {
            group_overrides: BTreeMap::new(),
            spend_groups: PlanGroup::ALL.iter().map(|g| g.id().to_string()).collect(),
            spend_thresholds: BTreeMap::new(),
        }
    }
}

impl HostSettings {
    /// The groups counted toward the spend total; never empty.
    pub fn effective_spend_groups(&self) -> Vec<String> {
        let groups: Vec<String> = PlanGroup::ALL
            .iter()
            .map(|g| g.id().to_string())
            .filter(|g| self.spend_groups.contains(g))
            .collect();
        if groups.is_empty() {
            PlanGroup::ALL.iter().map(|g| g.id().to_string()).collect()
        } else {
            groups
        }
    }

    pub fn threshold(&self, range_id: &str) -> Option<SpendThreshold> {
        self.spend_thresholds
            .get(range_id)
            .copied()
            .filter(SpendThreshold::is_valid)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TailscaleStatus {
    pub available: bool,
    pub address: Option<String>,
    pub dns_name: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HttpsStatus {
    pub enabled: bool,
    pub active: bool,
    pub url: Option<String>,
    pub certificate_status: Option<String>,
}

/// The active pairing code. `url` is what the PlanMeter apps scan;
/// `web_url` opens the web client; `web_code` is typed into an open web app.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteInvite {
    pub url: String,
    pub local_url: Option<String>,
    pub web_url: Option<String>,
    pub web_code: Option<String>,
    #[serde(with = "iso8601")]
    pub expires_at: Timestamp,
}

impl Default for RemoteInvite {
    fn default() -> Self {
        Self {
            url: String::new(),
            local_url: None,
            web_url: None,
            web_code: None,
            expires_at: epoch(),
        }
    }
}

/// `GET /v1/remote`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteStatus {
    pub enabled: bool,
    pub port: i64,
    pub status: String,
    pub bind_addresses: Vec<String>,
    pub tailscale: TailscaleStatus,
    pub https: HttpsStatus,
    pub devices: Vec<PairedDevice>,
    pub invite: Option<RemoteInvite>,
    pub log: Vec<String>,
}

impl Default for RemoteStatus {
    fn default() -> Self {
        Self {
            enabled: false,
            port: 7787,
            status: "Off".into(),
            bind_addresses: Vec::new(),
            tailscale: TailscaleStatus::default(),
            https: HttpsStatus::default(),
            devices: Vec::new(),
            invite: None,
            log: Vec::new(),
        }
    }
}

impl RemoteStatus {
    /// Listening on the tailnet, so a pairing code can be issued.
    pub fn is_listening(&self) -> bool {
        self.enabled && !self.bind_addresses.is_empty()
    }
}

/// `POST /v1/refresh` body.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RefreshBody {
    pub force_account_usage: bool,
}

/// `PUT /v1/settings/groups/{accountId}` body; `None` restores the suggestion.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupOverrideBody {
    pub group: Option<PlanGroup>,
}

/// `PUT /v1/settings/spend` body; absent fields stay unchanged.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpendSettingsBody {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub groups: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thresholds: Option<BTreeMap<String, SpendThreshold>>,
}

/// `PUT /v1/remote` body; absent fields stay unchanged.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteSettingsBody {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub https_enabled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<i64>,
}

/// Non-2xx control API responses.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ErrorBody {
    pub error: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_round_trip_without_fractional_seconds() {
        let point = RemoteTimelinePoint {
            period: DateTime::from_timestamp(1_792_411_200, 0).unwrap(),
            account_id: "a".into(),
            cost_usd: 1.5,
            tokens: 10,
            baseline_cost_usd: None,
        };
        let json = serde_json::to_string(&point).unwrap();
        assert!(
            json.contains("\"period\":\"2026-10-19T12:00:00Z\""),
            "{json}"
        );
        assert!(!json.contains("baselineCostUsd"));
        let back: RemoteTimelinePoint = serde_json::from_str(&json).unwrap();
        assert_eq!(back, point);
    }

    #[test]
    fn fractional_and_offset_dates_decode() {
        let a = iso8601::parse("2026-10-19T12:00:00.250Z").unwrap();
        let b = iso8601::parse("2026-10-19T14:00:00+02:00").unwrap();
        assert_eq!(a.timestamp(), b.timestamp());
    }

    #[test]
    fn request_omits_absent_fields() {
        let mut r = RemoteRequest::new(RemoteMethod::Timeline);
        r.days = Some(7);
        r.resolution = Some("hour".into());
        assert_eq!(
            serde_json::to_string(&r).unwrap(),
            r#"{"method":"timeline","days":7,"resolution":"hour"}"#
        );
    }

    #[test]
    fn group_override_body_sends_null() {
        let body = GroupOverrideBody { group: None };
        assert_eq!(serde_json::to_string(&body).unwrap(), r#"{"group":null}"#);
        let body = GroupOverrideBody {
            group: Some(PlanGroup::Work),
        };
        assert_eq!(serde_json::to_string(&body).unwrap(), r#"{"group":"work"}"#);
    }

    #[test]
    fn threshold_rules_match_swift() {
        let t = SpendThreshold::new(100.0, 80.0);
        assert!(t.is_valid());
        assert_eq!(t.status(79.99), SpendStatus::Comfortable);
        assert_eq!(t.status(80.0), SpendStatus::Approaching);
        assert_eq!(t.status(100.0), SpendStatus::Reached);
        assert!((t.fraction(150.0) - 1.5).abs() < 1e-9);
        assert!(!SpendThreshold::new(0.0, 80.0).is_valid());
        assert!(!SpendThreshold::new(10.0, 100.0).is_valid());
        assert!(!SpendThreshold::new(f64::NAN, 50.0).is_valid());
    }

    #[test]
    fn rebucket_merges_points_and_periods() {
        let t0 = DateTime::from_timestamp(1_792_411_200, 0).unwrap();
        let mk =
            |offset: i64, account: &str, cost: f64, baseline: Option<f64>| RemoteTimelinePoint {
                period: t0 + chrono::Duration::seconds(offset),
                account_id: account.into(),
                cost_usd: cost,
                tokens: 1,
                baseline_cost_usd: baseline,
            };
        let timeline = RemoteTimeline {
            days: 1,
            resolution: "5m".into(),
            periods: (0..6)
                .map(|i| t0 + chrono::Duration::seconds(i * 300))
                .collect(),
            points: vec![
                mk(0, "a", 1.0, None),
                mk(300, "a", 2.0, Some(0.5)),
                mk(900, "b", 4.0, None),
            ],
            accounts: vec![],
            minutes: None,
        };
        let wide = timeline.rebucketed("15m").unwrap();
        assert_eq!(wide.periods.len(), 2);
        assert_eq!(wide.points.len(), 2);
        assert_eq!(wide.points[0].cost_usd, 3.0);
        assert_eq!(wide.points[0].baseline_cost_usd, Some(0.5));
        assert_eq!(wide.points[0].tokens, 2);
        assert!(timeline.rebucketed("day").is_none());
        assert!(RemoteTimeline::coarsens("minute", "15m"));
        assert!(!RemoteTimeline::coarsens("hour", "15m"));
    }

    #[test]
    fn spend_groups_never_empty() {
        let mut s = HostSettings {
            spend_groups: vec![],
            ..Default::default()
        };
        assert_eq!(s.effective_spend_groups().len(), 3);
        s.spend_groups = vec!["work".into(), "bogus".into()];
        assert_eq!(s.effective_spend_groups(), vec!["work".to_string()]);
    }
}
