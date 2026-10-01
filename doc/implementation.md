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
