//! Decodes every golden fixture with the app's models. Switching to the
//! canonical Swift-generated fixtures needs no code change: `fixtures_dir()`
//! prefers `protocol/fixtures/` once it exists.

mod common;

use common::{json_files, stem};
use planmeter::client::{Client, ClientError};
use planmeter::http::{self, decode_segment};
use planmeter::models::*;
use planmeter::range::TimeRange;
use serde::Deserialize;
use serde_json::Value;
use std::os::unix::net::UnixListener;

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

/// A control fixture: one request and the daemon's answer.
#[derive(Debug, Deserialize)]
struct Exchange {
    request: FixtureRequest,
    response: FixtureResponse,
}

#[derive(Debug, Deserialize)]
struct FixtureRequest {
    method: String,
    path: String,
    #[serde(default)]
    body: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct FixtureResponse {
    status: u16,
    #[serde(default)]
    body: Value,
}

fn exchanges() -> Vec<(String, Exchange)> {
    let files = json_files("control");
    assert!(!files.is_empty(), "no control fixtures");
    files
        .iter()
        .map(|path| {
            let name = stem(path);
            let exchange =
                serde_json::from_slice(&read(path)).unwrap_or_else(|e| panic!("{name}: {e}"));
            (name, exchange)
        })
        .collect()
}

fn segments(path: &str) -> Vec<String> {
    path.split('?')
        .next()
        .unwrap_or(path)
        .trim_matches('/')
        .split('/')
        .map(decode_segment)
        .collect()
}

#[test]
fn every_control_fixture_decodes() {
    let mut kinds = Vec::new();
    for (name, ex) in exchanges() {
        let body = ex.response.body.clone();
        if !(200..300).contains(&ex.response.status) {
            let e: ErrorBody =
                serde_json::from_value(body).unwrap_or_else(|e| panic!("{name}: {e}"));
            assert!(!e.error.is_empty(), "{name}: error message");
            kinds.push("error");
            continue;
        }
        let segs = segments(&ex.request.path);
        let segs: Vec<&str> = segs.iter().map(String::as_str).collect();
        let kind = match segs.as_slice() {
            ["v1", "status"] | ["v1", "refresh"] => {
                let s: DaemonStatus =
                    serde_json::from_value(body).unwrap_or_else(|e| panic!("{name}: {e}"));
                assert!(s.api_version >= 1, "{name}");
                "status"
            }
            ["v1", "settings", ..] => {
                let s: HostSettings =
                    serde_json::from_value(body).unwrap_or_else(|e| panic!("{name}: {e}"));
                for (range, t) in &s.spend_thresholds {
                    assert!(
                        TimeRange::from_id(range).is_some(),
                        "{name}: range id {range}"
                    );
                    assert!(t.is_valid(), "{name}: threshold for {range}");
                }
                "settings"
            }
            ["v1", "remote", ..] => {
                let r: RemoteStatus =
                    serde_json::from_value(body).unwrap_or_else(|e| panic!("{name}: {e}"));
                if let Some(invite) = &r.invite {
                    assert!(
                        invite.url.starts_with("planmeter://pair?"),
                        "{name}: invite url"
                    );
                }
                "remote"
            }
            ["v1", "rpc"] => {
                let reply: RemoteReply =
                    serde_json::from_value(body).unwrap_or_else(|e| panic!("{name}: {e}"));
                assert!(
                    reply.error.is_some() || reply != RemoteReply::default(),
                    "{name}: empty reply"
                );
                "rpc"
            }
            // A newer endpoint this client does not use yet.
            _ => "other",
        };
        kinds.push(kind);
    }
    for required in ["status", "settings", "remote", "rpc", "error"] {
        assert!(
            kinds.contains(&required),
            "missing a {required} control fixture"
        );
    }
}

/// Numbers compare by value: `25` and `25.0` are the same JSON number to Swift.
fn normalize(v: Value) -> Value {
    match v {
        Value::Number(n) => serde_json::json!(n.as_f64()),
        Value::Array(a) => Value::Array(a.into_iter().map(normalize).collect()),
        Value::Object(o) => Value::Object(o.into_iter().map(|(k, v)| (k, normalize(v))).collect()),
        other => other,
    }
}

fn from<T: serde::de::DeserializeOwned>(v: Value) -> T {
    serde_json::from_value(v).expect("fixture request body")
}

/// Issues the client call that produces this fixture's request.
fn call(client: &Client, req: &FixtureRequest) -> Result<(), ClientError> {
    let body = req.body.clone().unwrap_or(Value::Null);
    let segs = segments(&req.path);
    let segs: Vec<&str> = segs.iter().map(String::as_str).collect();
    match (req.method.as_str(), segs.as_slice()) {
        ("GET", ["v1", "status"]) => client.status().map(drop),
        ("POST", ["v1", "refresh"]) => client
            .refresh(body["forceAccountUsage"].as_bool().unwrap_or(false))
            .map(drop),
        ("POST", ["v1", "rpc"]) => client.rpc(&from(body)).map(drop),
        ("GET", ["v1", "settings"]) => client.settings().map(drop),
        ("PUT", ["v1", "settings", "groups", id]) => {
            let b: GroupOverrideBody = from(body);
            client.set_group(id, b.group).map(drop)
        }
        ("PUT", ["v1", "settings", "spend"]) => {
            let b: SpendSettingsBody = from(body);
            client.set_spend(b.groups, b.thresholds).map(drop)
        }
        ("GET", ["v1", "remote"]) => client.remote().map(drop),
        ("PUT", ["v1", "remote"]) => client.set_remote(&from(body)).map(drop),
        ("POST", ["v1", "remote", "invite"]) => client.create_invite().map(drop),
        ("DELETE", ["v1", "remote", "invite"]) => client.cancel_invite().map(drop),
        ("DELETE", ["v1", "remote", "devices", id]) => client.revoke_device(id).map(drop),
        _ => {
            let response = client.send(&req.method, &req.path, None)?;
            if response.is_success() {
                Ok(())
            } else {
                Err(ClientError::Http {
                    status: response.status,
                    message: String::new(),
                })
            }
        }
    }
}

/// Replays every control fixture against the real client over a socket: the
/// client must send exactly the fixture's request and accept its response.
#[test]
fn client_requests_match_control_fixtures() {
    let dir = tempfile::tempdir().unwrap();
    for (name, ex) in exchanges() {
        let socket = dir.path().join(format!("{name}.sock"));
        let listener = UnixListener::bind(&socket).unwrap();
        let status = ex.response.status;
        let response_body = serde_json::to_vec(&ex.response.body).unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let request = http::read_request(&stream).unwrap();
            http::write_response(&mut stream, status, &response_body).unwrap();
            request
        });
        let result = call(&Client::new(&socket), &ex.request);
        let sent = server.join().unwrap();

        assert_eq!(sent.method, ex.request.method, "{name}: method");
        assert_eq!(sent.path, ex.request.path, "{name}: path");
        let sent_body: Value = if sent.body.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&sent.body)
                .unwrap_or_else(|e| panic!("{name}: client sent invalid JSON: {e}"))
        };
        let expected = ex.request.body.clone().unwrap_or(Value::Null);
        assert_eq!(
            normalize(sent_body),
            normalize(expected),
            "{name}: request body"
        );
        match (&result, (200..300).contains(&status)) {
            (Ok(()), true) => {}
            (Err(ClientError::Http { status: s, .. }), false) => assert_eq!(*s, status, "{name}"),
            other => panic!("{name}: unexpected client result {other:?}"),
        }
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
