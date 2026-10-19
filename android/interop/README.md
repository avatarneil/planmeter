# Protocol interop with Swift

The Kotlin protocol module (`android/protocol`) is a third, independent
implementation of PlanMeter's remote protocol. Two checks tie it to the Swift
implementation in `Sources/PlanMeterRemote`. Both use the small harness in
`swift/`, which depends on this checkout's `PlanMeterRemote` by path.

## Vectors (run in CI)

`protocol/src/test/resources/interop/swift-vectors.json` is written by the
harness and read by `SwiftVectorsTest`:

- Swift-sealed requests (ChaCha20-Poly1305 and AES-256-GCM, RPC and pairing)
  that Kotlin must open and verify, the response key CryptoKit derived (Kotlin
  must derive the same bytes), and Swift-sealed responses Kotlin must open.
- 64 CryptoKit ECDSA signatures that Kotlin must verify.
- Pairing links with Swift's verdict from `PairingInvite(url:)`, which Kotlin's
  parser must match field for field.
- A `RemoteJSON`-encoded reply for every RPC method, plus an error reply.

Regenerate after a protocol change (macOS, Swift 6):

```sh
swift build --package-path android/interop/swift --scratch-path /tmp/planmeter-interop-build
/tmp/planmeter-interop-build/debug/planmeter-interop vectors \
  android/protocol/src/test/resources/interop/swift-vectors.json
```

Keys in the file are throwaway test keys.

## Live host (manual)

```sh
android/interop/live-test.sh
```

Starts the harness as a host that handles `/v1/info`, `/v1/pair`, and
`/v1/rpc` with the same checks and `SecureChannel` calls as the Mac's
`RemoteState`, then runs `LiveSwiftServerTest` in Docker: the Kotlin client
pairs, calls every method, sends 200 more signed requests and 20 AES-GCM
requests, and checks that the used invite is refused. The host prints a
summary such as:

```
[interop] paired Kotlin JVM (JVM 21.0.12.1) as HsNEJOb1qkjQRK3yKDaRL7
[interop] -> 403 no active pairing code
[interop] summary: cipher-aes-256-gcm=20 cipher-chacha20poly1305=206 http-403=1 paired=1 rpc-accounts=1 rpc-limits=21 rpc-models=1 rpc-summary=201 rpc-timeline=1
```

The shared golden fixtures in `protocol/fixtures` (repository root) will be read
by `GoldenFixturesTest` once they land on this branch.
