//! Decodes every golden fixture with the app's models. Switching to the
//! canonical Swift-generated fixtures needs no code change: `fixtures_dir()`
//! prefers `protocol/fixtures/` once it exists.

mod common;

use common::{json_files, stem};
use planmeter::models::*;

fn read(path: &std::path::Path) -> Vec<u8> {
    std::fs::read(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

#[test]
fn every_reply_fixture_decodes() {
    let files = json_files("replies");
    assert!(!files.is_empty(), "no reply fixtures");
    let mut methods_seen = Vec::new();
    for path in files {
        let name = stem(&path);
        let reply: RemoteReply =
            serde_json::from_slice(&read(&path)).unwrap_or_else(|e| panic!("{name}: {e}"));
        let set = [
            reply.summary.is_some(),
            reply.models.is_some(),
            reply.timeline.is_some(),
            reply.limits.is_some(),
            reply.accounts.is_some(),
            reply.error.is_some(),
        ];
        assert_eq!(
            set.iter().filter(|s| **s).count(),
            1,
            "{name}: exactly one payload field must be set"
        );
        for method in RemoteMethod::ALL {
            if name.starts_with(method.as_str()) {
                methods_seen.push(method);
            }
        }
        if name.starts_with("summary") {
            let s = reply.summary.as_ref().unwrap();
            let groups: f64 = s.groups.iter().map(|g| g.totals.cost_usd).sum();
            assert!(
                (groups - s.total.cost_usd).abs() < 0.01,
                "{name}: group costs add up to the total"
            );
            assert!(s.to > s.from, "{name}: window");
        }
        if name.starts_with("timeline") {
            let t = reply.timeline.as_ref().unwrap();
            let chart = planmeter::chart::ChartData::build(t);
            assert!(
                chart.bars.len() >= t.periods.len(),
                "{name}: zero-filled bars"
            );
            for p in &t.points {
                assert!(
                    t.accounts.iter().any(|a| a.id == p.account_id),
                    "{name}: point account {} is listed",
                    p.account_id
                );
            }
        }
        if name.starts_with("error") {
            assert!(!reply.error.as_deref().unwrap_or("").is_empty());
        }
    }
    for method in RemoteMethod::ALL {
        assert!(
            methods_seen.contains(&method),
            "missing a reply fixture for {}",
            method.as_str()
        );
    }
}

#[test]
fn every_control_fixture_decodes() {
    let files = json_files("control");
    assert!(!files.is_empty(), "no control fixtures");
    let mut kinds = Vec::new();
    for path in files {
        let name = stem(&path);
        let bytes = read(&path);
        // Names follow the endpoint: status, refresh, settings*, remote*, error*.
        let kind = if name.starts_with("status") || name.starts_with("refresh") {
            serde_json::from_slice::<DaemonStatus>(&bytes)
                .map(|s| assert!(s.api_version >= 1, "{name}"))
                .map_err(|e| e.to_string())
                .map(|_| "status")
        } else if name.starts_with("settings") {
            serde_json::from_slice::<HostSettings>(&bytes)
                .map(|s| {
                    for (range, t) in &s.spend_thresholds {
                        assert!(
                            planmeter::range::TimeRange::from_id(range).is_some(),
                            "{name}: range id {range}"
                        );
                        assert!(t.is_valid(), "{name}: threshold for {range}");
                    }
                })
                .map_err(|e| e.to_string())
                .map(|_| "settings")
        } else if name.starts_with("remote")
            || name.starts_with("invite")
            || name.starts_with("device")
        {
            serde_json::from_slice::<RemoteStatus>(&bytes)
                .map(|r| {
                    if let Some(invite) = &r.invite {
                        assert!(
                            invite.url.starts_with("planmeter://pair?"),
                            "{name}: invite url"
                        );
                    }
                })
                .map_err(|e| e.to_string())
                .map(|_| "remote")
        } else if name.starts_with("error") {
            serde_json::from_slice::<ErrorBody>(&bytes)
                .map(|e| assert!(!e.error.is_empty(), "{name}"))
                .map_err(|e| e.to_string())
                .map(|_| "error")
        } else {
            // A newer endpoint this client does not use yet: it must still be JSON.
            serde_json::from_slice::<serde_json::Value>(&bytes)
                .map(|_| "other")
                .map_err(|e| e.to_string())
        };
        kinds.push(kind.unwrap_or_else(|e| panic!("{name}: {e}")));
    }
    for required in ["status", "settings", "remote"] {
        assert!(
            kinds.contains(&required),
            "missing a {required} control fixture"
        );
    }
}

#[test]
fn swift_style_json_decodes() {
    // Swift's JSONEncoder omits nil optionals and sorts keys; extra fields from
    // newer hosts must be ignored.
    let json = br#"{"summary":null,"timeline":{"accounts":[{"group":"work","id":"a","name":"A","provider":"codex","providerName":"Codex"}],"days":1,"futureField":true,"periods":["2026-10-19T12:00:00Z"],"points":[{"accountId":"a","costUsd":1.25,"period":"2026-10-19T12:00:00Z","tokens":42}],"resolution":"hour"}}"#;
    let reply: RemoteReply = serde_json::from_slice(json).unwrap();
    let t = reply.timeline.unwrap();
    assert_eq!(t.points[0].cost_usd, 1.25);
    assert_eq!(t.points[0].baseline_cost_usd, None);
    assert_eq!(t.accounts[0].accent_color_hex, None);
    assert!(reply.summary.is_none());
}
