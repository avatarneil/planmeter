//! Development stand-in for `planmeterd`: serves the control API over the
//! same Unix socket with synthetic usage, so the GTK app can run anywhere.
//!
//!     mock-planmeterd [--socket PATH] [--delay-ms N] [--auto-pair SECS] [--rpc-error TEXT]

use planmeter::client::default_socket_path;
use planmeter::mock::{serve, MockDaemon};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn usage() -> ! {
    eprintln!("usage: mock-planmeterd [--socket PATH] [--delay-ms N] [--auto-pair SECS] [--rpc-error TEXT]");
    std::process::exit(2)
}

fn main() {
    let mut socket = default_socket_path();
    let mut delay = Duration::ZERO;
    let mut auto_pair = None;
    let mut rpc_error = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = || args.next().unwrap_or_else(|| usage());
        match arg.as_str() {
            "--socket" => socket = PathBuf::from(value()),
            "--delay-ms" => {
                delay = Duration::from_millis(value().parse().unwrap_or_else(|_| usage()))
            }
            "--auto-pair" => auto_pair = Some(value().parse().unwrap_or_else(|_| usage())),
            "--rpc-error" => rpc_error = Some(value()),
            "-h" | "--help" => usage(),
            _ => usage(),
        }
    }

    if let Some(dir) = socket.parent() {
        if let Err(e) = std::fs::create_dir_all(dir) {
            eprintln!("mock-planmeterd: cannot create {}: {e}", dir.display());
            std::process::exit(1);
        }
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    // A stale socket from an earlier run would make bind fail.
    if socket.exists() {
        let _ = std::fs::remove_file(&socket);
    }
    let listener = match UnixListener::bind(&socket) {
        Ok(l) => l,
        Err(e) => {
            eprintln!(
                "mock-planmeterd: cannot listen on {}: {e}",
                socket.display()
            );
            std::process::exit(1);
        }
    };
    let _ = std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600));

    let mut daemon = MockDaemon::new(chrono::Utc::now());
    daemon.auto_pair_after = auto_pair;
    daemon.rpc_error = rpc_error;
    eprintln!("mock-planmeterd: listening on {}", socket.display());
    serve(listener, Arc::new(Mutex::new(daemon)), delay);
}
