# Cross-platform PlanMeter

Status: exploration, landing as a PR stack. Nothing here changes the macOS, iOS, or watchOS
apps' behavior, signing, or release process.

## Goals

- Run the PlanMeter host (the part that reads transcripts) on **Linux** as well as macOS,
  with Windows as a later target.
- Add an **Android** companion alongside the iPhone/iPad/Watch apps.
- Every client stays native to its platform and as fast as the Apple apps are today: no
  web-view shells, no shared cross-platform widget toolkit.
- Linux and Android use **Tailscale** for remote access. iCloud stays Apple-only; a
  non-Tailscale sync path for other platforms is out of scope for now (see
  [Sync](#sync-beyond-tailscale)).

## Non-goals (for this stack)

- Merging, releasing, or publishing packages (Flathub, Play Store, apt repositories).
- Replacing any Apple UI. SwiftUI stays the UI on macOS, iOS, and watchOS.
- Windows UI. The architecture leaves room for it; the work is not scheduled.

## Platform matrix

| Platform | Role | Language / UI | Data source | Remote access |
| --- | --- | --- | --- | --- |
| macOS 14+ | Host + UI | Swift, SwiftUI (unchanged) | In-process `PlanMeterCore` | Tailscale, iCloud |
| Linux (x86-64, arm64) | Host daemon | Swift, `planmeterd` (headless) | In-process `PlanMeterCore` | Tailscale |
| Linux desktop | UI | Rust, GTK 4 + libadwaita | Local control socket to `planmeterd` | – |
| Windows (later) | Host + UI | Swift daemon; WinUI 3 UI | Local control pipe to `planmeterd` | Tailscale |
| iOS / iPadOS / watchOS | Companion | Swift, SwiftUI (unchanged) | Remote API | Tailscale, iCloud |
| Android 9+ | Companion | Kotlin, Jetpack Compose, Glance | Remote API | Tailscale |
| Web | Companion | Plain JS (unchanged) | Remote API | Tailscale HTTPS |

## Architecture

```
                 ┌──────────────── host (macOS / Linux / Windows) ────────────────┐
 transcripts ──▶ │ PlanMeterCore ─▶ PlanMeterHost (report builder, pairing, RPC)  │
 (~/.codex,      │      │                 │                     │                  │
  ~/.claude ...) │  CLI / MCP     macOS: SwiftUI app     Linux: planmeterd        │
                 │                (in-process)           ├─ control socket ──▶ GTK app
                 │                                        └─ tailnet HTTP  ─┐      │
                 └──────────────────────────────────────────────────────────┼─────┘
                                       end-to-end encrypted RPC (v1)        │
                        ┌───────────────────────┬──────────────────────────┤
                    iOS / Watch (Swift)     Android (Kotlin)          Web (JS)
```

### Decision: keep Swift for the shared core

Rust would be the natural choice for a cross-platform core in a new project: first-class
Linux, Windows, and Android toolchains, mature GTK bindings, and UniFFI for Swift and Kotlin
bindings. PlanMeter is not a new project. `PlanMeterCore` is about 5,000 lines of tested
accounting logic: transcript dedup rules ported from T3 Code, workspace-credit hour
distribution, Codex cloud-turn joins, and pricing. A Rust port would leave two choices,
both worse than staying put:

1. Keep the Swift core on Apple platforms and a Rust core elsewhere. Totals would drift
   between a Mac and a Linux box reading the same transcripts.
2. Move the Mac and iOS apps onto the Rust core through FFI. That rewrites the most
   mature clients for no user-visible gain and adds a second toolchain to every Apple build.

Swift ships official toolchains for Linux and Windows, and swift-foundation gives one
Foundation implementation across them. The core's Apple-only dependencies are small and
all have portable equivalents:

| Apple-only today | Portable replacement |
| --- | --- |
| CryptoKit | [swift-crypto](https://github.com/apple/swift-crypto) (same API; Apple builds keep CryptoKit) |
| `import SQLite3` | system `libsqlite3` via a module map |
| `import Darwin` | `Glibc` / `Musl` / `ucrt` |
| `URLSession` in Foundation | `FoundationNetworking` on Linux |
| Network.framework listener | portable POSIX socket listener in `PlanMeterHost` (macOS keeps `NWListener`) |
| Secure Enclave keys | 0600 key files on Linux (same as the Mac's software-key fallback) |
| CloudKit | Apple-only; compiled out elsewhere |

**Rust is still used where it is the strongest native option: the GTK 4 / libadwaita UI on
Linux.** gtk4-rs and libadwaita-rs are the bindings most GNOME Circle apps use. No Swift
GTK binding is close in maturity. Because the Linux UI talks to `planmeterd` over a local
socket, the UI language is independent of the core.

### Decision: Jetpack Compose for Android, not React Native

React Native only pays off if it replaces more than one native UI. The iOS, watchOS, and
macOS apps stay SwiftUI (widgets, complications, and Watch connectivity have no RN
equivalent), and React Native has no supported Linux desktop target. RN would therefore
only cover Android, through a JavaScript bridge, while feeling less native than Compose.
Kotlin with Compose and Material 3 (dynamic color, Glance home-screen widgets, WorkManager
background refresh, Android Keystore keys) is the native choice and needs no third-party
crypto: P-256 ECDH, ECDSA, HKDF (HMAC-SHA256), and ChaCha20-Poly1305 are all in the
platform (`ChaCha20-Poly1305` requires API 28, hence Android 9+).

The remote protocol now has three independent implementations: Swift, JavaScript, and
Kotlin. Instead of sharing code through FFI, they share **golden test vectors** (see
[Protocol conformance](#protocol-conformance)). The protocol is about 500 lines, and each
implementation stays idiomatic and dependency-free.

### Decision: a headless daemon on Linux

On macOS the SwiftUI app is the host. On Linux the host is `planmeterd`, a headless Swift
executable run as a systemd user service, for three reasons:

- Coding agents often run on headless Linux dev boxes and servers. A daemon lets a phone
  read their usage over Tailscale without a desktop session.
- GNOME discourages background GUI processes; user services are the native way to keep
  something running.
- A stable local API gives every desktop UI (GTK now, WinUI later) the same thin-client
  shape, written in whatever is most native for that desktop.

`planmeter-cli` and `planmeter-mcp` keep scanning directly and do not need the daemon.

## Local control API (`planmeterd` ↔ desktop UI)

HTTP/1.1 over a Unix domain socket, one request per connection (`Connection: close`),
JSON bodies using the remote protocol's JSON conventions (`RemoteJSON`: ISO-8601 dates,
standard base64 for `Data`, sorted keys). Errors are non-2xx with `{"error": "…"}`.

Socket path, first match wins:

1. `$PLANMETER_CONTROL_SOCKET`
2. `$XDG_RUNTIME_DIR/planmeter/control.sock`
3. `/tmp/planmeter-$UID/control.sock`

The directory is created `0700` and the socket `0600`. On Linux the daemon also checks
`SO_PEERCRED` and refuses peers with a different UID. The control socket is never exposed
on the network; phones use the encrypted tailnet API.

| Method | Path | Body | Response |
| --- | --- | --- | --- |
| `GET` | `/v1/status` | – | `DaemonStatus` |
| `POST` | `/v1/refresh` | `{"forceAccountUsage": bool}` (optional) | `DaemonStatus` after the scan |
| `POST` | `/v1/rpc` | `RemoteRequest` | `RemoteReply` (the same payload phones decrypt) |
| `GET` | `/v1/settings` | – | `HostSettings` |
| `PUT` | `/v1/settings/groups/{accountId}` | `{"group": "personal" \| "work" \| "other" \| null}` | `HostSettings` |
| `PUT` | `/v1/settings/spend` | `{"groups": [String]?, "thresholds": {range: SpendThreshold}?}` | `HostSettings` |
| `GET` | `/v1/remote` | – | `RemoteStatus` |
| `PUT` | `/v1/remote` | `{"enabled": bool?, "httpsEnabled": bool?, "port": int?}` | `RemoteStatus` |
| `POST` | `/v1/remote/invite` | – | `RemoteStatus` with `invite` |
| `DELETE` | `/v1/remote/invite` | – | `RemoteStatus` |
| `DELETE` | `/v1/remote/devices/{id}` | – | `RemoteStatus` |

```jsonc
// DaemonStatus
{ "apiVersion": 1, "version": "0.3.6", "serverName": "devbox", "isScanning": false,
  "lastScanAt": "2026-10-19T12:00:00Z", "lastError": null, "pricingSource": "litellm",
  "pricingError": null, "accountCount": 4 }

// HostSettings: range ids match the Mac's TimeRange ids ("lastHour", "today", "day", "week", "month", "quarter")
{ "groupOverrides": { "<accountId>": "work" }, "spendGroups": ["personal", "work"],
  "spendThresholds": { "today": { "limit": 25, "warningPercent": 80 } } }

// RemoteStatus
{ "enabled": true, "port": 7787, "status": "listening", "bindAddresses": ["100.64.0.7"],
  "tailscale": { "available": true, "address": "100.64.0.7", "dnsName": "devbox.tail1234.ts.net" },
  "https": { "enabled": false, "active": false, "url": null, "certificateStatus": null },
  "devices": [ /* PairedDevice */ ],
  "invite": { "url": "planmeter://pair?…", "localUrl": "planmeter://pair?…", "webUrl": null,
              "webCode": "12345678", "expiresAt": "2026-10-19T12:05:00Z" },
  "log": ["…"] }
```

`RemoteRequest`, `RemoteReply`, `PairedDevice`, and `SpendThreshold` are the existing
Swift types. Additions must be backward compatible: new optional fields only. Breaking
changes bump `apiVersion` and the `/v1/` prefix together.

## Protocol conformance

`protocol/` holds a language-neutral description of the remote protocol and golden
fixtures generated by the Swift implementation:

- `protocol/fixtures/secure-channel/` contains deterministic key-derivation, header,
  AEAD, and signature vectors for both ciphers, for requests and responses.
- `protocol/fixtures/pairing/` contains pairing URLs (valid and invalid) and device-id
  derivation.
- `protocol/fixtures/replies/` contains a `RemoteReply` example for every `RemoteMethod`,
  plus an error reply.
- `protocol/fixtures/control/` contains a control API response example for every endpoint.

Swift tests regenerate the fixtures and fail if the committed files differ, so a protocol
change cannot go unnoticed. The Kotlin and Rust test suites read the same files. ECDSA
signatures are randomized, so vectors carry a known-good signature that implementations
must verify, rather than one they must reproduce.

## Linux specifics

- **Paths** follow XDG. Config goes in `$XDG_CONFIG_HOME/planmeter`, state (scan cache,
  pricing cache, paired devices, server key) in `$XDG_STATE_HOME/planmeter`, and the
  socket in `$XDG_RUNTIME_DIR`. Provider homes (`~/.codex`, `~/.claude`, `$XDG_DATA_HOME/opencode`)
  are unchanged.
- **Keys**: the server's P-256 key-agreement key is a software key in a `0600` file,
  matching the Mac's non-Enclave fallback. Secret Service or TPM wrapping can come
  later; it would not work on headless servers anyway.
- **Tailscale**: the daemon shells out to the `tailscale` CLI exactly as the Mac does,
  for status and `tailscale serve`. Linux can reach its own tailnet address, so a
  loopback listener is only needed for local testing.
- **Codex account-wide usage** looks for the Codex CLI on `PATH` and in common Linux
  install locations. Cloud-turn readings need `URLSessionWebSocketTask`, which depends on
  libcurl WebSocket support on Linux. When it is unavailable, that reading is labelled
  unavailable and local reporting continues.
- **Desktop integration** for the GTK app: an AdwApplicationWindow dashboard, GNotification
  for spend-limit crossings, a `.desktop` file, AppStream metainfo, and a Flatpak manifest
  (unpublished). A StatusNotifierItem tray icon is a follow-up; GNOME needs an extension
  to show it.
- **Packaging** (not published in this stack): systemd user unit for `planmeterd`,
  Flatpak for the GTK app, and a tarball for the daemon, CLI, and MCP server.

## Android specifics

- Pairing works by scanning the Mac/Linux QR code (CameraX + ZXing core, no Google Play
  services), by opening a `planmeter://pair` link, or by pasting the link.
- The device signing key is P-256 in the Android Keystore, StrongBox-backed when available.
  This is the counterpart of the iPhone's Secure Enclave key. The paired-server record is
  stored with encrypted preferences.
- The UI is a Compose dashboard matching the iPhone: range picker, totals, per-group and
  per-account breakdown, timeline chart (Compose Canvas), models, Codex limits, and accounts.
  It uses Material 3 with dynamic color, light and dark themes, and an optional biometric lock.
- A Glance home-screen widget shows today's spend and the Personal/Work split, refreshed by
  WorkManager (the platform minimum is 15 minutes).
- The app is Tailscale only: the phone needs the Tailscale Android app on the same tailnet.

## Sync beyond Tailscale

iCloud sync remains Apple-only. Options for Linux and Android, deferred:

1. A self-hosted relay that stores the same end-to-end-encrypted snapshot blob the Mac
   uploads to CloudKit. The server sees only ciphertext.
2. Writing the encrypted snapshot to a user-chosen synced folder (Syncthing, Dropbox,
   Google Drive) and reading it from Android through the Storage Access Framework.
3. Google Drive app-data folder for Android-only users.

All three can reuse `CloudSnapshot` as the payload and the existing device keys to encrypt it.

## Windows (later)

The Swift core and `planmeterd` should compile with the Swift for Windows toolchain once
the remaining `Glibc` and POSIX socket code gets `ucrt`/Winsock branches. The control API
would move to a named pipe (`\\.\pipe\planmeter-<user>`) with the same HTTP framing. The UI
would be WinUI 3 (C#) talking to the pipe. The tray (notification-area icon) is native there.

## Rollout (this stack)

1. **Design**: this document.
2. **Portable core**: `PlanMeterCore`, `PlanMeterRemote`, CLI, and MCP build and pass
   tests on Linux. Linux CI job.
3. **Protocol**: `protocol/` spec and golden fixtures, verified by Swift tests.
4. **Host + daemon**: `PlanMeterHost` extracted from the Mac app (report builder,
   pairing/RPC handling, portable listener), with `planmeterd` and the control API. The
   Mac app keeps its behavior and uses the shared code.
5. **Linux desktop app**: Rust GTK 4 / libadwaita client of the control API.
6. **Android app**: Kotlin/Compose companion with a Glance widget.
7. **CI and docs**: Linux and Android CI jobs, README platform table.
