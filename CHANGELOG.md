# Changelog

All notable changes to `AmwalECR`, the iOS ECR SDK. Semantic versioning, with
the addition described in
[the release policy](https://github.com/amwal-pay/amwal-ecr-flutter/blob/main/doc/release-policy.md): any change to
what an outcome *means* is breaking, however small the diff.

## 0.2.0

Brings the iOS SDK level with `com.amwal-pay:ecr-sdk` 1.0.4. Everything below
already existed on Android; this is the iOS half of the same three features, and
the wire format is now identical on both platforms.

**Breaking, and unavoidably so:** the protocol renamed the field that names a
transaction, so `requestId` is `merchantReferenceId` throughout — on the wire, on
`EcrApproved`, `EcrDeclined`, `EcrInquiry` and `EcrReceipt`. A 0.1.0 till talking
to a current terminal does not simply lose a field; it fails to be understood.
Upgrade both sides together.

### Added

- **A reference the till chooses.** Every operation takes `merchantReferenceId` —
  an order number, a basket id, whatever already names the sale in the caller's
  own system. Left out, the SDK generates one, as before. Either way it comes
  back on the outcome, and it is the only identifier the till holds *before* the
  terminal answers.
- **`inquireByReference(_:)`.** Asks what became of a transaction by the
  reference it was sent with, rather than by a receipt number that arrives *in*
  the answer — which is exactly what goes missing when an answer goes missing.
- **Auto-inquire on a lost answer.** A money-moving request whose answer never
  arrived is followed by one inquiry, on a fresh connection, and what it found is
  attached to the result as `recovered`. `settled` says whether it resolved the
  outcome. Turn it off with `EcrConfig.autoInquireOnFailure` if the till runs its
  own reconciliation. Nothing is ever *re-sent*: an inquiry reads and nothing
  more.
- **Message authentication.** Set `EcrConfig.secureHashKey` and every request is
  signed (HMAC-SHA256 over the sorted scalar fields, with a per-message nonce)
  and every answer is checked, both for its signature and for echoing this
  request's nonce. Built on CommonCrypto, so the iOS 12 floor is unchanged and
  the SDK still has no dependencies. Required in practice — a terminal refuses
  what it cannot verify.
- **`EcrFailure.unauthenticated`**, for an answer that cannot be shown to have
  come from the terminal. Like a timeout it leaves the outcome **unknown**; it is
  never a decline, and must never be retried.
- **`EcrFailure.outcomeUnknown`**, so the one distinction that matters after a
  failure — was anything actually sent — is a property rather than a case
  analysis at each call site.
- **`EcrNextStep`**, carried on a decline and on every failure. The terminal
  states what the till should do instead of leaving it to be inferred from a
  response code.

### Changed

- `sale`, `void`, `refund` and `run` now `throw`, for arguments that cannot be
  used — a reference the wire format cannot carry, a secret that is not hex.
  Nothing is sent in that case. Everything that happens on the wire is still an
  `EcrResult`, never an exception.
- `EcrConfig` gained `secureHashKey`, `autoInquireOnFailure`, `signsMessages` and
  `secureHashKeyError`. A struct stays assignable after construction, so the key
  is checked at the last point before it is used rather than in the initialiser;
  a bad one throws `EcrInvalidArgument` and nothing is sent unsigned.
- An inquiry with no status now reports `Approved`/`Declined` from the lookup
  rather than an empty string, matching the Kotlin SDK.

## 0.1.0

First release.

### Added

- **Five operations** on `EcrTerminal`: `isReachable`, `sale`,
  `void`, `refund`, `inquire` and `receipt`, matching the Kotlin SDK method for
  method.
- **Typed outcomes.** `EcrResult` (`approved` / `declined` / `failed`),
  `EcrInquiry` and `EcrReceipt`, each with their own branches, so an inquiry
  that failed cannot be mistaken for a sale that was refused.
- **Four failures** — `unreachable`, `timeout`, `malformed`, `connectionLost` —
  the same four the Kotlin SDK reports, so the two hosts cannot describe the
  same network event differently. Only `unreachable` leaves the outcome known.
- **Exact amounts.** `Decimal` throughout, converted to the wire's minor units
  once, half-up, matching the Kotlin SDK to the last minor unit.
- **Cancellation.** `cancel()` shuts the socket down, so a blocked read returns
  at once rather than holding a till for the full response timeout. The terminal
  is not told and does not stop: the outcome is unknown.
- **No retries anywhere.** Not on connect, not on read, not on any failure.
- **Distribution** as both a Swift package and a CocoaPods pod, from the same
  sources. Foundation and BSD sockets only — no third-party dependency.

### Compatibility

| | |
|---|---|
| iOS | 12.0+ |
| macOS | 12.0+ (so the suite runs without a simulator) |
| Swift | 5.5+ |
| ECR protocol | version `1` |
| Kotlin SDK it mirrors | `com.amwal-pay:ecr-sdk:1.0.3` |
