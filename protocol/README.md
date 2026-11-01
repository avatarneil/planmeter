# PlanMeter remote protocol, version 1

This document specifies the protocol between a PlanMeter **host** (the Mac app today, `planmeterd`
on Linux later) and its **clients** (the iOS/watchOS app, the web client, and the Android app).
It describes the protocol as implemented in `Sources/PlanMeterRemote` and
`Sources/PlanMeter/Remote/RemoteState.swift`. You should be able to write a compatible client
from this document and the fixtures in [`fixtures/`](#fixtures).

The key words MUST, MUST NOT, SHOULD, and MAY are used as in RFC 2119.

## Contents

1. [Overview](#overview)
2. [Transport](#transport)
3. [Endpoints](#endpoints)
4. [Encodings](#encodings)
5. [Secure channel](#secure-channel)
6. [Pairing](#pairing)
7. [RPC](#rpc)
8. [Errors and status codes](#errors-and-status-codes)
9. [Versioning](#versioning)
10. [Implementation notes](#implementation-notes)
11. [Fixtures](#fixtures)

## Overview

- The host listens for plain HTTP/1.1 on its Tailscale address. Tailscale (WireGuard) provides
  transport encryption between devices. The host refuses peers outside the tailnet.
- Inside that, every request and response body is end-to-end encrypted and authenticated by the
  **secure channel**: per-request ephemeral P-256 ECDH against the host's static key, HKDF-SHA256
  request/response keys, an AEAD (ChaCha20-Poly1305 or AES-256-GCM), and an ECDSA P-256
  signature by the client's device key.
- A client **pairs** once by scanning a QR code (or opening a link) that carries the host's
  address, its static public key, and a single-use token. Pairing registers the client's device
  signing key with the host and returns a `deviceId`.
- After pairing, the client sends **RPCs** (`summary`, `models`, `timeline`, `limits`,
  `accounts`) and decrypts typed JSON replies.

The host has one long-lived P-256 key-agreement key (the **server static key**). Each client
has one long-lived P-256 signing key (the **device key**). Neither private key ever leaves its
device.

## Transport

| Property | Value |
| --- | --- |
| Protocol | HTTP/1.1, one request per connection. Responses carry `Connection: close`. |
| Default port | 7787 (configurable on the host). |
| Addresses | The host's Tailscale IPv4 address, plus `127.0.0.1` for same-machine clients. |
| HTTPS | Optional. When the user enables it, `tailscale serve` exposes `https://<MagicDNS name>/` on port 443 and proxies to `http://127.0.0.1:<port>`. The web client requires it; native clients use plain HTTP. |
| Allowed peers | `100.64.0.0/10`, `fd7a:115c:a1e0::/48`, and loopback. For requests from loopback, the first `X-Forwarded-For` entry (set by Tailscale Serve) is the peer. Anything else gets `403`. |
| Request body | Read by `Content-Length` only. Chunked transfer encoding is not supported. Maximum 1 MiB. |
| Request head | Maximum 16 KiB. |
| Timeout | The host drops a connection that has not delivered a complete request within 20 seconds. |
| Path matching | Exact match on the path; any query string is ignored. |

Clients address the host as `http://<host>:<port>`, where `<host>` comes from the pairing invite.
IPv6 literals MUST be bracketed (`http://[fd7a:115c:a1e0::1]:7787`). Clients SHOULD send
`Content-Type: application/json`, SHOULD NOT send cookies, and SHOULD use a request timeout of
about 20 seconds. The iOS app sends `User-Agent: PlanMeterMobile/1`; the host ignores it.

Every host response carries `Content-Type` (`application/json` for API responses),
`Content-Length`, `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, and
`Connection: close`.

## Endpoints

| Method | Path | Request body | Success response | Authentication |
| --- | --- | --- | --- | --- |
| `GET` | `/v1/info` | none | `200` [`ServerInfo`](#get-v1info) | none |
| `POST` | `/v1/pair` | [`SealedRequest`](#sealedrequest) wrapping a [`PairRequest`](#pairrequest) | `200` [`SealedResponse`](#sealedresponse) wrapping a [`PairResponse`](#pairresponse) | invite token + device signature |
| `POST` | `/v1/rpc` | [`SealedRequest`](#sealedrequest) wrapping a [`RemoteRequest`](#remoterequest) | `200` [`SealedResponse`](#sealedresponse) wrapping a [`RemoteReply`](#remotereply) | paired device signature |
| `POST` | `/v1/web-pairing-invite` | `{"code": "12345678"}` | `200` [`WebPairingOffer`](#web-pairing) | 8-digit code shown on the host |
| `GET` | `/`, `/index.html`, `/app.js`, `/pair-parse.js`, `/jsqr.js`, `/app.css`, `/manifest.webmanifest`, `/icon.svg` | none | the static web client | none |

Any other method on the four API paths returns `405`. Any other path returns `404`.

### `GET /v1/info`

Unauthenticated. Lets a client recognize a PlanMeter host without revealing any usage data.

```json
{"app": "planmeter", "version": "0.3.6", "serverName": "Ada’s MacBook Pro", "protocolVersion": 1}
```

`version` is the host app's marketing version (`"dev"` for unbundled builds). `protocolVersion`
is the secure channel's `v`.

## Encodings

### JSON (`RemoteJSON`)

All bodies are UTF-8 JSON objects.

- **Dates** are ISO-8601 strings in UTC with second precision and a `Z` suffix:
  `"2026-10-19T16:00:00Z"`. Senders truncate fractional seconds. The Swift decoder **rejects**
  fractional seconds and numeric offsets, so a client that ever sends a date MUST use this exact
  form.
- **Binary data** (`Data` fields such as keys, nonces, ciphertext, and signatures) is standard
  base64 (RFC 4648 §4) **with** `=` padding and no line breaks. The Swift decoder rejects
  unpadded, URL-safe, or wrapped base64 in JSON bodies.
- **Optional fields** are omitted when absent; they are never `null`. Receivers MUST treat a
  missing field and `null` alike.
- **Unknown fields** MUST be ignored. New optional fields are added without a version change.
- **Key order**: the Swift encoder sorts keys and does not add whitespace. Receivers MUST NOT
  depend on order or formatting; nothing signs or hashes a JSON body.
- **Escaping**: the Swift encoder escapes `/` as `\/`. Standard JSON parsers handle this.
- **Numbers**: integers are JSON integers (64-bit). `Double` values use the shortest
  round-tripping decimal form and may have no fractional part (`128` for 128.0).

`GET /v1/info`, the web pairing offer, and error bodies are encoded with Swift's default
`JSONEncoder` (unsorted keys); they contain no dates or binary data.

### Base64url

Only two values use base64url (RFC 4648 §5, `-` and `_`, **no** padding): the server public key
in a pairing URL (`k`) and the hash inside the device-id derivation. Decoders SHOULD accept
padded input as well.

### Keys and signatures

| Item | Encoding |
| --- | --- |
| P-256 public key | X9.63 uncompressed point: `0x04 ‖ X ‖ Y`, 65 bytes, coordinates big-endian. Compressed points are not accepted. |
| P-256 private key (fixtures only) | 32-byte big-endian scalar ("raw representation"). |
| ECDH shared secret | The 32-byte big-endian x-coordinate of the shared point (what CryptoKit, WebCrypto `deriveBits(…, 256)`, Java `KeyAgreement("ECDH")`, and RustCrypto `raw_secret_bytes()` return). |
| ECDSA signature | P-256 with SHA-256, encoded as raw `r ‖ s`, 64 bytes (IEEE P1363, the WebCrypto format). **Not** DER. Both `s` and `n − s` verify; clients need not normalize to low S. |

## Secure channel

### Parameters

| Name | Value |
| --- | --- |
| `LABEL` | `planmeter-remote-v1` |
| Protocol version `v` | `1` |
| Curve | NIST P-256 (secp256r1) for ECDH and ECDSA |
| KDF | HKDF-SHA256 (RFC 5869) |
| AEAD | `chacha20poly1305` (RFC 8439, IETF variant) or `aes-256-gcm` |
| Nonce | 12 random bytes, fresh for every request and every response |
| Tag | 16 bytes |
| Clock window | 120 seconds either way |

The cipher is chosen by the client, per request. Native clients SHOULD use `chacha20poly1305`.
Browsers use `aes-256-gcm` because WebCrypto has no ChaCha20-Poly1305. The host answers with
the cipher of the request.

### Sealing a request (client)

Inputs: plaintext `P` (the UTF-8 JSON of a `PairRequest` or `RemoteRequest`), the server static
public key `S` (65 bytes, from the pairing invite), the `deviceId` (from pairing, or the literal
string `pairing` while pairing), the device signing key, the HTTP method `POST`, and the path.

1. Generate an ephemeral P-256 key pair `e`. Let `E` be its 65-byte X9.63 public key.
2. `Z` = ECDH(`e`, `S`): the 32-byte shared x-coordinate.
3. `N` = 12 random bytes.
4. `T` = the current Unix time in whole seconds (floor), as a signed 64-bit integer.
5. Derive two 32-byte keys:
   - `Kreq` = HKDF-SHA256(IKM = `Z`, salt = `N`, info = UTF-8(`LABEL "|" deviceId "|request"`), L = 32)
   - `Kres` = HKDF-SHA256(IKM = `Z`, salt = `N`, info = UTF-8(`LABEL "|" deviceId "|response"`), L = 32)

   For example, info = `planmeter-remote-v1|0nfkgpQ6iVXlNxiZqqW0aF|request`.
6. Build the header `H` (next section).
7. `C` = `N ‖ AEAD-Encrypt(key = Kreq, nonce = N, aad = H, plaintext = P) ‖ tag`. That is, the
   12-byte nonce, then the ciphertext (same length as `P`), then the 16-byte tag.
8. `σ` = ECDSA-P256-SHA256-Sign(device key, `H ‖ SHA-256(C)`), as 64-byte `r ‖ s`. The signed
   message is the header bytes followed by the 32-byte raw SHA-256 digest of `C`; the ECDSA
   algorithm then hashes that message with SHA-256 as usual.
9. Send the [`SealedRequest`](#sealedrequest) JSON and keep `Kres` to open the response.

### Header

`H` is the UTF-8 encoding of eight lines, each terminated by a single line feed (`0x0A`),
including the last. There are no carriage returns.

```
planmeter-remote-v1⏎
<METHOD in upper case>⏎
<path>⏎
<deviceId>⏎
<timestamp T in decimal>⏎
<base64(N), standard with padding>⏎
<base64(E), standard with padding>⏎
<cipher>⏎
```

- `<path>` is exactly the request path, for example `/v1/rpc` or `/v1/pair`, without a query.
- `<timestamp>` is the same integer as the JSON `timestamp` field, in decimal ASCII with no
  leading zeros or sign for positive values.
- `base64(N)` is 16 characters; `base64(E)` is 88 characters ending in one `=`.
- `<cipher>` is the effective cipher name: the `cipher` field, or `chacha20poly1305` when the
  field is absent.

The header from [`fixtures/secure-channel/chacha20poly1305-request.json`](fixtures/secure-channel/chacha20poly1305-request.json):

```
planmeter-remote-v1
POST
/v1/rpc
0nfkgpQ6iVXlNxiZqqW0aF
1792500000
lwbbCwmImiEo5QJj
BD2oj57vM+Sym/zjh5wr9nfCtr0sqne0TV4DclUs92dKyBsy4vmkPCYMMIzCZKDhIPOcstrsqdMSiorwe5250zA=
chacha20poly1305

```

(The final line feed after `chacha20poly1305` is part of the header.)

### `SealedRequest`

```json
{
  "v": 1,
  "deviceId": "0nfkgpQ6iVXlNxiZqqW0aF",
  "ephemeralPublicKey": "<base64 of E, 65 bytes>",
  "nonce": "<base64 of N, 12 bytes>",
  "timestamp": 1792500000,
  "ciphertext": "<base64 of C = N ‖ ciphertext ‖ tag>",
  "signature": "<base64 of σ, 64 bytes>",
  "cipher": "chacha20poly1305"
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `v` | integer | MUST be `1`. Not covered by the header or signature. |
| `deviceId` | string | The paired device id, or `pairing` for `POST /v1/pair`. |
| `ephemeralPublicKey` | base64 | Exactly 65 bytes. |
| `nonce` | base64 | Exactly 12 bytes. Also the HKDF salt and the first 12 bytes of `ciphertext`; the two copies MUST be equal. |
| `timestamp` | integer | Unix seconds. |
| `ciphertext` | base64 | `N ‖ ciphertext ‖ tag`, at least 28 bytes. |
| `signature` | base64 | 64 bytes, `r ‖ s`. |
| `cipher` | string, optional | `chacha20poly1305` or `aes-256-gcm`. Absent means `chacha20poly1305`; clients SHOULD always send it. |

### Opening a request (host)

The host processes a `SealedRequest` in this order. The [status codes](#errors-and-status-codes)
for each failure differ per endpoint.

1. **Decode** the JSON. Failure is a bad request.
2. **checkTimestamp**: `v` MUST be 1 (else `unsupportedVersion`); `nonce` MUST be 12 bytes and
   `ephemeralPublicKey` 65 bytes (else `malformed`); `|timestamp − now| ≤ 120` seconds (else
   `timeWindow`). A skew of exactly 120 seconds is accepted.
3. **Verify the signature** over `H ‖ SHA-256(ciphertext)`, where `H` is rebuilt from the
   received fields and the method and path the host actually received. For RPC the key is the
   paired device's stored key; for pairing it is the `devicePublicKey` inside the decrypted
   `PairRequest`, so pairing verifies after step 5.
4. **Replay check**: reject a `(deviceId, nonce)` pair seen in the last 245 seconds
   (2 × 120 + 5). The cache is in memory; the clock window bounds what a restart forgets.
5. **Open**: `Z` = ECDH(server static key, `E`); derive `Kreq` and `Kres` as above; decrypt
   `ciphertext` with `Kreq`, the nonce embedded in its first 12 bytes, and `aad = H`.
6. **Decode** the plaintext as a `PairRequest` or `RemoteRequest`.

### Sealing a response (host)

1. `N2` = 12 fresh random bytes.
2. `C2` = `N2 ‖ AEAD-Encrypt(key = Kres, nonce = N2, aad = N2, plaintext = P2) ‖ tag`, using the
   request's cipher. The additional data is the 12 nonce bytes themselves.
3. Respond `200` with a `SealedResponse`.

### `SealedResponse`

```json
{"nonce": "<base64 of N2>", "ciphertext": "<base64 of N2 ‖ ciphertext ‖ tag>", "cipher": "chacha20poly1305"}
```

| Field | Type | Notes |
| --- | --- | --- |
| `nonce` | base64 | Exactly 12 bytes (else the client fails with `malformed`). Used as the additional data. |
| `ciphertext` | base64 | `N2 ‖ ciphertext ‖ tag`. |
| `cipher` | string, optional | Absent means `chacha20poly1305`. Current hosts always send it. |

### Opening a response (client)

Check that `nonce` is 12 bytes, then decrypt `ciphertext` with `Kres`, nonce = its first 12
bytes, and `aad` = the bytes of the `nonce` field. The two nonce copies MUST be equal (a
mismatch fails authentication). The plaintext is the UTF-8 JSON of a `PairResponse` or
`RemoteReply`. Each `Kres` opens exactly one response.

Error responses (any status other than `200`) are **not** encrypted; see
[Errors](#errors-and-status-codes).

### Security properties (informative)

- Device keys only sign, so a leaked device key exposes no recorded traffic; it lets the holder
  send requests as that device until it is removed.
- v1 has **no forward secrecy against the server's static key**. Every request and response key
  comes from ECDH between the request's ephemeral key, which travels in the clear, and the
  server's static key. Anyone who records traffic and later obtains the server's private key can
  decrypt it. The fresh ephemeral key per request only keeps requests' keys independent of each
  other. Closing this would need a server ephemeral key, which is a protocol change.
- The header binds the method, path, device id, timestamp, nonce, ephemeral key, and cipher into
  both the AEAD and the signature. Changing any of them, or relabelling the cipher, fails both.
- The signature proves possession of the paired device key; the AEAD alone does not, because
  anyone with the server's public key can produce a decryptable request.
- `v` is not authenticated. It exists so a future version can be rejected early.

## Pairing

### Invite URL

The host shows a QR code containing:

```
planmeter://pair?h=<host>&p=<port>&n=<server name>&k=<server public key>&t=<token>&e=<expiry>
```

| Parameter | Required | Meaning |
| --- | --- | --- |
| `h` | yes, non-empty | Host to connect to: the MagicDNS name if available, else the Tailscale IPv4 address. |
| `p` | yes | Decimal port, 1–65535. |
| `n` | no | Display name of the host. Defaults to `h`. |
| `k` | yes | Server static public key, base64url without padding; MUST decode to 65 bytes. |
| `t` | yes, non-empty | Pairing token: opaque ASCII, currently 43 characters (32 random bytes in base64url). Pass it through unchanged. |
| `e` | yes | Expiry as decimal Unix seconds (64-bit integer). |

- The scheme MUST be `planmeter` and the host component MUST be `pair`.
- Parameters may appear in any order; unknown parameters MUST be ignored.
- Values are percent-decoded as in RFC 3986. The host percent-encodes non-ASCII and spaces
  (`n=Ada%E2%80%99s%20MacBook%20Pro`). It does not encode `+`, so `+` MUST be read as a literal
  plus sign, not a space.
- An expired invite still parses. Before pairing, clients MUST check `e` against the clock and
  show an error instead of sending a request that will fail.
- Invites last 5 minutes. A host has at most one active invite; making a new one replaces it.
  After 5 failed pairing attempts the host cancels the invite.

See [`fixtures/pairing/invites.json`](fixtures/pairing/invites.json) for valid URLs with parsed
fields and invalid URLs that MUST be rejected.

### `POST /v1/pair`

1. Create (or load) the device signing key.
2. Build a `PairRequest` and seal it with `deviceId = "pairing"`, path `/v1/pair`, the invite's
   server key `k`, and the device key as signer.
3. `POST` it to `http://<h>:<p>/v1/pair`.
4. Open the `SealedResponse` to get a `PairResponse`.
5. Store the paired-server record: `h`, `p`, the server name from the response, the server key
   from the invite (pinned for all later requests), the `deviceId` from the response, and the
   pairing time.

#### `PairRequest`

```json
{"token": "AyxTHyFcn7YlJYEZFStySZHSCbH_uvyNAlpfKrmzPno", "deviceName": "Ada’s Pixel 9",
 "devicePublicKey": "<base64 of the 65-byte X9.63 device public key>", "platform": "android"}
```

| Field | Type | Notes |
| --- | --- | --- |
| `token` | string | `t` from the invite. Compared in constant time. |
| `deviceName` | string | Shown on the host. The host keeps the first 64 characters, trims whitespace, and uses `Device` if empty. |
| `devicePublicKey` | base64 | 65 bytes. The host verifies the request's signature with this key. |
| `platform` | string | Free text, first 32 characters kept. The web client sends `web`; the iOS app sends a description such as `iPhone · iOS 26.0`. Android SHOULD send `android`. |

#### `PairResponse`

```json
{"deviceId": "0nfkgpQ6iVXlNxiZqqW0aF", "serverName": "Ada’s MacBook Pro", "serverVersion": "0.3.6"}
```

#### Device id

`deviceId` = the first 22 characters of base64url-without-padding(SHA-256(device public key)),
where the public key is the 65-byte X9.63 encoding. A client can compute its own id; the host's
response is authoritative. Pairing again with the same key replaces the earlier entry (same id).
See [`fixtures/pairing/device-ids.json`](fixtures/pairing/device-ids.json).

#### Host checks, in order

1. Decode and checkTimestamp, and require `deviceId == "pairing"`. Else `400 bad pairing request`.
2. An unexpired invite must exist. Else `403 no active pairing code`.
3. Replay check on `("pairing", nonce)`. Else `409 replay`.
4. Open and decode the `PairRequest`. Else `403 pairing rejected`.
5. `devicePublicKey` must be 65 bytes and verify the signature. Else `403 pairing rejected`.
6. `token` must equal the invite token. Else `403 pairing rejected`.
7. Register the device, consume the invite, and reply with the sealed `PairResponse`.

Each `403 pairing rejected` counts toward the invite's failure budget of 5.

### Web pairing

Browsers that are already open cannot receive the `planmeter://` URL, so the host offers two
extra paths to the same invite.

**Link.** A QR code or link to the web client with the invite in the URL fragment, which never
reaches server logs:

```
https://<MagicDNS name>/#k=<base64url server key>&t=<token>&e=<expiry>&n=<server name>
```

(`http://127.0.0.1:<port>/#…` when Tailscale Serve is off, for clients on the host itself.) The
web client parses the fragment like the invite URL's query.

**Code.** The host also shows an 8-digit code. The browser exchanges it for the invite:

```
POST /v1/web-pairing-invite
{"code": "12345678"}
```

The host strips non-digits and requires exactly 8. On success:

```json
{"serverName": "Ada’s MacBook Pro", "serverPublicKey": "<standard base64, 65 bytes>",
 "token": "<the invite token>", "expiresAt": 1792500300}
```

Note that `serverPublicKey` here is **standard** base64 and `expiresAt` is integer Unix seconds.
Failures: `403 no active pairing code`, or `403 pairing rejected` for invalid JSON or a wrong
code (counted toward the failure budget). Claiming the code does not consume the invite; the
browser then pairs with `POST /v1/pair` as usual, using `cipher = aes-256-gcm`.

## RPC

`POST /v1/rpc` carries a sealed `RemoteRequest` signed by a paired device (`deviceId` from
pairing) and returns a sealed `RemoteReply`.

Host checks, in order:

1. Decode and checkTimestamp. Else `400 bad request`.
2. `deviceId` must be paired. Else `401 unknown device`.
3. Verify the signature with the stored device key. Else `401 signature failed`.
4. Replay check on `(deviceId, nonce)`. Else `409 replay`.
5. Open and decode the `RemoteRequest`. Else `400 undecryptable request`. An unknown `method`
   value fails here, so check the host version before using a new method.
6. Reply with the sealed `RemoteReply`.

A client that gets `401 unknown device` has been unpaired (revoked on the host) and SHOULD
offer to pair again.

### `RemoteRequest`

```json
{"method": "timeline", "days": 1, "resolution": "hour"}
```

| Field | Type | Applies to | Meaning |
| --- | --- | --- | --- |
| `method` | string | all | `summary`, `models`, `timeline`, `limits`, or `accounts`. |
| `days` | integer, optional | summary, models, timeline | Window length. Default 30, clamped to 1–365. `1` is a rolling 24 hours: the host's current clock hour and the 23 before it. Larger values are whole local calendar days in the host's time zone, ending at the end of today. |
| `minutes` | integer, optional | summary, models, timeline | A window shorter than a day, clamped to 5–1440, ending at the next five-minute boundary. Overrides `days`. Send `days` too: hosts older than this field ignore it. |
| `resolution` | string, optional | timeline | `minute`, `5m`, `15m`, `hour`, or `day`. Default and unknown values mean `day`. The host may coarsen it (see below). |
| `account` | string, optional | models | Filter: case-insensitive substring of the account id or name, or an exact provider (`codex`, `claude`, `grok`, `opencode`). |

The host never uses buckets coarser than `hour` for `minutes` windows or `days = 1`, never
coarser than `day` otherwise, and coarsens until the window has at most about 1,500 buckets. The
reply's `resolution` is the one used. Hosts older than fine buckets only answer `hour` and
`day`; clients detect them when a `minutes` request comes back without `summary.minutes`, or a
fine resolution comes back as `day`.

### `RemoteReply`

A union: exactly one of `summary`, `models`, `timeline`, `limits`, or `accounts` is present on
success, matching the method. On an application-level failure the HTTP status is still `200`
and the reply has only `error`, for example `{"error": "server not ready"}`. Clients MUST check
`error` first.

Examples of every reply are in [`fixtures/replies/`](fixtures/replies/). Field reference:

**`RemoteAccount`**: `id` (string, stable), `name`, `provider` (`codex`, `claude`, `grok`,
`opencode`), `providerName`, `group` (`personal`, `work`, or `other`), and optional `email`,
`plan`, `accentColorHex` (`#RRGGBB`).

**`RemoteTotals`**: `costUsd` (number), `tokens` (input + output), `inputTokens` (including
cached), `cachedInputTokens`, `outputTokens`, `sessions`, `cacheSavingsUsd`.

**`summary`** (`RemoteSummary`): `days`, `from`, `to` (window, dates), `groups` (array of
`{group, totals, accounts: [{account, totals}]}` in the order personal, work, other; `other` is
omitted when empty; accounts sorted by cost, then tokens, descending), `total`, `todayCostUsd`,
`generatedAt` (time of the host's last scan), `serverName`, `pricingSource`, and optional
`usesProviderDates` (boolean) and `minutes` (set for sub-day windows).

**`models`** (array of `RemoteModelRow`): `accountId`, `accountName`, `group`, `provider`,
`model`, `totals`, `priced` (false when no price is known for the model, in which case its cost
is 0). Sorted by cost, then tokens, descending.

**`timeline`** (`RemoteTimeline`): `days`, `resolution` (effective), `periods` (every bucket
start in the window, ascending; buckets with no points are zero), `points` (sparse:
`{period, accountId, costUsd, tokens, baselineCostUsd?}`, sorted by period then account id),
`accounts` (the accounts that appear in `points`), and optional `minutes`. `baselineCostUsd`,
when present, is the part of `costUsd` that comes from workspace credits without timing, spread
evenly over the hours the provider reported; charts can draw it as a lighter baseline. `period`
is a bucket start; fixed-size buckets are `minute` (60 s), `5m`, `15m`, `hour`; `day` buckets
are local calendar days.

**`limits`** (`RemoteLimits`): `accounts` (one entry per Codex account: `{account, windows,
note?, asOf?}`, where each window is `{label, usedPercent, windowMinutes, resetsAt}`) and a
`note` for display.

**`accounts`** (`RemoteAccounts`): `accounts`, `sources` (`{provider, path, status}` with status
`ok`, `missing`, `partial`, or `failed`), and optional `scannedAt`.

## Errors and status codes

Every non-`200` response has a plaintext JSON body `{"error": "<message>"}`. The message is for
logs and display; clients branch on the status code, plus the message where noted.

| Status | `error` | When |
| --- | --- | --- |
| 400 | `bad request` | Malformed HTTP head; or on `/v1/rpc`, a `SealedRequest` that does not decode or fails checkTimestamp. |
| 400 | `truncated body` | The connection closed before `Content-Length` bytes arrived. |
| 400 | `bad pairing request` | `/v1/pair`: undecodable, failed checkTimestamp, or `deviceId` is not `pairing`. |
| 400 | `undecryptable request` | `/v1/rpc`: AEAD failure or the plaintext is not a valid `RemoteRequest`. |
| 401 | `unknown device` | `/v1/rpc`: `deviceId` is not paired (revoked or never paired). |
| 401 | `signature failed` | `/v1/rpc`: the signature does not verify. |
| 403 | `tailnet peers only` | The peer is not on the tailnet or loopback. |
| 403 | `no active pairing code` | `/v1/pair` or `/v1/web-pairing-invite` with no unexpired invite. |
| 403 | `pairing rejected` | `/v1/pair`: undecryptable, bad key or signature, or wrong token. `/v1/web-pairing-invite`: bad JSON or wrong code. |
| 404 | `not found` | Unknown path. (`web client not bundled` for a static file missing from the build.) |
| 405 | `method not allowed` | Wrong method on an API path. |
| 409 | `replay` | The `(deviceId, nonce)` pair was already used within 245 seconds. |
| 413 | `body too large` | `Content-Length` over 1 MiB. |
| 431 | `headers too large` | Request head over 16 KiB. |
| 500 | `could not seal response` | Internal failure while encrypting the reply. |
| 503 | `server stopping` | The listener is shutting down. |

Timeouts and dropped connections have no body. Clients SHOULD treat `timeWindow`-style
failures (`400 bad request` right after a successful pairing) as a hint to check the device
clock.

## Versioning

- This is version 1: `v = 1`, the label `planmeter-remote-v1`, and the `/v1/` path prefix.
- Compatible changes add optional JSON fields, new `RemoteRequest` parameters that older hosts
  ignore, or new endpoints. They do not change `v`.
- A breaking change bumps `v`, the label, and the path prefix together.
- New `RemoteMethod` values are not understood by older hosts (`400 undecryptable request`).
  Use `GET /v1/info` (`version`) to decide whether a host supports a method.

## Implementation notes

### Kotlin / Android

- **Keys**: generate the device key in the Android Keystore (`KeyProperties.KEY_ALGORITHM_EC`,
  `secp256r1`, purpose `SIGN`, digest `SHA256`; StrongBox when available). Ephemeral keys are
  ordinary in-memory `KeyPairGenerator("EC")` keys.
- **X9.63**: Java encodes EC public keys as X.509 SubjectPublicKeyInfo. Build the 65-byte form
  from `ECPublicKey.w` (`0x04`, then `affineX` and `affineY` each as 32-byte big-endian, left
  padded). To import the server key, build an `ECPublicKeySpec` from the two coordinates.
- **ECDH**: `KeyAgreement.getInstance("ECDH")` returns the 32-byte x-coordinate.
- **HKDF**: not in the JDK; implement RFC 5869 with `Mac.getInstance("HmacSHA256")`. With
  L = 32 it is `PRK = HMAC-SHA256(key = N, message = Z)` and
  `OKM = HMAC-SHA256(key = PRK, message = info ‖ 0x01)`.
- **AEAD**: `Cipher.getInstance("ChaCha20/Poly1305/NoPadding")` (Android API 28+; the desktop
  JDK calls it `ChaCha20-Poly1305`) with `IvParameterSpec(N)`, or
  `Cipher.getInstance("AES/GCM/NoPadding")` with `GCMParameterSpec(128, N)`. Call `updateAAD(H)` before
  `doFinal`. Both return `ciphertext ‖ tag`; prepend `N` yourself, and strip it before opening a
  response.
- **ECDSA**: `Signature.getInstance("SHA256withECDSA")` produces DER. Convert to raw `r ‖ s` (strip the DER
  integer headers, left-pad each to 32 bytes). Feed the signer the message `H ‖ SHA-256(C)`, not
  a pre-hashed digest.

### Rust

`p256` (`ecdh::diffie_hellman(...).raw_secret_bytes()`, `ecdsa::Signature::to_bytes()` for
`r ‖ s`, `EncodedPoint::from_bytes` / `to_encoded_point(false)` for X9.63), `hkdf` with
`sha2::Sha256`, `chacha20poly1305`, and `aes-gcm` (`Aes256Gcm`, whose output is
`ciphertext ‖ tag`).

### WebCrypto

See `Sources/PlanMeter/Web/app.js`: `ECDH` `deriveBits(…, 256)`, an `HKDF` `deriveKey` to
`AES-GCM` 256, `encrypt` with `additionalData`, and `ECDSA` `{hash: "SHA-256"}`, whose
signatures are already raw `r ‖ s`. `exportKey("raw")` yields the 65-byte X9.63 point.

## Fixtures

Generated by the Swift implementation in
`Tests/PlanMeterRemoteTests/ProtocolFixtureTests.swift`. Swift tests fail if the committed files
differ semantically from what the code produces, on macOS and Linux. To change them on purpose,
run on a Mac and review the diff:

```
PLANMETER_REGENERATE_FIXTURES=1 swift test --filter ProtocolFixtureTests
```

All key material is fixed (private scalars are SHA-256 of fixed labels) and the timestamp is
`1792500000` (2026-10-20T12:40:00Z), so every value is reproducible except ECDSA signatures,
which are randomized. A vector's signature is a known-good one to **verify**; implementations
cannot reproduce it. Hex values are lower case. File names are stable.

| File | Contents |
| --- | --- |
| `secure-channel/chacha20poly1305-request.json` | RPC request (`timeline`, `days` 1, `hour`) sealed with ChaCha20-Poly1305. |
| `secure-channel/chacha20poly1305-response.json` | The host's reply to it (an `accounts` reply). |
| `secure-channel/aes-256-gcm-request.json` | RPC request (`summary`, `days` 7) sealed with AES-256-GCM. |
| `secure-channel/aes-256-gcm-response.json` | The reply to it (a `limits` reply). |
| `secure-channel/chacha20poly1305-pair-request.json` | `POST /v1/pair` from a native client (`deviceId` = `pairing`). |
| `secure-channel/chacha20poly1305-pair-response.json` | The sealed `PairResponse`. |
| `secure-channel/aes-256-gcm-pair-request.json` | `POST /v1/pair` from the web client. |
| `secure-channel/aes-256-gcm-pair-response.json` | The sealed `PairResponse`. |
| `secure-channel/negative.json` | Altered requests and responses with the expected result of each check. |
| `pairing/invites.json` | Valid invite URLs with parsed fields; invalid URLs with reasons. |
| `pairing/pair-request.json` | A `PairRequest` (the plaintext of `chacha20poly1305-pair-request.json`). |
| `pairing/pair-response.json` | A `PairResponse`. |
| `pairing/device-ids.json` | Device-id derivations. |
| `replies/summary.json`, `models.json`, `timeline.json`, `limits.json`, `accounts.json` | A `RemoteReply` for each method. `timeline.json` is a 60-minute window in `5m` buckets with `minutes` and `baselineCostUsd`. |
| `replies/error.json` | An error reply. |
| `web-pairing/link.json` | The browser pairing link for an invite, on the HTTPS and loopback origins. |
| `web-pairing/exchange.json` | `POST /v1/web-pairing-invite` cases in order: offers for differently formatted codes, each failure, the fifth failure cancelling the invite, and expiry. |
| `http/status-codes.json` | The response for each row of [Errors and status codes](#errors-and-status-codes), in order against one host. Sealed bodies are described rather than embedded. |
| `http/framing.json` | Request parsing and limits (query strings, `Content-Length`, 16 KiB head, 1 MiB body, truncation) and exact response heads. |
| `control/*.json` | The local control API between `planmeterd` and desktop UIs; see [docs/cross-platform.md](../docs/cross-platform.md#local-control-api-planmeterd--desktop-ui). |

`web-pairing/`, `http/`, and `control/` describe host behaviour and are generated by
`Tests/PlanMeterHostTests` (`RemoteFixtureTests`, `ControlFixtureTests`) from the shared
`PlanMeterHost` code, with the same inputs and the same `PLANMETER_REGENERATE_FIXTURES` switch
(`swift test --filter PlanMeterHostTests`).

### Request vectors (`*-request.json`)

| Field | Meaning |
| --- | --- |
| `serverStaticPrivateKeyHex`, `serverStaticPublicKeyHex` | Host key: 32-byte scalar and 65-byte X9.63 point. |
| `ephemeralPrivateKeyHex`, `ephemeralPublicKeyHex` | The request's ephemeral key (`e`, `E`). |
| `deviceSigningPrivateKeyHex`, `deviceSigningPublicKeyHex` | The device key. |
| `deviceId` | Header and HKDF device id (derived, or `pairing`). |
| `cipher`, `method`, `path`, `timestamp` | As sent. |
| `requestNonceHex` | `N`. |
| `sharedSecretHex` | `Z`. |
| `requestKeyInfo`, `responseKeyInfo` | HKDF info strings. |
| `requestKeyHex`, `responseKeyHex` | `Kreq`, `Kres`. |
| `header`, `headerBase64` | `H` as text (with `\n`) and as base64 of its exact bytes. |
| `plaintext` | `P`, the exact UTF-8 bytes that were encrypted. |
| `ciphertextHex` | `C` = `N ‖ ciphertext ‖ tag`. |
| `ciphertextSha256Hex` | SHA-256(`C`). |
| `signingInputHex` | `H ‖ SHA-256(C)`, the message passed to ECDSA. |
| `signatureHex` | A valid `σ` (verify-only). |
| `sealedRequest` | The complete HTTP body, as a JSON object. |

A conforming client implementation SHOULD reproduce every value except `signatureHex` from the
private keys, nonce, timestamp, and plaintext, verify `signatureHex` against
`deviceSigningPublicKeyHex`, and produce a byte-identical `sealedRequest` apart from
`signature`. A host implementation SHOULD open `sealedRequest` with the server private key and
recover `plaintext`.

### Response vectors (`*-response.json`)

The same key material as the matching request vector (named in `requestVector`), plus
`responseNonceHex` (`N2`), `aadHex` (equal to `N2`), `plaintext` (`P2`), `ciphertextHex`
(`C2` = `N2 ‖ ciphertext ‖ tag`), and `sealedResponse` (the HTTP body). Responses are fully
deterministic given `N2`.

### `negative.json`

`vectors` is an array. Request vectors (`"kind": "request"`) give a `sealedRequest` body, the
`method`, `path`, and `devicePublicKeyHex` to check against, a clock value `now`, and `expect`:

- `checkTimestamp`: `ok`, `unsupportedVersion`, `malformed`, or `timeWindow`.
- `verifySignature`: `true` or `false`.
- `open` (decrypt with `serverStaticPrivateKeyHex`): `ok` (with `plaintext`), `decryptFailed`,
  or `error` (the ephemeral key is not a valid point).

Each check is listed independently, even where a host would stop at an earlier one. Response
vectors (`"kind": "response"`) give a `sealedResponse` and `responseKeyHex`, and
`expect.openResponse`: `ok` (with `plaintext`), `decryptFailed`, or `malformed`.

The vectors cover: an unchanged baseline, a missing `cipher` field (accepted as
`chacha20poly1305`), tampered ciphertext and tag, wrong path and method, a signature by another
key, the `(r, n − s)` signature form, a relabelled cipher, the clock-window edge and both
directions of skew, `v = 2`, a short nonce, a truncated ephemeral key, and for responses a
tampered ciphertext, a mismatched `nonce` field, the wrong key, and a short nonce.

### `pairing/invites.json`

`valid`: `{url, description, expected: {serverHost, port, serverName, serverPublicKeyHex,
token, expiresAt}}`. `invalid`: `{url, reason}`; a parser MUST reject each one.

### `pairing/device-ids.json`

`vectors`: `{label, publicKeyHex, sha256Hex, sha256Base64Url, deviceId}`.
