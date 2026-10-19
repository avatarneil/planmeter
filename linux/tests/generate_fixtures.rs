//! Regenerates the sample fixtures in `tests/fixtures/` from the mock daemon:
//!
//!     cargo test --test generate_fixtures -- --ignored
//!
//! They follow the canonical `protocol/fixtures/` layout (a bare `RemoteReply`
//! per method; a request/response exchange per control endpoint) and stand in
//! for it in repositories that do not have it.

use chrono::{DateTime, TimeZone, Utc};
use planmeter::http::encode_segment;
use planmeter::mock::MockDaemon;
use planmeter::models::*;
use serde_json::{json, Value};
use std::path::PathBuf;

fn now() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 19, 15, 2, 0).unwrap()
}

fn write(sub: &str, name: &str, value: &Value) {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(sub);
    std::fs::create_dir_all(&dir).unwrap();
    // serde_json's map is sorted without `preserve_order`, like RemoteJSON.
    let text = serde_json::to_string_pretty(value).unwrap() + "\n";
    std::fs::write(dir.join(format!("{name}.json")), text).unwrap();
}

/// Sends one request to the mock and records the exchange.
fn exchange(
    d: &mut MockDaemon,
    name: &str,
    method: &str,
    path: &str,
    body: Option<Value>,
) -> Value {
    let bytes = body
        .as_ref()
        .map(|b| serde_json::to_vec(b).unwrap())
        .unwrap_or_default();
    let (status, response) = d.route(method, path, &bytes, now());
    let response: Value = serde_json::from_slice(&response).unwrap();
    write(
        "control",
        name,
        &json!({
            "request": { "method": method, "path": path, "body": body },
            "response": { "status": status, "body": response },
        }),
    );
    response
}

fn reply(d: &mut MockDaemon, name: &str, request: RemoteRequest) {
    let body = serde_json::to_vec(&request).unwrap();
    let (status, response) = d.route("POST", "/v1/rpc", &body, now());
    assert_eq!(status, 200, "{name}");
    write("replies", name, &serde_json::from_slice(&response).unwrap());
}

fn request(
    method: RemoteMethod,
    days: Option<i64>,
    resolution: Option<&str>,
    minutes: Option<i64>,
) -> RemoteRequest {
    RemoteRequest {
        method,
        days,
        resolution: resolution.map(Into::into),
        account: None,
        minutes,
    }
}

#[test]
#[ignore]
fn regenerate_sample_fixtures() {
    let mut d = MockDaemon::new(now());
    reply(
        &mut d,
        "summary",
        request(RemoteMethod::Summary, Some(7), None, None),
    );
    reply(
        &mut d,
        "summary-last-hour",
        request(RemoteMethod::Summary, Some(1), None, Some(60)),
    );
    reply(
        &mut d,
        "timeline",
        request(RemoteMethod::Timeline, Some(1), Some("hour"), None),
    );
    reply(
        &mut d,
        "timeline-week-day",
        request(RemoteMethod::Timeline, Some(7), Some("day"), None),
    );
    reply(
        &mut d,
        "models",
        request(RemoteMethod::Models, Some(7), None, None),
    );
    reply(
        &mut d,
        "limits",
        request(RemoteMethod::Limits, None, None, None),
    );
    reply(
        &mut d,
        "accounts",
        request(RemoteMethod::Accounts, None, None, None),
    );
    write("replies", "error", &json!({ "error": "server not ready" }));

    exchange(&mut d, "get-status", "GET", "/v1/status", None);
    exchange(
        &mut d,
        "post-refresh",
        "POST",
        "/v1/refresh",
        Some(json!({ "forceAccountUsage": true })),
    );
    exchange(
        &mut d,
        "post-rpc",
        "POST",
        "/v1/rpc",
        Some(json!({ "method": "summary", "days": 1 })),
    );
    exchange(&mut d, "get-settings", "GET", "/v1/settings", None);
    let groups = format!("/v1/settings/groups/{}", encode_segment("opencode"));
    exchange(
        &mut d,
        "put-settings-groups",
        "PUT",
        &groups,
        Some(json!({ "group": "work" })),
    );
    exchange(
        &mut d,
        "put-settings-spend",
        "PUT",
        "/v1/settings/spend",
        Some(json!({
            "groups": ["personal", "work"],
            "thresholds": { "today": { "limit": 60, "warningPercent": 80 }, "week": { "limit": 400, "warningPercent": 75 } },
        })),
    );
    exchange(&mut d, "get-remote", "GET", "/v1/remote", None);
    exchange(
        &mut d,
        "put-remote",
        "PUT",
        "/v1/remote",
        Some(json!({ "enabled": true, "httpsEnabled": true, "port": 7787 })),
    );
    exchange(
        &mut d,
        "post-remote-invite",
        "POST",
        "/v1/remote/invite",
        None,
    );
    exchange(
        &mut d,
        "delete-remote-invite",
        "DELETE",
        "/v1/remote/invite",
        None,
    );
    let device = format!(
        "/v1/remote/devices/{}",
        encode_segment("wE9rT6yU3iO0pA7sD4fG1h")
    );
    exchange(&mut d, "delete-remote-device", "DELETE", &device, None);
    exchange(&mut d, "error-not-found", "GET", "/v1/unknown", None);
    exchange(
        &mut d,
        "error-bad-request",
        "PUT",
        "/v1/settings/spend",
        Some(json!({ "groups": [] })),
    );
}
