# Amwal ECR SDK for iOS

Drive an Amwal POS terminal from your own iOS application over the local
network.

Your application asks for a payment; the terminal reads the card, talks to the
payment backend, and answers. **No card data passes through your application** —
you receive a masked PAN at most, so integrating does not pull your app into PCI
scope the way handling card numbers would.

```swift
import AmwalECR

let terminal = EcrTerminal(host: "192.168.1.50", serialNumber: "P2M12345678")

switch terminal.sale(amount: Decimal(string: "1.234")!) {
case let .approved(sale):   receipt.print(rrn: sale.rrn, auth: sale.authCode)
case let .declined(refusal): screen.show(refusal.reason)
case let .failed(_, failure): screen.show(failure.message)   // outcome unknown
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
Version* from `0.2.0`.

Or in a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/amwal-pay/AmwalECR-iOS-SPM.git", .upToNextMinor(from: "0.2.0")),
],
targets: [
    .target(name: "Till", dependencies: [.product(name: "AmwalECR", package: "AmwalECR-iOS-SPM")]),
]
```

The module is `AmwalECR`, and it brings nothing else with it: Foundation and BSD
sockets, no third-party dependency.

**iOS 12.0+, macOS 12.0+, Swift 5.5+.**

> **Using CocoaPods instead?** The same sources are published as the `AmwalECR`
> pod from [AmwalECR-iOS-CocoaPods](https://github.com/amwal-pay/AmwalECR-iOS-CocoaPods).
> Depend on one or the other, never both in the same target — two copies of the
> module will not link.

### Local network permission

iOS asks the user before an app may talk to devices on the local network. Add
this to `Info.plist` or the first `sale` fails with `unreachable` and no
explanation:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Connects to the payment terminal to take card payments.</string>
```

---

## The one rule

**A failure is not a decline.** Four of the six things that can happen to a
request leave the outcome *unknown*: the terminal may have taken the money and
the answer may simply not have arrived.

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
let result = try terminal.sale(amount: total, merchantReferenceId: order.number)

switch result {
case let .failed(reference, failure, recovered):
    if case let .found(_, transaction, _) = recovered {
        book(transaction)              // the answer was lost; the outcome is not
    } else if failure.outcomeUnknown {
        // Still unknown. Ask again later, quoting `reference`. Never resend.
        _ = try? terminal.inquireByReference(reference)
    }
case .approved, .declined:
    break
}
```

`result.settled` is the short form of that first branch. Turn the follow-up off
with `EcrConfig.autoInquireOnFailure` if the till runs its own reconciliation.

---

## Operations

| | Method | Needs |
|---|---|---|
| Reachability | `isReachable()` | — |
| Sale | `sale(amount:merchantReferenceId:)` | amount |
| Void | `void(receiptNumber:originalTerminalId:merchantReferenceId:)` | the original's receipt number |
| Refund | `refund(amount:receiptNumber:transactionDate:originalTerminalId:merchantReferenceId:)` | amount, receipt number, date |
| Inquiry | `inquire(receiptNumber:transactionDate:originalTerminalId:merchantReferenceId:)` | receipt number, date |
| Inquiry by reference | `inquireByReference(_:transactionDate:originalTerminalId:merchantReferenceId:)` | the original's reference |
| E-receipt | `receipt(receiptNumber:transactionDate:originalTerminalId:merchantReferenceId:)` | receipt number, date |

Both inquiries read and change nothing, so they are safe to repeat, and the
terminal answers them even while it is taking a payment — which is exactly when a
till needs them.

`merchantReferenceId` is optional everywhere and is the till's own name for the
transaction: an order number, a basket id, whatever already names it in the
caller's system. Left out, the SDK generates one. Either way it comes back on the
outcome, and it is the only identifier a till holds *before* the terminal
answers — which is what makes `inquireByReference` the lookup that still works
when nothing else does.

The money-moving calls `throw` only for arguments that cannot be used: a
reference over 32 characters or carrying a space, `&` or `=`; a secret that is
not hex. Nothing is sent in that case. Everything that happens on the wire is an
`EcrResult`, never an exception.

---

## Signing the link

A terminal refuses what it cannot verify, so in practice a till needs the secret
Amwal issues for it:

```swift
var config = EcrConfig()
config.secureHashKey = secret          // hex, from the keychain — never in source
let terminal = EcrTerminal(host: host, serialNumber: serial, config: config)
```

Every request is then signed — HMAC-SHA256 over the sorted top-level fields, with
a per-message nonce — and every answer is checked, both that it carries this
till's signature and that it echoes *this* request's nonce. An answer failing
either check is `.unauthenticated`: something else may have replied on the
terminal's port, so the answer is discarded rather than believed. It is not a
decline, and the transaction may well have completed.

`EcrConfig.secureHashKeyError` says whether a key is usable before you send
anything; a key that is not throws `EcrInvalidArgument` at the first call rather
than being sent unsigned.

**Every call blocks** while the terminal works, which for a sale is as long as
the cardholder takes. Run them off the main thread and call `cancel()` from
another thread to stop waiting:

```swift
DispatchQueue.global(qos: .userInitiated).async {
    let result = terminal.sale(amount: total)
    DispatchQueue.main.async { screen.show(result) }
}

// The operator gave up. This stops the wait — it does not stop the terminal,
// and the outcome is unknown.
terminal.cancel()
```

---

## Configuration

```swift
let terminal = EcrTerminal(
    host: "192.168.1.50",
    serialNumber: "P2M12345678",
    config: EcrConfig(
        ecrId: "TILL-01",         // how this till names itself
        currencyCode: "512",      // OMR
        minorUnitDigits: 3,       // baisa
        port: 9100,
        connectTimeout: 10,       // seconds
        responseTimeout: 120,     // the cardholder's time, not the network's
        probeTimeout: 3           // isReachable only
    )
)
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
terminal.sale(amount: amount)
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
| **[Wire protocol](https://github.com/amwal-pay/ECR-simulator/blob/main/ecr-sdk/docs/protocol.md)** | The bytes on the socket |
| **[Integration guide](https://github.com/amwal-pay/ECR-simulator/blob/main/ecr-sdk/docs/integration-guide.md)** | From an empty project to a till that reconciles properly |
| **[Troubleshooting](https://github.com/amwal-pay/ECR-simulator/blob/main/ecr-sdk/docs/troubleshooting.md)** | Symptom → cause → fix |
| **[Compatibility matrix](https://github.com/amwal-pay/amwal-ecr-flutter/blob/main/doc/compatibility-matrix.md)** | Versions, floors, and every place the platforms differ |
| **[Release policy](https://github.com/amwal-pay/amwal-ecr-flutter/blob/main/doc/release-policy.md)** | Versioning, release order, rollback |

---

## Building and testing

```bash
swift test            # 37 tests, no simulator needed
```

The suite is not incidental to the platform story: `EcrDecimalTests`,
`EcrMessageTests` and `EcrResponseReaderTests` assert this SDK against the Kotlin
SDK's own test payloads and rounding boundaries. That is what keeps "identical on
both platforms" a checkable claim.
# AmwalECR-iOS-SPM
