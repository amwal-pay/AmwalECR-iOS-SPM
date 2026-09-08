# Changelog

All notable changes to `AmwalECR`, the iOS ECR SDK. Semantic versioning, with
the addition described in
[the release policy](https://github.com/amwal-pay/amwal-ecr-flutter/blob/main/doc/release-policy.md): any change to
what an outcome *means* is breaking, however small the diff.

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
