//! Blocking client for the `planmeterd` control API: HTTP/1.1 over a Unix
//! domain socket, one request per connection. The UI runs these calls off
//! the main thread (`gio::spawn_blocking`).

use crate::http;
use crate::models::*;
use crate::range::{Resolution, TimeRange};
use chrono::{DateTime, Local, Utc};
use serde::de::DeserializeOwned;
use serde::Serialize;
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fmt;
use std::io;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Socket path, first match wins: `$PLANMETER_CONTROL_SOCKET`,
/// `$XDG_RUNTIME_DIR/planmeter/control.sock`, `/tmp/planmeter-$UID/control.sock`.
pub fn default_socket_path() -> PathBuf {
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    socket_path_from(
        std::env::var_os("PLANMETER_CONTROL_SOCKET"),
        std::env::var_os("XDG_RUNTIME_DIR"),
        uid,
    )
}

pub fn socket_path_from(
    explicit: Option<OsString>,
    runtime_dir: Option<OsString>,
    uid: u32,
) -> PathBuf {
    if let Some(path) = explicit.filter(|p| !p.is_empty()) {
        return PathBuf::from(path);
    }
    if let Some(dir) = runtime_dir.filter(|p| !p.is_empty()) {
        return PathBuf::from(dir).join("planmeter").join("control.sock");
    }
    PathBuf::from(format!("/tmp/planmeter-{uid}/control.sock"))
}

#[derive(Debug, Clone, PartialEq)]
pub enum ClientError {
    /// No daemon at the socket: missing, refused, or not a socket.
    Unavailable(String),
    /// Connected, but it did not answer in time.
    Timeout,
    /// A non-2xx answer, with the daemon's `{"error": …}` message.
    Http { status: u16, message: String },
    /// Not HTTP, or not the JSON we expected.
    Protocol(String),
    /// An RPC reply with `error` set.
    Remote(String),
}

impl ClientError {
    pub fn is_unavailable(&self) -> bool {
        matches!(self, Self::Unavailable(_))
    }
}

impl fmt::Display for ClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unavailable(m) => write!(f, "planmeterd is not running ({m})"),
            Self::Timeout => write!(f, "planmeterd did not respond in time"),
            Self::Http { status, message } => {
                if message.is_empty() {
                    write!(f, "planmeterd returned HTTP {status}")
                } else {
                    write!(f, "{message}")
                }
            }
            Self::Protocol(m) => write!(f, "Unexpected reply from planmeterd: {m}"),
            Self::Remote(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for ClientError {}

pub type Result<T> = std::result::Result<T, ClientError>;

fn connect_error(err: io::Error, path: &Path) -> ClientError {
    use io::ErrorKind::*;
    match err.kind() {
        NotFound => ClientError::Unavailable(format!("no socket at {}", path.display())),
        ConnectionRefused => {
            ClientError::Unavailable(format!("nothing is listening at {}", path.display()))
        }
        PermissionDenied => {
            ClientError::Unavailable(format!("permission denied for {}", path.display()))
        }
        TimedOut | WouldBlock => ClientError::Timeout,
        _ => ClientError::Unavailable(format!("{} ({err})", path.display())),
    }
}

#[derive(Debug, Clone)]
pub struct Client {
    socket: PathBuf,
    /// RPCs can wait for a scan, so reads get a generous timeout.
    read_timeout: Duration,
}

impl Default for Client {
    fn default() -> Self {
        Self::new(default_socket_path())
    }
}

impl Client {
    pub fn new(socket: impl Into<PathBuf>) -> Self {
        Self {
            socket: socket.into(),
            read_timeout: Duration::from_secs(90),
        }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.read_timeout = timeout;
        self
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    /// One request on a fresh connection.
    pub fn send(&self, method: &str, path: &str, body: Option<&[u8]>) -> Result<http::Response> {
        let mut stream =
            UnixStream::connect(&self.socket).map_err(|e| connect_error(e, &self.socket))?;
        let io_err = |e: io::Error| match e.kind() {
            io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => ClientError::Timeout,
            io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset => {
                ClientError::Unavailable(e.to_string())
            }
            _ => ClientError::Protocol(e.to_string()),
        };
        stream
            .set_write_timeout(Some(Duration::from_secs(10)))
            .map_err(io_err)?;
        stream
            .set_read_timeout(Some(self.read_timeout))
            .map_err(io_err)?;
        http::write_request(&mut stream, method, path, body).map_err(io_err)?;
        http::read_response(&stream).map_err(io_err)
    }

    fn call<T: DeserializeOwned>(
        &self,
        method: &str,
        path: &str,
        body: Option<Vec<u8>>,
    ) -> Result<T> {
        let response = self.send(method, path, body.as_deref())?;
        if !response.is_success() {
            let message = serde_json::from_slice::<ErrorBody>(&response.body)
                .map(|b| b.error)
                .unwrap_or_else(|_| {
                    String::from_utf8_lossy(&response.body)
                        .trim()
                        .chars()
                        .take(200)
                        .collect()
                });
            return Err(ClientError::Http {
                status: response.status,
                message,
            });
        }
        serde_json::from_slice(&response.body)
            .map_err(|e| ClientError::Protocol(format!("{path}: {e}")))
    }

    fn json<B: Serialize>(body: &B) -> Option<Vec<u8>> {
        Some(serde_json::to_vec(body).expect("control API bodies always serialize"))
    }

    // MARK: Daemon

    pub fn status(&self) -> Result<DaemonStatus> {
        self.call("GET", "/v1/status", None)
    }

    /// Rescans transcripts; returns the status after the scan.
    pub fn refresh(&self, force_account_usage: bool) -> Result<DaemonStatus> {
        self.call(
            "POST",
            "/v1/refresh",
            Self::json(&RefreshBody {
                force_account_usage,
            }),
        )
    }

    // MARK: Reports

    pub fn rpc(&self, request: &RemoteRequest) -> Result<RemoteReply> {
        let reply: RemoteReply = self.call("POST", "/v1/rpc", Self::json(request))?;
        match reply.error {
            Some(error) => Err(ClientError::Remote(error)),
            None => Ok(reply),
        }
    }

    pub fn summary(&self, request: &RemoteRequest) -> Result<RemoteSummary> {
        self.rpc(request)?
            .summary
            .ok_or_else(|| ClientError::Protocol("summary reply without a summary".into()))
    }

    pub fn timeline(&self, request: &RemoteRequest) -> Result<RemoteTimeline> {
        self.rpc(request)?
            .timeline
            .ok_or_else(|| ClientError::Protocol("timeline reply without a timeline".into()))
    }

    pub fn models(&self, request: &RemoteRequest) -> Result<Vec<RemoteModelRow>> {
        Ok(self.rpc(request)?.models.unwrap_or_default())
    }

    pub fn limits(&self) -> Result<RemoteLimits> {
        Ok(self
            .rpc(&RemoteRequest::new(RemoteMethod::Limits))?
            .limits
            .unwrap_or_default())
    }

    pub fn accounts(&self) -> Result<RemoteAccounts> {
        Ok(self
            .rpc(&RemoteRequest::new(RemoteMethod::Accounts))?
            .accounts
            .unwrap_or_default())
    }

    // MARK: Settings

    pub fn settings(&self) -> Result<HostSettings> {
        self.call("GET", "/v1/settings", None)
    }

    /// `None` restores the suggested group.
    pub fn set_group(&self, account_id: &str, group: Option<PlanGroup>) -> Result<HostSettings> {
        let path = format!("/v1/settings/groups/{}", http::encode_segment(account_id));
        self.call("PUT", &path, Self::json(&GroupOverrideBody { group }))
    }

    pub fn set_spend(
        &self,
        groups: Option<Vec<String>>,
        thresholds: Option<BTreeMap<String, SpendThreshold>>,
    ) -> Result<HostSettings> {
        self.call(
            "PUT",
            "/v1/settings/spend",
            Self::json(&SpendSettingsBody { groups, thresholds }),
        )
    }

    // MARK: Remote access

    pub fn remote(&self) -> Result<RemoteStatus> {
        self.call("GET", "/v1/remote", None)
    }

    pub fn set_remote(&self, body: &RemoteSettingsBody) -> Result<RemoteStatus> {
        self.call("PUT", "/v1/remote", Self::json(body))
    }

    pub fn create_invite(&self) -> Result<RemoteStatus> {
        self.call("POST", "/v1/remote/invite", None)
    }

    pub fn cancel_invite(&self) -> Result<RemoteStatus> {
        self.call("DELETE", "/v1/remote/invite", None)
    }

    pub fn revoke_device(&self, id: &str) -> Result<RemoteStatus> {
        self.call(
            "DELETE",
            &format!("/v1/remote/devices/{}", http::encode_segment(id)),
            None,
        )
    }

    // MARK: Dashboard

    /// Everything the dashboard shows for one range, fetched in parallel.
    pub fn dashboard(
        &self,
        range: TimeRange,
        granularity: Resolution,
        now: DateTime<Local>,
    ) -> Result<Dashboard> {
        let req = |m| range.request(m, Some(granularity), now);
        let (summary_req, timeline_req, models_req) = (
            req(RemoteMethod::Summary),
            req(RemoteMethod::Timeline),
            req(RemoteMethod::Models),
        );
        std::thread::scope(|scope| {
            let status = scope.spawn(|| self.status());
            let settings = scope.spawn(|| self.settings());
            let remote = scope.spawn(|| self.remote());
            let timeline = scope.spawn(|| self.timeline(&timeline_req));
            let models = scope.spawn(|| self.models(&models_req));
            let limits = scope.spawn(|| self.limits());
            let accounts = scope.spawn(|| self.accounts());
            let summary = self.summary(&summary_req);
            Ok(Dashboard {
                range,
                granularity,
                summary: summary?,
                timeline: join(timeline.join())?,
                models: join(models.join())?,
                limits: join(limits.join())?,
                accounts: join(accounts.join())?,
                status: join(status.join())?,
                settings: join(settings.join())?,
                // An older daemon without remote access still has a dashboard.
                remote: join(remote.join()).ok(),
                fetched_at: Utc::now(),
            })
        })
    }

    /// Spend summaries for several ranges, fetched in parallel, for alerts on
    /// ranges other than the one on screen.
    pub fn summaries(
        &self,
        ranges: &[TimeRange],
        now: DateTime<Local>,
    ) -> Result<Vec<(TimeRange, RemoteSummary)>> {
        std::thread::scope(|scope| {
            let handles: Vec<_> = ranges
                .iter()
                .map(|&range| {
                    let request = range.request(RemoteMethod::Summary, None, now);
                    (range, scope.spawn(move || self.summary(&request)))
                })
                .collect();
            handles
                .into_iter()
                .map(|(range, handle)| Ok((range, join(handle.join())?)))
                .collect()
        })
    }

    /// The host settings and a summary for every range with a spend limit:
    /// what spend alerts need when the dashboard is not refreshing.
    pub fn alert_summaries(
        &self,
        now: DateTime<Local>,
    ) -> Result<(HostSettings, Vec<(TimeRange, RemoteSummary)>)> {
        let settings = self.settings()?;
        let ranges: Vec<TimeRange> = TimeRange::ALL
            .into_iter()
            .filter(|r| settings.threshold(r.id()).is_some())
            .collect();
        let summaries = self.summaries(&ranges, now)?;
        Ok((settings, summaries))
    }
}

fn join<T>(result: std::thread::Result<Result<T>>) -> Result<T> {
    result.unwrap_or_else(|_| Err(ClientError::Protocol("worker panicked".into())))
}

/// One consistent dashboard snapshot.
#[derive(Debug, Clone, PartialEq)]
pub struct Dashboard {
    pub range: TimeRange,
    pub granularity: Resolution,
    pub status: DaemonStatus,
    pub settings: HostSettings,
    pub summary: RemoteSummary,
    pub timeline: RemoteTimeline,
    pub models: Vec<RemoteModelRow>,
    pub limits: RemoteLimits,
    pub accounts: RemoteAccounts,
    pub remote: Option<RemoteStatus>,
    pub fetched_at: DateTime<Utc>,
}

impl Dashboard {
    /// Every known account, in the host's order, for stable series colors.
    pub fn all_accounts(&self) -> Vec<RemoteAccount> {
        let mut out = self.accounts.accounts.clone();
        let extra = self
            .summary
            .groups
            .iter()
            .flat_map(|g| g.accounts.iter().map(|a| &a.account))
            .chain(self.timeline.accounts.iter());
        for account in extra {
            if !out.iter().any(|a| a.id == account.id) {
                out.push(account.clone());
            }
        }
        out
    }

    pub fn account_color(&self, id: &str) -> String {
        crate::format::account_color(&self.all_accounts(), id)
    }

    /// Spend of the groups that count toward the total.
    pub fn spend_total(&self) -> f64 {
        spend_total(&self.summary, &self.settings)
    }

    pub fn threshold(&self) -> Option<SpendThreshold> {
        self.settings.threshold(self.range.id())
    }
}

/// Spend toward a range's limit: the groups that count toward the total.
pub fn spend_total(summary: &RemoteSummary, settings: &HostSettings) -> f64 {
    summary
        .totals_for_groups(&settings.effective_spend_groups())
        .cost_usd
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_path_precedence() {
        let p = socket_path_from(
            Some("/run/custom.sock".into()),
            Some("/run/user/1000".into()),
            1000,
        );
        assert_eq!(p, PathBuf::from("/run/custom.sock"));
        let p = socket_path_from(Some("".into()), Some("/run/user/1000".into()), 1000);
        assert_eq!(p, PathBuf::from("/run/user/1000/planmeter/control.sock"));
        let p = socket_path_from(None, None, 1000);
        assert_eq!(p, PathBuf::from("/tmp/planmeter-1000/control.sock"));
    }

    #[test]
    fn missing_socket_is_unavailable() {
        let dir = std::env::temp_dir().join(format!("planmeter-missing-{}", std::process::id()));
        let client = Client::new(dir.join("control.sock"));
        let err = client.status().unwrap_err();
        assert!(err.is_unavailable(), "{err:?}");
    }
}
