//! The control-socket client against the mock daemon on a temporary socket.

use chrono::Local;
use planmeter::client::{Client, ClientError};
use planmeter::mock::{serve, MockDaemon};
use planmeter::models::*;
use planmeter::range::{Resolution, TimeRange};
use std::collections::BTreeMap;
use std::os::unix::net::UnixListener;
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct Fixture {
    client: Client,
    daemon: Arc<Mutex<MockDaemon>>,
    _dir: tempfile::TempDir,
}

fn start() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("planmeter").join("control.sock");
    std::fs::create_dir_all(socket.parent().unwrap()).unwrap();
    let listener = UnixListener::bind(&socket).unwrap();
    let daemon = Arc::new(Mutex::new(MockDaemon::new(chrono::Utc::now())));
    let shared = Arc::clone(&daemon);
    std::thread::spawn(move || serve(listener, shared, Duration::ZERO));
    Fixture {
        client: Client::new(&socket).with_timeout(Duration::from_secs(20)),
        daemon,
        _dir: dir,
    }
}

#[test]
fn status_and_refresh() {
    let f = start();
    let status = f.client.status().unwrap();
    assert_eq!(status.api_version, 1);
    assert_eq!(status.server_name, "devbox");
    assert!(status.last_scan_at.is_some());
    let after = f.client.refresh(true).unwrap();
    assert!(after.last_scan_at >= status.last_scan_at);
}

#[test]
fn dashboard_for_every_range() {
    let f = start();
    for range in TimeRange::ALL {
        for &granularity in range.granularities() {
            let d = f
                .client
                .dashboard(range, granularity, Local::now())
                .unwrap();
            assert_eq!(d.timeline.resolution, granularity.as_str(), "{range:?}");
            let bars = planmeter::chart::ChartData::build(&d.timeline);
            assert!(
                bars.bars.len() <= 1501,
                "{range:?} {granularity:?}: {} bars",
                bars.bars.len()
            );
            let timeline_cost: f64 = d.timeline.points.iter().map(|p| p.cost_usd).sum();
            assert!(
                (timeline_cost - d.summary.total.cost_usd).abs() < 1e-6,
                "{range:?}: chart and totals agree"
            );
            let model_cost: f64 = d.models.iter().map(|m| m.totals.cost_usd).sum();
            assert!(
                (model_cost - d.summary.total.cost_usd).abs() < 1e-6,
                "{range:?}: models and totals agree"
            );
        }
    }
    let d = f
        .client
        .dashboard(TimeRange::Today, Resolution::Hour, Local::now())
        .unwrap();
    assert!(d.summary.minutes.is_some(), "Today is a sub-day window");
    assert_eq!(d.limits.accounts.len(), 2);
    assert_eq!(d.accounts.accounts.len(), 5);
    assert!(d.remote.is_some());
    assert!(d.threshold().is_some(), "the mock has a Today limit");
}

#[test]
fn settings_round_trip() {
    let f = start();
    let settings = f
        .client
        .set_group("codex:plan:personal", Some(PlanGroup::Work))
        .unwrap();
    assert_eq!(
        settings.group_overrides.get("codex:plan:personal"),
        Some(&PlanGroup::Work)
    );
    let accounts = f.client.accounts().unwrap();
    let moved = accounts
        .accounts
        .iter()
        .find(|a| a.id == "codex:plan:personal")
        .unwrap();
    assert_eq!(moved.group, "work");
    let settings = f.client.set_group("codex:plan:personal", None).unwrap();
    assert!(settings.group_overrides.is_empty());

    let mut thresholds = BTreeMap::new();
    thresholds.insert("quarter".to_string(), SpendThreshold::new(5000.0, 90.0));
    let settings = f
        .client
        .set_spend(Some(vec!["work".into()]), Some(thresholds))
        .unwrap();
    assert_eq!(settings.spend_groups, vec!["work".to_string()]);
    assert_eq!(
        settings.threshold("quarter"),
        Some(SpendThreshold::new(5000.0, 90.0))
    );
    assert!(
        settings.threshold("today").is_none(),
        "thresholds replace the whole map"
    );
    // Groups alone leave thresholds unchanged.
    let settings = f
        .client
        .set_spend(Some(vec!["personal".into(), "work".into()]), None)
        .unwrap();
    assert!(settings.threshold("quarter").is_some());

    let err = f.client.set_spend(Some(vec![]), None).unwrap_err();
    assert!(
        matches!(err, ClientError::Http { status: 400, .. }),
        "{err:?}"
    );
    assert!(err.to_string().contains("at least one plan group"));
}

#[test]
fn remote_pairing_flow() {
    let f = start();
    let remote = f.client.remote().unwrap();
    assert!(remote.is_listening());
    assert_eq!(remote.devices.len(), 3);
    let with_invite = f.client.create_invite().unwrap();
    let invite = with_invite.invite.expect("invite");
    assert!(invite.expires_at > chrono::Utc::now());
    assert!(f.client.cancel_invite().unwrap().invite.is_none());
    let after = f.client.revoke_device(&remote.devices[0].id).unwrap();
    assert_eq!(after.devices.len(), 2);
    let err = f.client.revoke_device("does not exist").unwrap_err();
    assert!(matches!(err, ClientError::Http { status: 404, .. }));
    let off = f
        .client
        .set_remote(&RemoteSettingsBody {
            enabled: Some(false),
            ..Default::default()
        })
        .unwrap();
    assert!(!off.enabled && !off.is_listening());
    assert!(matches!(
        f.client.create_invite().unwrap_err(),
        ClientError::Http { status: 409, .. }
    ));
    let https = f
        .client
        .set_remote(&RemoteSettingsBody {
            enabled: Some(true),
            https_enabled: Some(false),
            port: Some(8800),
        })
        .unwrap();
    assert_eq!(https.port, 8800);
    assert!(!https.https.active && https.https.url.is_none());
}

#[test]
fn auto_pair_completes_an_invite() {
    let f = start();
    f.daemon.lock().unwrap().auto_pair_after = Some(0);
    f.client.create_invite().unwrap();
    let remote = f.client.remote().unwrap();
    assert!(remote.invite.is_none());
    assert_eq!(remote.devices.len(), 4);
}

#[test]
fn rpc_errors_surface() {
    let f = start();
    f.daemon.lock().unwrap().rpc_error = Some("Scan failed: permission denied".into());
    let err = f.client.limits().unwrap_err();
    assert_eq!(
        err,
        ClientError::Remote("Scan failed: permission denied".into())
    );
}

#[test]
fn stale_socket_is_unavailable() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("control.sock");
    // A socket file with nobody listening, as after a daemon crash.
    drop(UnixListener::bind(&socket).unwrap());
    let err = Client::new(&socket).status().unwrap_err();
    assert!(err.is_unavailable(), "{err:?}");
}
