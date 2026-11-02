# Amwal ECR SDK for iOS

`AmwalECR` drives an Amwal POS terminal from an iOS or macOS till: sale, void, refund, inquiry, e-receipt, close receipt, settlement, and sign-on. Wi-Fi and USB use the terminal's ECR port. Web Service uses HTTPS to the Amwal Hub. Card data stays on the terminal: your app receives a masked PAN at most.

Package `AmwalECR` **0.3.1**. Open one session, call the operation, then read the result. It is the iOS counterpart of the [Kotlin SDK](https://github.com/amwal-pay/ECR-simulator/blob/main/ecr-sdk), method for method and outcome for outcome.

## Install

- iOS 12.0 or later, macOS 12.0 or later, Swift 5.5 or later. No third-party dependency.
- Wi-Fi needs the local network permission. Add this to `Info.plist`, or the first Wi-Fi sale fails with `.unreachable` and no explanation. USB cable and Web Service do not need it.

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Connects to the payment terminal to take card payments.</string>
```

In Xcode: **File ▸ Add Package Dependencies…**, then `https://github.com/amwal-pay/AmwalECR-iOS-SPM.git`, *Up to Next Minor Version* from `0.3.1`. Or in a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/amwal-pay/AmwalECR-iOS-SPM.git", .upToNextMinor(from: "0.3.1")),
],
targets: [
    .target(name: "Till", dependencies: [.product(name: "AmwalECR", package: "AmwalECR-iOS-SPM")]),
]
```

Pin the version. A patch release can add API. The same sources are published as the `AmwalECR` pod from [AmwalECR-iOS-CocoaPods](https://github.com/amwal-pay/AmwalECR-iOS-CocoaPods). Depend on one or the other, never both in the same target.

## Open a session

<a id="ecropenedsession"></a>

Open one session for the terminal and keep it, every sale, void, refund, inquiry, e-receipt, and close receipt can use it. **Every call blocks** while the terminal works, which for a sale is as long as the cardholder takes. Run them off the main thread.

### Wi-Fi implementation

Each terminal shows its IP and port on the idle screen. Use that IP and port to connect from the till and send operations to that terminal. The till and the terminal must be on the same Wi-Fi.

```swift
import AmwalECR

var config = EcrConfig()
config.secureHashKey = wifiKey

let plan = EcrSessions.plan(
    link: .lan(host: "192.168.1.50"),   // port defaults to 9100
    config: config
)

guard plan.isReady else {
    show(plan.issues.joined(separator: "; "))
    return
}

let session = EcrSessions.open(terminalSerial: "P653200085189", plan: plan)
```

### Web Service implementation

```swift
var config = EcrConfig()
config.secureHashKey = webServiceKey
config.environment = .uat             // .sit is the default; .prod for live

let plan = EcrSessions.plan(
    link: .webService(merchantId: "13593", terminalId: "101311"),
    config: config
)

let session = EcrSessions.open(terminalSerial: "P653200008251", plan: plan)
```

Hub addresses stay inside the SDK. `EcrEnvironment.fromName` reads `SIT`, `UAT`, and `PROD`, ignoring case. Any other name reads as `SIT`.

### USB cable implementation

There is no IP address. The terminal profile is USB cable, and the signing key is the Wi-Fi key. This package has no hardware driver: you supply an `EcrChannel` that already owns the byte stream (External Accessory or DriverKit on the device). The bytes are the same framed messages as Wi-Fi.

```swift
let plan = EcrSessions.plan(link: .usbCable, config: config)

guard plan.isReady else {
    show(plan.issues.joined(separator: "; "))
    return
}

let session = EcrSessions.open(
    terminalSerial: "P653200085189",
    plan: plan,
    usbChannel: { myUsbChannel() }
)
```

`open` requires `usbChannel` for a cable plan. A cable session uses the same sale, void, refund, inquiry, e-receipt, and close receipt calls as Wi-Fi.

## Operations

Amounts are `Decimal` in major units, never `Double`. Build them from text with `EcrDecimal.parse("1.234")`. `merchantReference` names this attempt. Save it before the call. Leave it blank and the SDK generates one and returns it on the result.

### Sale

The cardholder presents the card on the terminal.

```swift
let reference = "ORDER-1001-1"
save(reference)

let result = try session.sale(amount: EcrDecimal.parse("1.234")!, merchantReference: reference)
```

Read `result` with the `switch` in [Read the result](#read-the-result).

### Void

Cancels an earlier transaction for its full amount. No card. `receiptNumber` is the receipt number (STAN). `originalTerminalId` names another terminal when the original was not taken on this one. Web Service ignores it and uses the terminal in the plan. The void has its own merchant reference.

```swift
let result = try session.void(
    receiptNumber: stan,
    originalTerminalId: "",
    merchantReference: "ORDER-1001-V1"
)
```

### Refund

Returns some or all of an earlier transaction. The cardholder presents the card. `transactionDate` is the original day, `yyyyMMdd`.

```swift
let result = try session.refund(
    amount: EcrDecimal.parse("1.000")!,
    receiptNumber: stan,
    transactionDate: "20261019",
    originalTerminalId: "",
    merchantReference: "ORDER-1001-R1"
)
```

### Inquiry by receipt number

Reads a transaction. No card, no money. Safe to repeat, and the terminal answers even while another payment is in progress.

```swift
let inquiry = try session.inquire(
    receiptNumber: stan,
    transactionDate: "20261019"
)
```

### Inquiry by merchant reference

Reads the attempt you named. Use this when the sale, void, or refund never answered: you still have the reference you sent, and you do not yet have a receipt number. `transactionDate` is optional. On Wi-Fi and USB, `originalTerminalId` names another terminal.

```swift
let inquiry = try session.inquireByReference("ORDER-1001-1")
```

If the Hub cannot be reached, a Web Service inquiry answers `.failed(…, .connectionLost)`, never `.notFound`.

### E-receipt

Wi-Fi and USB. Returns a URL for a QR code. Safe to repeat. `.ready` carries `url`. `.unavailable` means there is no receipt to show. `.failed` means the exchange failed; repeat the call.

```swift
let receipt = try session.receipt(
    receiptNumber: stan,
    transactionDate: "20261019"
)

if case let .ready(_, url, _) = receipt {
    showQr(url)
}
```

On Web Service the same call returns `.unavailable` without sending anything. `session.supportsReceipt` is false there.

### Close receipt

<a id="close-receipt"></a>

Wi-Fi and USB send `CLOSE_RECEIPT`. Web Service posts `/Ecr/closeReceipt` and needs the sale, void, or refund reference as `originalMerchantReference`. Call it from the till's Close receipt action when the cashier is finished. Sale, void, refund, and dismissing a dialog do not send it. Safe to repeat: `.idle` means the terminal is idle, whether a receipt was up or not.

```swift
let closed = try session.closeReceipt()

switch closed {
case .idle:
    break
case let .refused(_, _, reason, _):
    show(reason)            // firmware has no CLOSE_RECEIPT; leave the receipt up
case let .failed(_, failure):
    show(failure.message)   // nothing changed; the call can be repeated
}
```

```swift
// Web Service: the second argument is the sale / void / refund reference.
let closed = try session.closeReceipt(originalMerchantReference: saleReference)
```

A Web Service close with no original reference answers `.failed` and sends nothing. App to app is not driven on iOS.

### Settlement

<a id="settlement"></a>

Closes the current batch, the same Manual settlement as the terminal's merchant menu. Wi-Fi and USB send `SETTLEMENT` on the same session as a sale. Confirm with the cashier first: the terminal does not ask, and the close starts as soon as the request arrives. The terminal must be idle. Safe to repeat when the answer is lost: a batch that closed answers `.nothingToSettle` the next time, and one that did not settles on the retry.

Web Service posts `/Ecr/settle` (identity, currency, and both timestamps — no `messageType`). `supportsSettlement` is true when the session has a local link or a Web Service client, and `settlement()` reads the answer the same way as Wi-Fi `SETTLEMENT`.

```swift
switch try session.settlement() {
case let .settled(_, batchId, _, _, _, _, netAmount, totals, _):
    show(batchId, netAmount, totals)
case let .nothingToSettle(_, message, _):
    show(message)
case let .notSettled(_, _, _, reason, _, _):
    show(reason)
case let .failed(_, failure):
    show(failure.message)   // the batch may or may not have closed
}
```

Amounts in `.settled` are major units. `totals` always has `SALE`, `REFUND`, `VOID`, `PRE_AUTH`, and `CAPTURE`, each an `EcrSettlementTotal`, with a zero row where the terminal omitted one. `closeReceipt` puts the terminal's settlement summary away sooner; it is the same call as after a sale.

### Sign-on

Wi-Fi and USB. Asks the terminal what it will accept before you offer operations to the cashier. `.available` carries `capabilities`: the terminal name, currency, whether e-receipt and physical receipt are on, and the permitted operations with their limits.

```swift
switch try session.signOn() {
case let .available(_, capabilities, _):
    guard capabilities.permits(.sale) else { return }
    if let limits = capabilities.limitsFor(.sale) {
        amountField.clamp(min: limits.minAmount, max: limits.maxAmount)
    }
case let .unavailable(_, reason, _, _):
    show(reason)
case let .failed(_, failure):
    show(failure.message)
}
```

On Web Service the call returns `.unavailable` without sending anything. `session.supportsSignOn` is false there. A later decline can carry `EcrDeclined.capabilities` when the terminal's profile changed, so the till can refresh what is permitted without signing on again.

### Reachability

Wi-Fi and USB, before a sale. Proves the port or cable answers. It does not prove the terminal is idle.

```swift
if let probe = session.probeReachability(), !probe.reachable {
    show(probe.error ?? probe.endpoint)
}
```

`probeTimeout` is 3 seconds. Web Service returns `nil` from `probeReachability`, so a sale is not held for a Hub probe.

## Read the result

<a id="handle-the-result"></a>

`sale`, `void`, and `refund` return `EcrResult`.

```swift
switch result {
case let .approved(approved):
    record(approved.merchantReference, approved.amount, approved.rrn, approved.authCode)
    if approved.partialApproval {
        collectBalance(asked: approved.requestedAmount, taken: approved.amount)
    }

case let .declined(declined):
    show(declined.reason)

case let .failed(_, _, .found(_, transaction, _)?):
    apply(transaction)

case let .failed(reference, failure, _) where failure.outcomeUnknown:
    markUnresolved(reference)

case let .failed(_, failure, _):
    show(failure.message)
}
```

| Result                                    | Meaning                                                                                                                                                                 |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.approved`                               | Money moved. `amount` is what was taken or returned. `responseCode` is `00` on a plain approval. `maskedPan` is masked.                                                |
| `.approved` with `partialApproval`        | The issuer authorised less than you asked. `requestedAmount` is what you asked. Collect the difference before you hand over the goods.                                 |
| `.declined`                               | The terminal answered and refused. `reason` is the text to show. `nextStep` is `.none`, except for `91`, where the terminal does not know either: inquire.             |
| `.failed` and `.unreachable`              | Nothing was sent. Wi-Fi and USB only.                                                                                                                                   |
| `.failed` and `failure.outcomeUnknown`    | The request went out and the answer did not settle it: timeout, connection lost, malformed answer, or a signature that does not match. The payment may have completed. |
| `result.settled`                          | Wi-Fi or USB already inquired. `recovered` is `.found`. Record that transaction.                                                                                        |
| `EcrInvalidArgument`                      | Wi-Fi and USB: the call was rejected before anything was sent. A merchant reference longer than 32 characters, or one that contains a space, `&`, or `=`, throws here. Web Service answers `.failed(…, .malformed, …)` instead of throwing. |

An answer whose `nextStep` is `INQUIRE_BY_MERCHANT_REFERENCE` arrives as `.failed` (`.timeout` or `.connectionLost`), not `.declined`. That includes a Web Service timeout, a lost HTTP call, an empty or unreadable body, and an HTTP 5xx. `failure.outcomeUnknown` is false only for `.unreachable`.

### Inquiry

| Result      | Meaning                                                                                                                                            |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.found`    | `transaction` is the record. `status` is the outcome (`Approved`, `Declined`, `Voided`, or other text from the backend). Compare it ignoring case. |
| `.notFound` | This lookup returned no record. `reason` is the backend's text when it sent any.                                                                   |
| `.failed`   | The lookup itself failed. Repeat the inquiry. An inquiry does not move money.                                                                      |

On `.found`, `transaction.stan` is the receipt number. `canVoid` and `canRefund` say whether the terminal would accept that operation now. When `partialApproval` is set, `amount` is what was asked and `authorizedAmount` is what was charged.

## Important notes

### Resolve an unknown outcome

<a id="resolve-an-unknown-outcome"></a>

`failure.outcomeUnknown` means the payment may have completed. Inquire by the merchant reference of that attempt. Charge the order again only after `transaction.status` is `Declined`, or after the terminal confirms the attempt did not complete. Nothing in this SDK retries a money-moving request, and neither should you: the second request is a second sale.

1. Save the reference before `sale`, `void`, or `refund`.
2. On Wi-Fi and USB, read `result.recovered` first. With `autoInquireOnFailure` left on (the default), the SDK has already called `inquireByReference` once. `.found` settles the attempt. `.notFound`, `.failed`, or nil leaves it unknown.
3. Call `inquireByReference` with the saved reference.
4. Read `transaction.status`, ignoring case.
   - `Approved` — the attempt completed. On a void or refund, the void or refund completed.
   - `Declined` — it did not. A new attempt needs a new reference.
   - Any other value, including `Voided` and `Reversed` — leave the order unresolved.
5. `.notFound` after a lost answer means this lookup returned no record. The same answer follows a terminal reset, or a record that has aged out. Confirm on the terminal, or with Amwal, before you take payment again.
6. `.failed` means the lookup failed. Inquire again.
7. On startup, inquire every attempt still marked unresolved.

`.unreachable` means the connection was never made. There is no attempt to look up.

### Merchant reference

32 characters maximum, with space, `&`, and `=` excluded. Use one reference per attempt; an order number plus an attempt suffix fits. A void and a refund each get a new reference.

### Receipt number

`.approved` does not carry it. Read `transaction.stan` from an inquiry by merchant reference, or read the printed receipt. Pass that receipt's day as `yyyyMMdd` to refund, inquiry by receipt number, and e-receipt. A receipt number is unique on one terminal for one day.

### Amounts and currency

`currencyCode` defaults to `"512"` and `minorUnitDigits` to `3` (OMR). Another currency needs both. The SDK converts to the wire's minor units once, rounding half up, matching the Kotlin SDK to the last minor unit. Amounts come back as strings in major units (`"1.234"`).

### Timeouts

| Transport                  | Wait                                                                                                                                         |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Wi-Fi                      | `connectTimeout` 10 s, then `responseTimeout` 120 s. A lost answer can add one more response wait for the automatic inquiry.               |
| USB                        | `responseTimeout` 120 s, the same as Wi-Fi.                                                                                                  |
| Web Service through `plan` | A `responseTimeout` of 120 s becomes `EcrConfig.webServiceResponseTimeout` (130 s). Any other value is kept.                                 |

The default wait covers card present and PIN. Shortening it does not make the terminal faster; it makes a completed sale time out. `session.cancel()` stops the wait on a Wi-Fi socket only; it does not stop the terminal, and the outcome is unknown.

### Keys

Even-length hex, at least 16 characters. `EcrConfig.secureHashKeyError` says whether a key is usable before you send anything. A key that is not is rejected rather than sent unsigned: `EcrInvalidArgument` on Wi-Fi and USB, a `.malformed` failure on Web Service.

Wi-Fi and USB sign the field `secureHash`, with a per-message nonce that the answer must echo. Web Service signs `secureHashValue`. The two secrets are issued separately. `plan.signingKeyLabel` names the one this plan expects.

### Logging

```swift
let logger = EcrLogger { print($0) }
let session = EcrSessions.open(terminalSerial: serial, plan: plan, logger: logger)
```

Logging is off until you pass a logger. `EcrLogger.none` discards every line. Treat the lines as transaction records: a signed message's `secureHash` appears in them, though never the key.

## When you build the message yourself

`EcrTransactionType` is `.sale`, `.void`, `.refund`, `.inquiry`, `.receipt`, `.signOn`, `.closeReceipt`. `EcrTransactionType.menuOptions` is the operator menu: sale, void, refund, inquiry. `requiresAmount`, `requiresOriginalStan`, `requiresOriginalDate`, `movesMoney`, and `allowsOtherTerminal` say which fields that operation needs. `EcrTerminal.run` accepts only the three that move money; passing any other type traps.

The wire format is in [the protocol](https://github.com/amwal-pay/ECR-simulator/blob/main/ecr-sdk/docs/protocol.md). Building, testing, and continuous integration are in [Development](doc/development.md).
