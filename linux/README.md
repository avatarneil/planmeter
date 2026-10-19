# PlanMeter for Linux

A native GNOME app for PlanMeter, written in Rust with GTK 4 and libadwaita. It shows
spend, tokens, cache savings, and Codex rate limits per account, split into Personal and
Work plans, and manages remote access for phones over Tailscale.

The app does not read transcripts itself. It is a client of `planmeterd`, the headless
PlanMeter host, over the local control socket described in
[`docs/cross-platform.md`](../docs/cross-platform.md#local-control-api-planmeterd--desktop-ui).
Run `planmeterd` as a systemd user service, or use the bundled mock daemon for development.

## Features

- **Dashboard**: total spend for the last hour, today, or the last 24 hours, 7, 30, or
  90 days, with today's spend, tokens, cached-input share, cache savings, and sessions.
- **Spend limit** progress for the selected range (teal, amber, coral as on the Mac), and a
  desktop notification when the spend total reaches the warning level or the limit, once
  per crossing per period.
- **Personal / Work / Other** cards with each account's spend in its accent color.
- **Timeline**: stacked bars per account, drawn with Cairo, with a bucket-size menu
  (1 min to 1 day, at most about 1,500 bars per range, as on the Mac and iPhone), hover
  highlight, tooltips, a legend, and a screen-reader summary. Untimed workspace credits
  are drawn as lighter bars.
- **Models** (cost, tokens, cached share, unpriced marker) and **Codex limits** with reset
  times.
- **Accounts** with their plan group, the scanned sources, and the daemon's status.
- **Remote**: turn the tailnet listener on or off, see the tailnet address and MagicDNS
  name, change the port, toggle HTTPS with Tailscale Serve, show pairing QR codes for the
  PlanMeter app and the web app (plus the 8-digit code for an already open web app) with a
  countdown, and revoke paired devices.
- **Preferences**: which plan groups count toward the spend total, spend limits and
  warning levels per range, alerts on or off, and per-account plan groups.
- Adaptive down to 360 px wide (phones running GNOME, small windows): sections stack and
  the page switcher moves to a bottom bar.
- Light and dark styles follow the system.

If `planmeterd` is not running, the app explains how to start it and offers a
**Start Service** button that runs `systemctl --user start planmeterd`, falling back to
`planmeterd` on `PATH`.

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Ctrl+R, F5 | Refresh (rescans transcripts and account-wide usage) |
| Alt+1 … Alt+6 | Last hour, Today, 24 hours, 7, 30, 90 days |
| Ctrl+, | Preferences |
| F10 | Main menu |
| Ctrl+W | Close window |
| Ctrl+Q | Quit |

## Requirements

- GTK 4.14 and libadwaita 1.5 or newer (Ubuntu 24.04 LTS, Debian 13, Fedora 40, or later).
- Rust 1.83 or newer to build.
- `planmeterd` from this repository (or `mock-planmeterd` for development).

Build dependencies:

```sh
# Debian / Ubuntu
sudo apt install libgtk-4-dev libadwaita-1-dev build-essential pkg-config
# Fedora
sudo dnf install gtk4-devel libadwaita-devel gcc pkgconf-pkg-config
```

## Build and run

```sh
cd linux
cargo build --release
./target/release/planmeter
```

The app finds the control socket at `$PLANMETER_CONTROL_SOCKET`, then
`$XDG_RUNTIME_DIR/planmeter/control.sock`, then `/tmp/planmeter-$UID/control.sock`, the
same order `planmeterd` uses. `--socket PATH` overrides it.

### With the mock daemon

`mock-planmeterd` serves the whole control API with deterministic synthetic usage for
five accounts, mutable settings, pairing invites, and device revoke:

```sh
cargo run --bin mock-planmeterd &
cargo run --bin planmeter
```

Options: `--socket PATH`, `--delay-ms N` (slow RPCs), `--auto-pair SECS` (a device
"scans" the invite after that many seconds), `--rpc-error TEXT` (every report fails).

### Install for the current user

```sh
cargo build --release
install -Dm755 target/release/planmeter ~/.local/bin/planmeter
install -Dm644 data/com.neilgoldader.PlanMeter.desktop -t ~/.local/share/applications
install -Dm644 data/com.neilgoldader.PlanMeter.metainfo.xml -t ~/.local/share/metainfo
install -Dm644 data/icons/hicolor/scalable/apps/com.neilgoldader.PlanMeter.svg -t ~/.local/share/icons/hicolor/scalable/apps
install -Dm644 data/icons/hicolor/symbolic/apps/com.neilgoldader.PlanMeter-symbolic.svg -t ~/.local/share/icons/hicolor/symbolic/apps
```

### Flatpak (local, unpublished)

```sh
flatpak install flathub org.gnome.Sdk//49 org.freedesktop.Sdk.Extension.rust-stable//25.08
flatpak-builder --user --install --force-clean build-dir flatpak/com.neilgoldader.PlanMeter.yml
flatpak run com.neilgoldader.PlanMeter
```

The sandbox reaches `planmeterd` through `$XDG_RUNTIME_DIR/planmeter` and starts it on
the host with `flatpak-spawn --host`. The `/tmp/planmeter-$UID` fallback socket is not
visible inside the sandbox, so run the daemon with `XDG_RUNTIME_DIR` set (systemd user
services always have it).

## Development in Docker

Everything builds in containers; nothing needs installing on the host. `docker/dev.sh`
builds `planmeter-linux-dev` (Debian trixie: GTK 4.18, libadwaita 1.7) and runs a command
in it, keeping Cargo's registry and `target/` in named volumes:

```sh
docker/dev.sh cargo fmt --check
docker/dev.sh cargo clippy --all-targets -- -D warnings
docker/dev.sh cargo test
SHOTS=/tmp/planmeter-shots docker/dev.sh docker/screenshots.sh
```

`docker/screenshots.sh` starts the mock daemon and renders the dashboard (light, dark,
narrow), the Remote page with a live pairing code, Preferences, the revoke confirmation,
About, the daemon-unavailable page, and **Start Service** recovering through a
`planmeterd` on `PATH`, to `$SHOTS/linux-*.png`.

`docker/Dockerfile.ubuntu-24.04` builds and tests against the runtime floor (GTK 4.14,
libadwaita 1.5) with Rust from rustup:

```sh
docker build -t planmeter-linux-ubuntu2404 -f docker/Dockerfile.ubuntu-24.04 docker
docker run --rm -v "$PWD/..":/src -w /src/linux -e CARGO_TARGET_DIR=/target \
  -v planmeter-linux-target-ubuntu:/target planmeter-linux-ubuntu2404 cargo test --locked
```

### Screenshots

`planmeter --screenshot FILE.png` renders the window offscreen and exits, like the Mac
app's `--snapshot`:

```sh
planmeter --screenshot out.png [--size 1200x800] [--page dashboard|accounts|remote|preferences] \
  [--range today] [--dark] [--pair] [--action app.about] [--delay 900]
```

It needs a display; in containers run it under `xvfb-run` and `dbus-run-session`.
Screenshot runs never write the saved preferences.

## Tests

- `src/*.rs` unit tests: models (dates, optional fields), HTTP framing (content length,
  chunked, garbage), range windows and request shapes, chart stacking, ticks, and hit
  testing, formatting, spend-alert crossings, and the mock daemon.
- `tests/client_mock.rs`: the socket client against the mock on a temporary socket, for
  every range and granularity, settings, remote access, pairing, and errors.
- `tests/fixtures.rs`: the golden fixtures from [`protocol/`](../protocol/README.md),
  generated by the Swift implementation. Every `protocol/fixtures/replies/*.json` must
  decode as a `RemoteReply`, with checks per method (totals add up, the timeline's
  60-minute window and untimed baselines render as the chart expects). Every control
  request/response exchange must decode, and is replayed through the real client over a
  socket, which must send exactly the fixture's method, path (percent-encoded ids), and
  body. Control exchanges come from `protocol/fixtures/control/`, generated by
  `planmeterd`'s tests. `PLANMETER_FIXTURES=dir` points both at another directory.

## How the app uses the control API

| Screen | Requests |
| --- | --- |
| Every refresh (30 s while visible, on focus, Ctrl+R) | `GET /v1/status`, `GET /v1/settings`, `GET /v1/remote`, and `POST /v1/rpc` with `summary`, `timeline`, `models`, `limits`, `accounts`, in parallel |
| Refresh button | `POST /v1/refresh` `{"forceAccountUsage": true}` first |
| Range | 1 hour: `minutes: 60`. Today: `minutes` from local midnight to the next five-minute boundary. 24 hours: `days: 1`. 7/30/90 days: `days` |
| Bucket size | `timeline.resolution`: `minute`, `5m`, `15m`, `hour`, `day` |
| Preferences, spend | `PUT /v1/settings/spend` with `groups` or the full `thresholds` map |
| Preferences, plan groups | `PUT /v1/settings/groups/{accountId}` with `{"group": … \| null}` |
| Remote switches, port | `PUT /v1/remote` |
| Pair a Device, Cancel | `POST` / `DELETE /v1/remote/invite`; polls `GET /v1/remote` every 3 s while a code is showing |
| Revoke | `DELETE /v1/remote/devices/{id}` after confirmation |

Desktop-only preferences (range, bucket sizes, window size, alert history) live in
`$XDG_STATE_HOME/planmeter/desktop.json`.

## Layout

```
linux/
  Cargo.toml, build.rs        crate; build.rs bundles data/ as a GResource
  src/lib.rs                  GTK-free core, unit tested
    models.rs                 RemoteReply, control API types (tolerant serde)
    client.rs                 HTTP/1.1 over UnixStream, socket path, dashboard fetch
    http.rs                   request/response framing (client and mock)
    range.rs                  TimeRange ids, windows, granularities, requests
    chart.rs                  bars, stacking, ticks, hit testing
    format.rs                 currency, tokens, percent, relative time, colors
    notify.rs                 spend-alert crossings
    mock.rs                   mock daemon
  src/main.rs, src/ui/        GTK 4 / libadwaita UI
  src/bin/mock-planmeterd.rs  mock daemon binary
  tests/                      integration tests and sample fixtures
  data/                       desktop entry, AppStream metainfo, icons, CSS
  flatpak/                    Flatpak manifest
  docker/                     dev image, Ubuntu 24.04 floor image, screenshot script
```
