//! Regenerates the sample fixtures in `tests/fixtures/` from the mock daemon:
//!
//!     cargo test --test generate_fixtures -- --ignored
//!
//! They stand in for the canonical `protocol/fixtures/` until those exist.

use chrono::{TimeZone, Utc};
use planmeter::mock::MockDaemon;
use planmeter::models::*;
use std::path::PathBuf;

fn write(sub: &str, name: &str, value: &serde_json::Value) {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(sub);
    std::fs::create_dir_all(&dir).unwrap();
    // serde_json's map is sorted without `preserve_order`, like RemoteJSON.
    let text = serde_json::to_string_pretty(value).unwrap() + "\n";
    std::fs::write(dir.join(format!("{name}.json")), text).unwrap();
}

fn route(d: &mut MockDaemon, method: &str, path: &str, body: &str) -> serde_json::Value {
    let now = Utc.with_ymd_and_hms(2026, 10, 19, 15, 2, 0).unwrap();
    let (status, bytes) = d.route(method, path, body.as_bytes(), now);
    assert!(
        status == 200 || path.contains("missing"),
        "{method} {path}: {status}"
    );
    serde_json::from_slice(&bytes).unwrap()
}

#[test]
#[ignore]
fn regenerate_sample_fixtures() {
    let now = Utc.with_ymd_and_hms(2026, 10, 19, 15, 2, 0).unwrap();
    let mut d = MockDaemon::new(now);
    let rpc = |d: &mut MockDaemon, req: RemoteRequest| {
        route(d, "POST", "/v1/rpc", &serde_json::to_string(&req).unwrap())
    };
    let mut summary = RemoteRequest::new(RemoteMethod::Summary);
    summary.days = Some(7);
    write("replies", "summary", &rpc(&mut d, summary.clone()));
    let mut hour = summary.clone();
    hour.days = Some(1);
    hour.minutes = Some(60);
    write("replies", "summary-last-hour", &rpc(&mut d, hour));
    let mut timeline = RemoteRequest::new(RemoteMethod::Timeline);
    timeline.days = Some(1);
    timeline.resolution = Some("hour".into());
    write("replies", "timeline", &rpc(&mut d, timeline));
    let mut weekly = RemoteRequest::new(RemoteMethod::Timeline);
    weekly.days = Some(7);
    weekly.resolution = Some("day".into());
    write("replies", "timeline-week-day", &rpc(&mut d, weekly));
    let mut models = RemoteRequest::new(RemoteMethod::Models);
    models.days = Some(7);
    write("replies", "models", &rpc(&mut d, models));
    write(
        "replies",
        "limits",
        &rpc(&mut d, RemoteRequest::new(RemoteMethod::Limits)),
    );
    write(
        "replies",
        "accounts",
        &rpc(&mut d, RemoteRequest::new(RemoteMethod::Accounts)),
    );
    write(
        "replies",
        "error",
        &serde_json::to_value(RemoteReply {
            error: Some("server not ready".into()),
            ..Default::default()
        })
        .unwrap(),
    );

    write("control", "status", &route(&mut d, "GET", "/v1/status", ""));
    write(
        "control",
        "refresh",
        &route(
            &mut d,
            "POST",
            "/v1/refresh",
            r#"{"forceAccountUsage":true}"#,
        ),
    );
    write(
        "control",
        "settings",
        &route(&mut d, "GET", "/v1/settings", ""),
    );
    write(
        "control",
        "settings-groups",
        &route(
            &mut d,
            "PUT",
            "/v1/settings/groups/opencode",
            r#"{"group":"work"}"#,
        ),
    );
    write("control", "remote", &route(&mut d, "GET", "/v1/remote", ""));
    write(
        "control",
        "remote-invite",
        &route(&mut d, "POST", "/v1/remote/invite", ""),
    );
    write(
        "control",
        "remote-device-revoked",
        &route(
            &mut d,
            "DELETE",
            "/v1/remote/devices/wE9rT6yU3iO0pA7sD4fG1h",
            "",
        ),
    );
    write(
        "control",
        "error-not-found",
        &route(&mut d, "DELETE", "/v1/remote/devices/missing", ""),
    );
}
