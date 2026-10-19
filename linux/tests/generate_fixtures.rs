//! Regenerates the sample control fixtures in `tests/fixtures/control/` from
//! the mock daemon:
//!
//!     cargo test --test generate_fixtures -- --ignored
//!
//! They use the canonical request/response exchange layout and stand in for
//! `protocol/fixtures/control/` until the daemon provides it. Replies come
//! from the canonical `protocol/fixtures/replies/`.

use chrono::{DateTime, TimeZone, Utc};
use planmeter::http::encode_segment;
use planmeter::mock::MockDaemon;
use serde_json::{json, Value};
use std::path::PathBuf;

fn now() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 19, 15, 2, 0).unwrap()
}

/// Sends one request to the mock and records the exchange.
fn exchange(d: &mut MockDaemon, name: &str, method: &str, path: &str, body: Option<Value>) {
    let bytes = body
        .as_ref()
        .map(|b| serde_json::to_vec(b).unwrap())
        .unwrap_or_default();
    let (status, response) = d.route(method, path, &bytes, now());
    let response: Value = serde_json::from_slice(&response).unwrap();
    let value = json!({
        "request": { "method": method, "path": path, "body": body },
        "response": { "status": status, "body": response },
    });
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/control");
    std::fs::create_dir_all(&dir).unwrap();
    // serde_json's map is sorted without `preserve_order`, like RemoteJSON.
    let text = serde_json::to_string_pretty(&value).unwrap() + "\n";
    std::fs::write(dir.join(format!("{name}.json")), text).unwrap();
}

#[test]
#[ignore]
fn regenerate_sample_control_fixtures() {
    let mut d = MockDaemon::new(now());
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
    let groups = format!(
        "/v1/settings/groups/{}",
        encode_segment("codex:plan:personal")
    );
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
            "thresholds": {
                "today": { "limit": 60, "warningPercent": 80 },
                "week": { "limit": 400, "warningPercent": 75 },
            },
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
