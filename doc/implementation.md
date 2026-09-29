# AmwalECR (SwiftPM) — implementation

How a till opens a session, signs on, takes a payment, and closes the
receipt with this package. The same content is summarised in the
[README](../README.md#implementation).

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
anything; a key that is not throws `EcrInvalidArgument` at the first call rather
than being sent unsigned.

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

// The operator gave up. This stops the wait — it does not stop the terminal,
// and the outcome is unknown.
session.cancel()
```

Every request is signed — HMAC-SHA256 over the sorted top-level fields, with a
per-message nonce — and every answer is checked, both that it carries this
till's signature and that it echoes *this* request's nonce. An answer failing
either check is `.unauthenticated`: something else may have replied on the
terminal's port, so the answer is discarded rather than believed. It is not a
decline, and the transaction may well have completed.

**Every call blocks** while the terminal works, which for a sale is as long as
the cardholder takes. Run them off the main thread.

### 4. Close the receipt (local links)

When the result UI is dismissed, ask the terminal to put its paper/e-receipt
away and return to idle. Moves no money; safe to repeat. Wi‑Fi and USB cable
send `CLOSE_RECEIPT`. Web Service answers `.refused` and sends nothing.

```swift
func resultDialogDidDismiss() {
    guard session.supportsSignOn else { return }  // same local-only gate
    _ = try? session.closeReceipt()
}
```

---

## Operations

| | Method | Needs |
|---|---|---|
| Reachability | `probeReachability()` / `isReachable()` | local links |
| Sign-on | `signOn(merchantReference:)` | Wi‑Fi or USB cable |
| Sale | `sale(amount:merchantReference:)` | amount |
| Void | `void(receiptNumber:originalTerminalId:merchantReference:)` | the original's receipt number |
| Refund | `refund(amount:receiptNumber:transactionDate:originalTerminalId:merchantReference:)` | amount, receipt number, date |
| Inquiry | `inquire(receiptNumber:transactionDate:originalTerminalId:merchantReference:)` | receipt number, date |
| Inquiry by reference | `inquireByReference(_:transactionDate:originalTerminalId:merchantReference:)` | the original's reference |
| Close receipt | `closeReceipt(merchantReference:)` | Wi‑Fi or USB cable |
| E-receipt | `receipt(receiptNumber:transactionDate:originalTerminalId:merchantReference:)` | receipt number, date (local links) |

Both inquiries read and change nothing, so they are safe to repeat, and the
terminal answers them even while it is taking a payment — which is exactly when a
till needs them.

`merchantReference` is optional everywhere and is the till's own name for the
transaction: an order number, a basket id, whatever already names it in the
caller's system. Left out, the SDK generates one. Either way it comes back on the
outcome, and it is the only identifier a till holds *before* the terminal
answers — which is what makes `inquireByReference` the lookup that still works
when nothing else does.

The money-moving calls `throw` only for arguments that cannot be used: a
reference over 32 characters or carrying a space, `&` or `=`; a secret that is
not hex. Nothing is sent in that case. Everything that happens on the wire is an
`EcrResult` (or `EcrSignOn` / `EcrReceiptClosed`), never an exception for a
terminal refusal.

---
