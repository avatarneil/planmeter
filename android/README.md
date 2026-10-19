# PlanMeter for Android

A native Android companion for PlanMeter, written in Kotlin with Jetpack
Compose and Material 3. It reads AI coding-agent usage from PlanMeter on your
Mac (or a Linux host running `planmeterd`) over Tailscale, using the same
end-to-end encrypted protocol as the iPhone app. There is no iCloud mode.

- Dashboard: range picker (1h, Today/24h, 7d, 30d, 90d), spend and today's
  spend, tokens, cached share and cache savings, Personal/Work/Other cards with
  accounts, a stacked per-account cost chart with bucket sizes and
  tap-to-inspect, models, Codex limits, and accounts and sources.
- Refreshes every 30 seconds while open, plus pull to refresh.
- A home-screen widget with today's spend and the Personal/Work split.
- Optional fingerprint, face, or screen-lock protection.
- Two-pane layout on tablets and foldables, dynamic color on Android 12+,
  light and dark themes.

Requires Android 9 (API 28) or later, because the protocol's
ChaCha20-Poly1305 cipher is a platform API from API 28.

## Build

Everything builds in Docker; the host needs no JDK or Android SDK.

```sh
android/scripts/docker-gradle.sh                    # tests, lint, and the debug APK
android/scripts/docker-gradle.sh :app:assembleDebug # just the APK
```

The script runs `eclipse-temurin:21-jdk-noble` as `linux/amd64` (Android's
`aapt2` has no linux-arm64 build, so Apple silicon runs it under Rosetta or
QEMU). The Android SDK goes in the `planmeter-android-sdk` volume and the
Gradle cache in `planmeter-android-gradle`, so only the first run downloads
them. `scripts/ensure-android-sdk.sh` installs the command-line tools, accepts
the licenses, and installs the platform and build tools.

With a local JDK 21 and Android SDK (as in CI), run Gradle directly:

```sh
cd android
ANDROID_HOME=… scripts/ensure-android-sdk.sh
./gradlew :protocol:test :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
```

The APK is `android/app/build/outputs/apk/debug/app-debug.apk`. CI uploads it
as the `planmeter-android-debug` artifact.

## Install (sideload)

The debug APK is signed with the Android debug key.

- With USB debugging: `adb install -r android/app/build/outputs/apk/debug/app-debug.apk`
- Without a computer: copy the APK to the phone and open it. Android asks you to
  allow installs from that app (Files, Drive, a browser) the first time.

Release builds are minified but unsigned; there is no Play Store listing.

## Pair

1. Install [Tailscale](https://tailscale.com/download/android) on the phone and
   sign in to the same tailnet as your computer.
2. On the computer, open PlanMeter → Remote, turn on remote access, and create
   a pairing code.
3. In the app, scan the QR code. You can also open the `planmeter://pair?…`
   link on the phone, or paste it into the app.

Codes are single use and expire after five minutes. If pairing fails, the app
says why: an expired or used code, a host that rejected the code, or a host it
could not reach (usually Tailscale is off on one side, or the computer is
asleep).

To unpair, use Settings → Unpair, then revoke the phone on the computer
(PlanMeter → Remote → Paired devices) so its key can never reconnect.

## Widget and background refresh

The AI spend widget shows today's spend, the Personal/Work split, and when it
was last updated. After 15 minutes, or after midnight, it asks you to open the
app instead of showing an old total as today's. It refreshes after every fetch
in the app and from a WorkManager job every 15 minutes (the platform minimum;
Android may defer it). The job only runs while a widget is placed. As on the
iPhone, background refresh pauses while the app lock is on.

## Security

- The device key is a P-256 signing key in the Android Keystore, in StrongBox
  when the phone has a secure element and in the TEE otherwise. It never leaves
  the keystore. Settings shows where it lives.
- Each request uses a fresh ephemeral ECDH key, is sealed with
  ChaCha20-Poly1305 to the host key pinned at pairing, and is signed by the
  device key.
- The pairing record (host, port, name, pinned server key, device id) is in
  DataStore. Nothing is backed up or moved to a new phone
  (`allowBackup="false"`, `dataExtractionRules`), because the Keystore key
  cannot move either.
- Cleartext HTTP. The host listens on its tailnet address with plain HTTP
  (port 7787 by default); the transport is WireGuard and every payload is
  encrypted end to end. A network security config can match host names but
  not IP ranges, and pairing links may carry a raw `100.x.y.z` address, so
  cleartext cannot be limited to the tailnet in
  `res/xml/network_security_config.xml`. It is narrowed in code instead:
  `HostPolicy.tailnetOnly` refuses any host that does not resolve into
  100.64.0.0/10 or fd7a:115c:a1e0::/48 before sending a request. Debug builds
  also allow loopback and `10.0.2.2`, for the emulator. The app has no other
  HTTP client, no WebView, and no third-party SDKs.

## Development

| Module | Contents |
| --- | --- |
| `protocol` | Pure Kotlin/JVM: wire models (kotlinx.serialization), pairing links, `SecureChannel`, and an `HttpURLConnection` `RemoteClient`. Platform JCA only. |
| `app` | Compose UI, Keystore signer, DataStore, Glance widget, WorkManager job. |
| `interop` | A SwiftPM harness that checks the Kotlin protocol against `Sources/PlanMeterRemote`. See [interop/README.md](interop/README.md). |

Protocol notes:

- Signatures are raw `r || s` (64 bytes) on the wire, as CryptoKit produces;
  JCA and the Keystore use DER, so `EcdsaSignature` converts both ways.
- The cipher is `ChaCha20/Poly1305/NoPadding` on Android and
  `ChaCha20-Poly1305` on desktop JVMs; `Aead` tries both, so the protocol tests
  run on the JVM.
- JSON follows Swift's `JSONEncoder` as `RemoteJSON` configures it: standard
  padded base64 for `Data`, ISO-8601 dates without fractional seconds (decoding
  also accepts fractions and offsets), nil optionals omitted, sorted keys.
  Swift's `Int` is 64-bit, so token counts are `Long`.

Tests:

- `:protocol:test` covers the channel (RFC 5869 and RFC 8439 vectors,
  tampering, DER edge cases), pairing links, JSON, an end-to-end client against
  a Kotlin port of the host's handlers, and Swift-generated vectors.
- `:app:testDebugUnitTest` runs Robolectric tests for request selection,
  widget staleness, chart axes, formatting, and every screen.
- `:app:recordRoborazziDebug` writes screenshots of the dashboard (phone and
  tablet, light and dark), pairing, settings, lock screen, and widget to
  `app/build/outputs/roborazzi`.

To try the app in the emulator against a Mac on the same machine: PlanMeter
also listens on `127.0.0.1`, which the emulator reaches as `10.0.2.2`. Replace
`h=…` in the pairing link with `h=10.0.2.2` and paste it into a debug build.
