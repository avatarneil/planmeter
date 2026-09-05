# PlanMeter

A native macOS app that shows local AI coding-agent usage split by subscription: personal plans on
one side and work plans on the other. It reads Codex, Claude Code, Grok Build, and OpenCode usage,
and includes a CLI, a read-only MCP server, and optional iPhone, iPad, Apple Watch, and web clients.

**T3 Code is optional.** PlanMeter works by itself with each provider's standard home directory and
environment variables. When it finds T3 Code settings, it uses T3's provider instances to discover
additional account homes and preserve their names and colors.

PlanMeter reads local files and never modifies provider transcripts or credentials. Pricing is
fetched from LiteLLM and cached locally; remote access is off by default.

## Supported platforms

| Component | Supported platform | Notes |
| --- | --- | --- |
| Mac app, CLI, MCP server | macOS 14 or newer on Apple silicon | This is the required host. Intel Macs, Windows, and Linux are not currently supported. |
| iPhone/iPad companion | iOS/iPadOS 17 or newer | Optional; requires the Mac app and Tailscale. |
| Apple Watch app and complication | watchOS 10 or newer | Optional; receives data through the paired iPhone. |
| Web client | A current browser with WebCrypto and IndexedDB | Optional; intended for a Tailscale HTTPS URL served by the Mac app. |

## Requirements

For the Mac app, CLI, and MCP server:

- macOS 14 or newer.
- An Apple silicon Mac.
- Xcode 16 or newer, including the Swift 6 toolchain and command-line build tools.
- `make`, supplied by the Xcode command-line tools.

Sparkle 2 is the sole third-party Swift package dependency and provides signed, in-app macOS
updates. Tailscale is not needed for the desktop app, CLI, MCP server, or update checks. It is
required only for remote access:

- Install and connect either the Tailscale macOS app or the Homebrew `tailscale` package.
- The native iOS client only needs both devices on the same tailnet.
- The web client additionally needs MagicDNS and HTTPS certificates enabled for the tailnet so
  `tailscale serve` can provide a secure origin.

T3 Code is not a build or runtime dependency. The Claude Code, Codex, and OpenCode CLIs are only
consulted by the optional `make install-mcp` registration step.

## Quick start

From a checkout:

```sh
make test
make app
open dist/PlanMeter.app
```

`make app` creates an ad-hoc-signed local build. To copy it to `/Applications`, run `make install`.

The macOS app checks GitHub Releases for updates daily and presents an update when one is available.
Use **PlanMeter → Check for Updates…** to check immediately. Update archives are verified with both
Sparkle's EdDSA signature and Apple code signing before installation; automatic installation is off
by default.

### Signed macOS releases

Distributing the app outside the Mac App Store requires an Apple Developer Program membership and a
`Developer ID Application` certificate installed with its private key. The normal build remains
ad-hoc signed so contributors do not need Apple credentials. Maintainers can create a hardened,
timestamped build by passing their identity explicitly:

```sh
security find-identity -v -p codesigning
make signed-app SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
```

Before publishing, archive the app, submit it to Apple's notarization service, staple the accepted
ticket to the app, and recreate the archive so the stapled app is the GitHub Release asset:

```sh
make release-macos SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
```

This produces an Apple-Silicon-only, notarized ZIP, Sparkle appcast, and SHA-256 checksum under
`dist/`. Upload all three files to the matching GitHub Release; the app reads `appcast.xml` through
GitHub's stable `releases/latest/download` URL. Create the
`planmeter-notary` Keychain profile once with
`xcrun notarytool store-credentials planmeter-notary`. `VERSION` is the release source of truth;
`BUILD_NUMBER` is Sparkle's monotonically increasing comparison version. `make check-version`
verifies that the macOS app, iOS/watchOS targets, and MCP server are aligned before building or
testing. Sparkle's private EdDSA update key remains in the release maintainer's Keychain.

## What it reads

| Provider | Standalone location | How an account is identified |
| --- | --- | --- |
| Codex | `$CODEX_HOME`, otherwise `~/.codex`; reads `sessions` and `archived_sessions` | `rate_limits.plan_type` on every usage event, matched to the plan in `auth.json` |
| Claude Code | `$CLAUDE_CONFIG_DIR`, otherwise the standard `~/.claude` data | The transcript directory; identity from `.claude.json` when available |
| Grok Build | `$GROK_HOME`, otherwise `~/.grok`; reads `sessions/*/updates.jsonl` | One local account |
| OpenCode | `$XDG_DATA_HOME/opencode/opencode.db`, otherwise `~/.local/share/opencode/opencode.db` | One local account; token counts and cost per assistant message |

In standalone mode PlanMeter discovers one configured home per provider. If
`$T3CODE_HOME/userdata/settings.json` or `~/.t3/userdata/settings.json` contains T3 Code
`providerInstances`, those instances take precedence. This enables multiple Codex or Claude homes,
custom display names, colors, and disabled-provider settings. Cursor and Antigravity have no local
usage data and are listed as unsupported when they appear in T3 settings.

Environment overrides are naturally available to the CLI and MCP server. To use them with the Mac
app, launch the `PlanMeter` executable from that environment or expose the variables to GUI apps
with `launchctl setenv`; apps opened from Finder otherwise use the standard home locations.

Parsers are ports of T3 Code's `usageTranscripts.ts` (fork-copy suppression, duplicate token_count
suppression, per-content-block dedup for Claude, Grok cost pro-rating), so totals match T3's Usage
page where the inputs overlap. Pricing uses LiteLLM's `model_prices_and_context_window.json`, read
from T3 Code's cached copy when present and fetched directly otherwise.

## Limitations

- Two Codex logins on the same plan type (for example two Business seats) cannot be told apart in
  the transcripts and are shown as one account.
- Claude Code does not write subscription-window readings locally, so the Limits panel only covers
  Codex.
- Costs are API-equivalent token prices, not what a subscription charges.

## Menu bar

The app also installs a menu bar item showing spend. You can choose which plan groups and time
period are included in the pre-click total from the menu bar popover. Its popover lists Personal and Work
totals for the selected range, each account underneath, and the Codex weekly window per account,
with buttons to open the main window or quit. Data refreshes every five minutes while the app runs,
and the app keeps running in the menu bar after the main window is closed.

Choose **Set limit** in the popover to set a personal USD target for the menu bar total,
with a warning threshold (80% by default). Each menu bar period remembers its own limit;
the target follows whichever plan groups you select. The menu bar shows percent used and
a distinct status symbol. The popover shows progress, dollars remaining or over, and controls
to edit or remove the limit. Limits are optional and persist across launches. They compare
API-equivalent usage costs, not subscription bills, and do not block spending or send notifications.

## MCP server

`planmeter-mcp` (bundled at `PlanMeter.app/Contents/MacOS/planmeter-mcp`) is a stdio MCP server
over the same data, so an agent can answer "how much have I spent on my personal plan this week?"
without leaving the terminal. Tools:

| Tool             | Arguments                       | Returns                                                     |
| ---------------- | ------------------------------- | ----------------------------------------------------------- |
| `usage_summary`  | `days` (default 30)             | Totals by group (personal/work/other) and by account        |
| `usage_by_model` | `days`, `account` filter        | Per account × model rows sorted by cost                     |
| `usage_timeline` | `days`, `resolution` day/hour   | Cost and tokens per period with per-account breakdown       |
| `codex_limits`   | none                            | Latest Codex rate-limit windows per account                 |
| `accounts`       | none                            | Discovered accounts, scanned sources, and their status      |

`make install-mcp` registers it with Claude Code (user scope, both the default home and
`~/.claude_personal_home`), Codex (`~/.codex/config.toml`), and OpenCode
(`~/.config/opencode/opencode.json`) when those tools are present. Run `make install` first so the
bundled server exists at the path being registered. Results are JSON in both `content` text and
`structuredContent`. Python 3 is only needed when the script updates OpenCode's JSON configuration.

## iOS companion over Tailscale

`ios/PlanMeterMobile` is a SwiftUI iPhone/iPad app that shows the same dashboard by talking to the
Mac over your tailnet. It uses QR pairing with a single-use token, proof-of-possession on every
request, a replay cache, and Tailscale as the network layer.

**Mac side** (PlanMeter → Remote in the toolbar): turn on remote access, create a pairing code,
scan it from the phone. The Mac listens only on its Tailscale address (plus loopback for
same-machine clients such as the simulator) and refuses connections from any other source address.
Paired devices are listed with last-seen time and can be revoked.

**Security model**, layered on top of Tailscale's WireGuard tunnel:

- Identity keys live in the Secure Enclave on both ends: a P-256 key-agreement key on the Mac, a
  P-256 signing key on each phone. Only wrapped blobs touch disk.
- The QR code carries the Mac's public key, so the phone pins it; the pairing request carries the
  phone's public key encrypted to that pin, so the Mac pins the phone. Tokens are 256-bit,
  single use, expire in 5 minutes, and are compared in constant time. Five bad attempts cancel
  the code.
- Every request uses a fresh ephemeral ECDH key against the Mac's static key, HKDF-derived request
  and response keys, ChaCha20-Poly1305 with the request header as additional data, and an ECDSA
  signature over method, path, device id, timestamp, nonce, ephemeral key, and ciphertext hash.
  Timestamps must be within two minutes; nonces are remembered for the window. A captured request
  cannot be replayed or decrypted later.
- Responses are encrypted under the per-request response key, so only the requester can read them
  and only the Mac could have produced them.
- Optional Face ID / passcode lock on the phone; server records only public keys.

### Web client (no install)

The Mac also serves a mobile-first web version of the same dashboard from `Sources/PlanMeter/Web`
(plain HTML/CSS/JS, no dependencies, strict Content Security Policy). Browsers only expose WebCrypto
on secure origins, so turn on **Tailscale HTTPS** in the Remote sheet: PlanMeter runs
`tailscale serve --bg --https=443 http://127.0.0.1:<port>`, and the page is published at
`https://<machine>.<tailnet>.ts.net/`, tailnet-only, with a certificate Tailscale issues. Pick
**Web** above the QR code and scan it with the phone's camera; the pairing data rides in the URL
fragment, so it never reaches server logs. To install it on iPhone, open that HTTPS page in Safari,
tap Share → **Add to Home Screen**, leave **Open as Web App** enabled, and tap **Add**.

If the Home Screen app is already open and unpaired, create a web pairing code on the Mac and enter
the eight digits shown below the QR into the app, or use the in-app scanner. The scanner decodes
camera frames locally; it also accepts a photo or pasted pairing link. The short code is random,
expires in five minutes, is cancelled after five incorrect attempts, and is accepted only over the
tailnet. It releases the same single-use invite over Tailscale HTTPS; the signed, encrypted pairing
exchange is unchanged.

The browser uses the same protocol as the iOS app with AES-256-GCM instead of ChaCha20-Poly1305
(WebCrypto has no ChaCha), and keeps a non-extractable ECDSA key in IndexedDB. Each browser pairs
separately, and adding the page to the Home Screen creates a new storage container, so pair again
from there if you want it as a standalone app. The web version trusts the tailnet for code delivery
in a way the native app does not, which is why Tailscale Serve's TLS matters.

### Apple Watch

`ios/PlanMeterMobile/PlanMeterWatch` is a watchOS companion embedded in the iPhone app, with a
WidgetKit complication (`PlanMeterWatchWidget`) for today's spend, Personal vs Work, or the top
Codex window as a gauge. Apple Watch has no Tailscale and its traffic does not use the phone's VPN,
so the watch never talks to the Mac: the iPhone app fetches over the encrypted channel and relays a
compact summary (`PlanMeterWatchShared.WatchPayload`) over Watch Connectivity, which Apple encrypts
between the paired devices. The watch holds no pairing keys. Pages: today and the Personal/Work
split, Codex limits as gauges, and the per-account list; the refresh button asks the phone to fetch
from the Mac right then. The complication reads the last payload from the shared app group
`group.com.neilgoldader.planmeter`, so both watch targets need that App Group capability under your
team (Xcode's automatic signing registers it).

**Installing on your phone**: open `ios/PlanMeterMobile/PlanMeterMobile.xcodeproj` in Xcode, pick
your team under Signing & Capabilities, and run on the device. The phone needs the Tailscale app
connected to the same tailnet. Simulator builds work without a team. For a signed device build you
may need to replace the `com.neilgoldader.planmeter` bundle-ID and App Group prefixes with identifiers
owned by your Apple Developer team; keep the App Group value consistent across the watch targets and
`PlanMeterWatchShared.WatchPayload`.

**Simulator testing**: macOS cannot connect to its own Tailscale address, so the Mac also binds
loopback. `PlanMeter --pairing-link` prints a tailnet pairing URL and a loopback variant with the
same token; a debug build of the iOS app accepts `--pair-url <url>` at launch so
`xcrun simctl launch booted com.neilgoldader.planmeter.mobile --pair-url "<loopback url>"` pairs
without the system's "Open in PlanMeter?" prompt. If codesign complains about "detritus", run
`xattr -cr .` to strip extended attributes from source files.

## Build and development

```sh
make test         # unit tests for the parsers, pricing, aggregation, and the secure channel
make app          # release build wrapped in dist/PlanMeter.app (ad-hoc signed)
make signed-app SIGNING_IDENTITY='Developer ID Application: Name (TEAMID)'
make release-macos SIGNING_IDENTITY='Developer ID Application: Name (TEAMID)'
make run          # build and open
make install      # copy to /Applications (quits a running copy first)
make install-mcp  # register the bundled MCP server with Claude Code, Codex, OpenCode
```

Handy flags on the app binary: `--snapshot out.png [--size WxH]` renders the main window and
exits; `--snapshot-menu out.png` renders the menu bar popover. `planmeter-cli --days N [--json]`
prints the same numbers in the terminal.

CI runs the Swift test suite, produces the macOS app bundle, and compiles the iOS/watchOS project for
the simulator. Tests can read locally installed provider data only when explicitly exercised; the
unit suite does not require provider credentials or T3 Code.

## Layout

- `Sources/PlanMeterCore` – account discovery, transcript parsers, pricing, scan cache, aggregation.
- `Sources/PlanMeter` – SwiftUI app: summary cards, Swift Charts timeline, model breakdown table,
  Codex limits, sources panel, account grouping sheet, menu bar popover.
- `Sources/PlanMeterRemote` – platform-neutral wire models, pairing, Secure Enclave key wrappers,
  and the encrypted request/response channel shared by the Mac server and the iOS app.
- `Sources/PlanMeter/Remote` – the Mac's tailnet-bound HTTP server, pairing state, and Remote sheet.
- `ios/PlanMeterMobile` – the iOS companion, watchOS app, and watch complication (one Xcode
  project referencing this package). `Sources/PlanMeterWatchShared` – the phone-to-watch payload.
- `Sources/PlanMeterMCP` – stdio MCP server. `Sources/PlanMeterCLI` – terminal report.
- `Tests/PlanMeterCoreTests` – parser and pricing fixtures.
- `scripts/bundle.sh` – wraps the three binaries in an `.app`; `scripts/install-mcp.sh` registers
  the MCP server with each agent; `scripts/release-macos.sh` signs, notarizes, and packages an
  Apple Silicon GitHub Release artifact.

## Privacy and security

PlanMeter reads local transcript and identity files to attribute usage. It stores its scan cache,
pricing cache, group choices, and remote-pairing state under the current user's Application Support
directory. Do not publish those local files or pairing links. Remote access is opt-in and restricted
to Tailscale or loopback peers; see the security model above before enabling it.

Please report suspected vulnerabilities through GitHub's private vulnerability reporting. If it is
not available, open an issue requesting a private contact channel without including vulnerability
details.

## License

PlanMeter is available under the MIT License; see [LICENSE](LICENSE). The vendored jsQR copy is
licensed under Apache License 2.0; see
[Sources/PlanMeter/Web/jsqr.LICENSE](Sources/PlanMeter/Web/jsqr.LICENSE).
