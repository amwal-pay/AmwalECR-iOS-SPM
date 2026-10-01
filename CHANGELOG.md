# Changelog

All notable changes to `AmwalECR`, the iOS ECR SDK. Semantic versioning, with
the addition described in
[the release policy](https://github.com/amwal-pay/amwal-ecr-flutter/blob/main/doc/release-policy.md): any change to
what an outcome *means* is breaking, however small the diff.

## 0.2.3

Documentation only — no API or wire changes. Tag `v0.2.3` to publish (SwiftPM
resolves from tags).

### Changed

- **README** and **`doc/implementation.md`** now match the current surface:
  Wi‑Fi / USB cable / Web Service; sign-on and close-receipt outcomes; the
  transport support matrix; LAN HMAC vs Web Service body signing; `cancel` and
  `probeReachability` per transport.
- Platform floor remains **iOS 12.0+** (CocoaPods pod targets iOS 17.0+).

## 0.2.2

Sign-on and close-receipt on local links, matching Android `EcrTerminal.signOn`
and `EcrTerminal.closeReceipt`.

### Added

- **`EcrTerminal.signOn`** and **`EcrOpenedSession.signOn`**. Wi‑Fi and a
  caller-supplied USB cable channel send `SIGN_ON`. A Web Service session
  answers `.unavailable` and sends nothing.
- **`EcrSignOn`** (`.available` / `.unavailable` / `.failed`),
  **`EcrTerminalCapabilities`**, **`EcrPermittedTransaction`**, and
  **`EcrTerminalTransport`**.
- **`EcrOpenedSession.supportsSignOn`** — `true` on Wi‑Fi and USB cable
  (`usesLocalTerminal`); the same local gate covers close-receipt (no separate
  flag).
- **`EcrDeclined.capabilities`** when a refusal carries `profileChanged`, so a
  till can update what the terminal permits without signing on again.
- **`EcrTerminal.closeReceipt`** and **`EcrOpenedSession.closeReceipt`**.
  Wi‑Fi and a caller-supplied USB cable channel send `CLOSE_RECEIPT`. A Web
  Service session answers `.refused` and sends nothing.
- **`EcrReceiptClosed`** (`.idle` / `.refused` / `.failed`). An already-idle
  terminal answers `.idle`; a terminal that will not (or cannot) close answers
  `.refused`.
- **`EcrTransactionType.signOn`** (`SIGN_ON`) and
  **`EcrTransactionType.closeReceipt`** (`CLOSE_RECEIPT`) — not in
  `menuOptions`; run via `signOn` / `closeReceipt`, not `run`.

## 0.2.1

Brings the iOS SDK to parity with Android `ecr-sdk` for Web Service ECR, USB
cable link surface, session planning, and secure-hash ownership. No AOA /
External Accessory hardware on iOS — USB cable is the link, channel, and
session-plan surface so a till can supply its own byte transport.

**Breaking:** `merchantReferenceId` is renamed to `merchantReference` throughout
the public API and on the wire (`merchantReference` field). Legacy response
payloads that still carry `merchantReferenceId` or `requestId` in `data` are
accepted when reading.

### Added

- **Web Service ECR** — `EcrWebServiceTerminal` with blocking `sale`, `void`,
  `refund`, `inquire`, and `inquireByReference` over HTTPS JSON (Hub URLs
  resolved internally for SIT/UAT/PROD).
- **`EcrEnvironment`**, **`EcrLink`**, **`EcrSessionPlan`**, and **`EcrSessions`**
  for validated session planning and client construction.
- **`EcrReachability`** and **`EcrTerminal.probeReachability()`**.
- **`EcrReachability.endpoint`** for operator-facing link text on non-IP links.
- **`EcrWireResponse`** with unified envelope parsing and
  `displayMessageFromRaw(_:fallback:)`.
- **`EcrConfig`** fields `merchantId`, `terminalId`, `environment`, and static
  `isValidSecureHashKey(_:)`.
- **`EcrTransactionType.menuOptions`** and **`EcrTransaction`** fields
  `partialApproval` and `authorizedAmount`.
- **`EcrLink.usbCable`** — addressless USB cable link; caller supplies an
  `EcrChannel`.
- **`EcrChannel`**, **`EcrChannelTimeout`**, and **`TcpEcrChannel`** — transport
  abstraction; LAN continues to use TCP framing via `TcpEcrChannel`.
- **`EcrFrames`** — public `wrap` / `bodyLength` / `readBody` matching Android.
- **`EcrSessionPlan.usesUsbCable`**, connection summary `"USB cable"`, and
  **`EcrSessions.usbCableTerminal(…)`**.
- **`EcrTerminal` channel initialiser** — host-based init remains and builds a
  `TcpEcrChannel`.
- **`EcrOpenedSession`** and **`EcrSessions.open`** — one dispatch for LAN /
  USB cable / Web Service so sale, inquiry, and recovery share the same client.
- Unit-test placeholders aligned with `ecr_sdk`: `SECURE_HASH_KEY_ECR_WIFI`,
  `SECURE_HASH_KEY_ECR_WIFI_OTHER`, `SECURE_HASH_KEY_WEBSERVICE` on
  `EcrTestConfigs` (`lan` / `lanOther` / `webService`).

### Changed

- **`EcrSecureHashKeys` removed.** Apps persist secrets and pass one value on
  `EcrConfig.secureHashKey` for the selected terminal mode. Log labels stay on
  `SecureHash.keyLabel` / `WebServiceSecureHash.keyLabel`.
- **`EcrResponseReader`** now parses the unified response envelope
  (`success`, `data`, `errorList`, nested `ecrResponse`), matching Android
  `EcrWireReaders.kt`. Inquiry found/not-found is determined by `data` presence,
  not the outer `success`/`approved` flag.
- **Partial inquiry amounts:** `amount` is the requested amount;
  `authorizedAmount` is the settled (`authorizeAmount`) value.
- **Web Service Hub hosts** are distinct per environment (SIT `:25452`,
  UAT `:15452`, PROD `pos.amwalpg.com`).
- **Diagnostics** never log hex slices of signing secrets — only
  `configured` / `not configured`.
- Settled money-moving amounts still prefer `authorizeAmount` when greater than
  zero.
