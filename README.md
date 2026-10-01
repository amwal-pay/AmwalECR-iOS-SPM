# Amwal ECR SDK for iOS

Drive an Amwal POS terminal from your own iOS application over Wi‑Fi, a USB
cable, or Web Service (Hub HTTPS).

Your application asks for a payment; the terminal reads the card, talks to the
payment backend, and answers. **No card data passes through your application** —
you receive a masked PAN at most, so integrating does not pull your app into PCI
scope the way handling card numbers would.

```swift
import AmwalECR

var config = EcrConfig()
config.secureHashKey = settings.secureHashKey(for: .wifi)   // app-owned secret

let plan = EcrSessions.plan(
    link: .lan(host: "192.168.1.50", port: 9100),
    config: config
)
guard plan.isReady else {
    screen.show(plan.issues.joined(separator: "\n"))
    return
}

let session = EcrSessions.open(terminalSerial: "P2M12345678", plan: plan)

switch try session.signOn() {
case let .available(_, capabilities, _):
    screen.showTerminal(capabilities.terminalName)
case let .unavailable(_, reason, _, _):
    screen.show(reason); return
case let .failed(_, failure):
    screen.show(failure.message); return
}

switch try session.sale(amount: Decimal(string: "1.234")!) {
case let .approved(sale):
    receipt.print(rrn: sale.rrn, auth: sale.authCode)
    _ = try? session.closeReceipt()          // dismiss the terminal receipt
case let .declined(refusal):
    screen.show(refusal.reason)
    if let capabilities = refusal.capabilities {
        screen.refreshPermitted(capabilities) // profileChanged without re-signing on
    }
case let .failed(_, failure, _):
    screen.show(failure.message)             // outcome may be unknown
}
```

This is the iOS counterpart of the [Kotlin SDK](https://github.com/amwal-pay/ECR-simulator/blob/main/ecr-sdk), method for
method and outcome for outcome. Both are used, unchanged, by the Flutter plugin
[`amwal_ecr`](https://github.com/amwal-pay/amwal-ecr-flutter).

---

## Installing

### Swift Package Manager

In Xcode: **File ▸ Add Package Dependencies…**, then
`https://github.com/amwal-pay/AmwalECR-iOS-SPM.git`, *Up to Next Minor
Version* from `0.2.3`.

Or in a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/amwal-pay/AmwalECR-iOS-SPM.git", .upToNextMinor(from: "0.2.3")),
],
targets: [
    .target(name: "Till", dependencies: [.product(name: "AmwalECR", package: "AmwalECR-iOS-SPM")]),
]
```

The module is `AmwalECR`, and it brings nothing else with it: Foundation and BSD
sockets, no third-party dependency.

**iOS 12.0+, macOS 12.0+, Swift 5.5+** (this package's floor; the CocoaPods
pod targets iOS 17.0+).

> **Using CocoaPods instead?** The same sources are published as the `AmwalECR`
> pod from [AmwalECR-iOS-CocoaPods](https://github.com/amwal-pay/AmwalECR-iOS-CocoaPods).
> Depend on one or the other, never both in the same target — two copies of the
> module will not link.

### Local network permission

Wi‑Fi / LAN only. iOS asks the user before an app may talk to devices on the
local network. Add this to `Info.plist` or the first LAN `sale` fails with
`unreachable` and no explanation. USB cable and Web Service do not need it.

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Connects to the payment terminal to take card payments.</string>
```

---

## The one rule

**A failure is not a decline.** Of the five `EcrFailure` kinds, four leave the
outcome *unknown*: the terminal may have taken the money and the answer may
simply not have arrived.

| Outcome | The money | What a till does |
|---|---|---|
| `.approved` | taken | Book it. |
| `.declined` | not taken | Tell the customer, offer another card. |
| `.failed(_, .unreachable, _)` | not taken — nothing was sent | Safe to send again. |
| `.failed(_, .timeout, _)` | **unknown** | Inquire by reference. **Never resend.** |
| `.failed(_, .connectionLost, _)` | **unknown** | Inquire by reference. **Never resend.** |
| `.failed(_, .malformed, _)` | **unknown** | Inquire by reference. **Never resend.** |
| `.failed(_, .unauthenticated, _)` | **unknown** | Inquire by reference. **Never resend.** |

`failure.outcomeUnknown` is that column. A response code of `91` comes back as a
*decline*, but it is the terminal saying it does not know either — read
`nextStep` and inquire.

Nothing in this SDK retries a money-moving request, at any level, for any
failure. That is deliberate, and a caller should not add one: the second request
is a second sale, and the customer is charged twice.

What the SDK *does* do is ask. A lost answer is followed by one inquiry — an
inquiry reads and nothing more — and what it found is attached to the result:

```swift
let result = try session.sale(amount: total, merchantReference: order.number)

switch result {
case let .failed(reference, failure, recovered):
    if case let .found(_, transaction, _) = recovered {
        book(transaction)              // the answer was lost; the outcome is not
    } else if failure.outcomeUnknown {
        // Still unknown. Ask again later, quoting `reference`. Never resend.
        _ = try? session.inquireByReference(reference)
    }
case .approved, .declined:
    break
}
```

`result.settled` is the short form of that first branch. Turn the follow-up off
with `EcrConfig.autoInquireOnFailure` if the till runs its own reconciliation.

---

## Implementation

The same walkthrough lives in [`doc/implementation.md`](doc/implementation.md)
for linking from other docs.

Prefer **`EcrSessions.plan` → `EcrSessions.open`**. Sale, inquiry, sign-on,
close-receipt and recovery then share one transport (LAN, USB cable, or Web
Service) and cannot diverge on which client they build. Construct `EcrTerminal`
or `EcrWebServiceTerminal` directly only when you already know the link.

### 1. Plan and open a session

**The app owns persistence** (Keychain / settings) and passes **one** value on
`EcrConfig.secureHashKey` for the selected mode — LAN (Wi‑Fi / USB cable) and
Web Service use different secrets, but the SDK only consumes the field you
assign:

```swift
let secret = settings.secureHashKey(for: selectedMode)

var config = EcrConfig(
    ecrId: "TILL-01",
    currencyCode: "512",      // OMR
    minorUnitDigits: 3,       // baisa
    port: 9100,
    connectTimeout: 10,
    responseTimeout: 120,     // cardholder time, not network time
    probeTimeout: 3
)
config.secureHashKey = secret

let link: EcrLink
switch selectedMode {
case .wifi:
    link = .lan(host: host, port: config.port)
case .usbCable:
    link = .usbCable
case .webService:
    link = .webService(merchantId: merchantId, terminalId: terminalId)
    config.environment = .sit   // .uat / .prod
}

let plan = EcrSessions.plan(link: link, config: config)
guard plan.isReady else {
    screen.show(plan.issues.joined(separator: "\n"))
    return
}

let session = EcrSessions.open(
    terminalSerial: serial,
    plan: plan,
    usbChannel: plan.usesUsbCable ? { myUsbChannel() } : nil
)
```

`EcrConfig.secureHashKeyError` says whether a key is usable before you send
anything. A key that is not is rejected rather than sent unsigned:
`EcrInvalidArgument` on Wi‑Fi / USB cable, `.malformed` failure on Web Service.

Web Service Hub bases: SIT `https://test.amwalpg.com:25452`, UAT
`https://test.amwalpg.com:15452`, PROD `https://pos.amwalpg.com`.

USB cable has no address — you supply an `EcrChannel` that already owns the byte
stream (External Accessory / DriverKit on device). Framing, signing and messages
are identical to Wi‑Fi.

### 2. Sign on (local links)

Ask what the terminal is and what it will accept before offering amounts. Reads
only — no card, no money. Wi‑Fi and USB cable send `SIGN_ON`. A Web Service
session answers `.unavailable` and sends nothing (the till already named that
terminal when it opened the session).

```swift
guard session.supportsSignOn else { /* Web Service — skip */ ; return }

switch try session.signOn() {
case let .available(_, capabilities, _):
    guard capabilities.permits(.sale) else { return }
    if let limits = capabilities.limitsFor(.sale) {
        amountField.clamp(min: limits.minAmount, max: limits.maxAmount)
    }
case let .unavailable(_, reason, _, _):
    screen.show(reason)
case let .failed(_, failure):
    screen.show(failure.message)
}
```

| `EcrSignOn` | Meaning |
|---|---|
| `.available` | Profile and permits are usable |
| `.unavailable` | Terminal said no, or Web Service (nothing sent) |
| `.failed` | Link broke before a readable answer |

`supportsSignOn` and `supportsReceipt` are `true` on Wi‑Fi and USB cable
(`usesLocalTerminal`). Close-receipt uses that same local gate
(`usesLocalTerminal`); there is no `supportsCloseReceipt` property.

A later decline can carry `EcrDeclined.capabilities` when the refusal includes
`profileChanged`, so the till can refresh what is permitted without signing on
again.

### 3. Take a payment

```swift
DispatchQueue.global(qos: .userInitiated).async {
    let result = try? session.sale(amount: total, merchantReference: order.number)
    DispatchQueue.main.async {
        guard let result else { return }
        screen.show(result)
    }
}

// The operator gave up. This stops the wait on a LAN TCP socket — it does not
// stop the terminal, and the outcome is unknown. Web Service and a
// caller-supplied USB channel are unaffected.
session.cancel()
```

On Wi‑Fi and USB cable, every request is signed — HMAC-SHA256 over the sorted
top-level fields (field `secureHash`), with a per-message nonce — and every
answer is checked, both that it carries this till's signature and that it echoes
*this* request's nonce. An answer failing either check is `.unauthenticated`:
something else may have replied on the terminal's port, so the answer is
discarded rather than believed. It is not a decline, and the transaction may
well have completed. Web Service signs the JSON body instead (HMAC-SHA256 under
the Web Service secret, field `secureHashValue`) and has no per-request nonce.

**Every call blocks** while the terminal works, which for a sale is as long as
the cardholder takes. Run them off the main thread.

### 4. Close the receipt (local links)

When the result UI is dismissed, ask the terminal to put its paper/e-receipt
away and return to idle. Moves no money; safe to repeat — an already-idle
terminal answers `.idle` the same way. Wi‑Fi and USB cable send `CLOSE_RECEIPT`.
Web Service answers `.refused` and sends nothing (the terminal is not on the
till's counter). A terminal too old to know the request also answers `.refused`;
treat that as "cannot be asked" and carry on.

```swift
func resultDialogDidDismiss() {
    guard session.usesLocalTerminal else { return }
    switch try? session.closeReceipt() {
    case .idle, .none:
        break
    case let .refused(_, _, reason, _):
        screen.log(reason)                   // unsupported or terminal refused
    case let .failed(_, failure):
        screen.log(failure.message)          // link broke; safe to ask again
    }
}
```

| `EcrReceiptClosed` | Meaning |
|---|---|
| `.idle` | Receipt dismissed / terminal already idle |
| `.refused` | Terminal said no, or Web Service (nothing sent) |
| `.failed` | Link broke before a readable answer |

---

## Operations

| | Method | Needs |
|---|---|---|
| Reachability | `probeReachability()` → `EcrReachability?` on the session; `isReachable()` / `probeReachability()` → `EcrReachability` on `EcrTerminal` | Wi‑Fi / USB; Web Service session returns `nil` |
| Sign-on | `signOn(merchantReference:)` → `EcrSignOn` | Wi‑Fi or USB cable (`supportsSignOn`) |
| Sale | `sale(amount:merchantReference:)` → `EcrResult` | amount |
| Void | `void(receiptNumber:originalTerminalId:merchantReference:)` → `EcrResult` | the original's receipt number |
| Refund | `refund(amount:receiptNumber:transactionDate:originalTerminalId:merchantReference:)` → `EcrResult` | amount, receipt number, date |
| Inquiry | `inquire(receiptNumber:transactionDate:originalTerminalId:merchantReference:)` → `EcrInquiry` | receipt number, date |
| Inquiry by reference | `inquireByReference(_:transactionDate:originalTerminalId:merchantReference:)` → `EcrInquiry` | the original's reference |
| Close receipt | `closeReceipt(merchantReference:)` → `EcrReceiptClosed` | Wi‑Fi or USB cable (`usesLocalTerminal`) |
| E-receipt | `receipt(receiptNumber:transactionDate:originalTerminalId:merchantReference:)` → `EcrReceipt` | receipt number, date (`supportsReceipt`) |

On `EcrTerminal` only, sale / void / refund also share `run(_:amount:originalStan:originalTerminalId:originalDate:merchantReference:)`. Inquiry, receipt, sign-on, and close-receipt are dedicated methods — passing them to `run` traps. `EcrOpenedSession` exposes the dedicated methods only.

### What each transport supports

| | Wi‑Fi | USB cable | Web Service |
|---|---|---|---|
| Sale / void / refund / inquiry | ✔ | ✔ | ✔ |
| Sign-on | ✔ | ✔ | `.unavailable` — nothing sent |
| Close receipt | ✔ | ✔ | `.refused` — nothing sent |
| E-receipt URL | ✔ | ✔ | `.unavailable` — nothing sent |
| `probeReachability` | ✔ | ✔ | `nil` |
| `cancel` | stops LAN TCP wait | no-op unless the channel is `TcpEcrChannel` | no-op |

USB cable has no built-in hardware driver in this package — you supply an
`EcrChannel`. Framing, signing, and messages match Wi‑Fi.

Both inquiries read and change nothing, so they are safe to repeat, and the
terminal answers them even while it is taking a payment — which is exactly when a
till needs them.

`merchantReference` is optional everywhere and is the till's own name for the
transaction: an order number, a basket id, whatever already names it in the
caller's system. Left out, the SDK generates one. Either way it comes back on the
outcome, and it is the only identifier a till holds *before* the terminal
answers — which is what makes `inquireByReference` the lookup that still works
when nothing else does.

On Wi‑Fi and USB cable, arguments that cannot be used — a reference over 32
characters or carrying a space, `&` or `=`; a secret that is not hex — throw
`EcrInvalidArgument` and nothing is sent. Over Web Service those same mistakes
come back as `.failed(…, .malformed, …)` (or inquiry `.failed`) without
throwing. Everything that happens on the wire after a request is sent is an
`EcrResult` (or `EcrSignOn` / `EcrReceiptClosed` / `EcrReceipt` / `EcrInquiry`),
never an exception for a terminal refusal.

---

## Configuration

```swift
var config = EcrConfig(
    ecrId: "TILL-01",         // how this till names itself
    currencyCode: "512",      // OMR
    minorUnitDigits: 3,       // baisa
    port: 9100,
    connectTimeout: 10,       // seconds
    responseTimeout: 120,     // the cardholder's time, not the network's
    probeTimeout: 3,          // probe / isReachable only
    environment: .sit         // Web Service only
)
config.secureHashKey = secret
```

`responseTimeout` is 120 seconds because a sale waits for a human being to
present a card and key a PIN. Shortening it does not make the terminal faster;
it makes a completed sale time out and land in the unknown-outcome path.

---

## Amounts

Amounts are `Decimal`, never `Double`. A binary float cannot hold `1.234`, and an
amount that is off by a thousandth is a wrong charge.

```swift
guard let amount = EcrDecimal.parse(field.text ?? "") else { return }   // no locale surprises
_ = try session.sale(amount: amount)
```

The conversion to the wire's minor units happens once, inside the SDK, half-up —
matching the Kotlin SDK to the last minor unit, so an Android till and an iOS
till cannot disagree about a rounding boundary.

Amounts come back as strings in major units (`"1.234"`), exactly as reported.

---

## Documentation

The protocol and the operational detail are shared with the Android SDK and are
not duplicated here:

| | |
|---|---|
| **[Implementation](doc/implementation.md)** | Plan, open, sign-on, sale, close receipt on this package |
| **[Wire protocol](https://github.com/amwal-pay/ECR-simulator/blob/main/ecr-sdk/docs/protocol.md)** | The bytes on the socket |
| **[Integration guide](https://github.com/amwal-pay/ECR-simulator/blob/main/ecr-sdk/docs/integration-guide.md)** | From an empty project to a till that reconciles properly |
| **[Troubleshooting](https://github.com/amwal-pay/ECR-simulator/blob/main/ecr-sdk/docs/troubleshooting.md)** | Symptom → cause → fix |
| **[Compatibility matrix](https://github.com/amwal-pay/amwal-ecr-flutter/blob/main/doc/compatibility-matrix.md)** | Versions, floors, and every place the platforms differ |
| **[Release policy](https://github.com/amwal-pay/amwal-ecr-flutter/blob/main/doc/release-policy.md)** | Versioning, release order, rollback |

---

## Building and testing

```bash
swift test            # no simulator needed
```

Unit tests share signing placeholders via `EcrTestConfigs` (aligned with
`ecr_sdk`): `SECURE_HASH_KEY_ECR_WIFI`, `SECURE_HASH_KEY_ECR_WIFI_OTHER`, and
`SECURE_HASH_KEY_WEBSERVICE`, exposed as `lan` / `lanOther` / `webService`
configs. Never commit real Amwal keys.

The suite is not incidental to the platform story: `EcrDecimalTests`,
`EcrMessageTests` and `EcrResponseReaderTests` assert this SDK against the Kotlin
SDK's own test payloads and rounding boundaries. That is what keeps "identical on
both platforms" a checkable claim.

### Continuous integration

[`codemagic.yaml`](codemagic.yaml) runs on Codemagic:

| Workflow | When | What it does |
|---|---|---|
| `spm-verify` | every push and pull request | `swift test` and builds for iOS device + simulator |
| `spm-release` | a `vX.Y.Z` tag | same checks, verifies the tag matches the top `CHANGELOG.md` entry, then resolves that exact version from GitHub into a throwaway consumer package |

The tag *is* the SwiftPM release — nothing is uploaded and no credentials are
needed. Start a release by pushing the tag — `git push origin vX.Y.Z` — so
Codemagic receives a tag webhook (`CM_TAG` is set). A manual rebuild of a tagged
commit also works: the script falls back to `git describe` when `CM_TAG` is
empty. Do not start `spm-release` on a branch; that fails.

Tag SwiftPM first, then the matching `vX.Y.Z` on
[AmwalECR-iOS-CocoaPods](https://github.com/amwal-pay/AmwalECR-iOS-CocoaPods);
see the release policy in
[amwal-ecr-flutter](https://github.com/amwal-pay/amwal-ecr-flutter/blob/main/doc/release-policy.md).
