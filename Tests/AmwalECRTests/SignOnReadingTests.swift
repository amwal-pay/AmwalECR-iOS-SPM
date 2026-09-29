import XCTest
@testable import AmwalECR

/// A sign-on is how a till learns what a terminal will accept, and a refusal is
/// how it learns that the answer has since changed.
final class SignOnReadingTests: XCTestCase {

    private func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    private let available = """
    {
      "success": true,
      "responseCode": "00",
      "message": "Sign-on accepted",
      "data": {
        "available": true,
        "ecrMode": 2,
        "ecrModeName": "WIFI",
        "terminalName": "Counter 3",
        "currencyCode": "512",
        "minorUnitDigits": 3,
        "eReceipt": true,
        "physicalReceipt": false,
        "permittedTransactions": [
          { "messageType": "SALE", "minAmount": "0.010", "maxAmount": "5.000" },
          { "messageType": "VOID" },
          { "messageType": "INQUIRY" },
          { "messageType": "RECEIPT" }
        ]
      },
      "errorList": []
    }
    """

    func testATerminalInServiceIsReadFieldForField() {
        guard case let .available(_, capabilities, _) = EcrTerminal.signOn(
            from: json(available),
            merchantReference: "A1B2C3D4E5F6"
        ) else {
            return XCTFail("expected available")
        }

        XCTAssertTrue(capabilities.available)
        XCTAssertEqual(.wifi, capabilities.transport)
        XCTAssertEqual("Counter 3", capabilities.terminalName)
        XCTAssertEqual("512", capabilities.currencyCode)
        XCTAssertEqual(3, capabilities.minorUnitDigits)
        XCTAssertTrue(capabilities.eReceipt)
        XCTAssertFalse(capabilities.physicalReceipt)
    }

    func testWhatTheTerminalPermitsIsWhatATillMaySend() {
        guard case let .available(_, capabilities, _) = EcrTerminal.signOn(
            from: json(available),
            merchantReference: ""
        ) else {
            return XCTFail("expected available")
        }

        XCTAssertTrue(capabilities.permits(.sale))
        XCTAssertFalse(capabilities.permits(.refund))
        XCTAssertEqual("0.010", capabilities.limitsFor(.sale)?.minAmount)
        XCTAssertEqual("5.000", capabilities.limitsFor(.sale)?.maxAmount)
        XCTAssertEqual("", capabilities.limitsFor(.void)?.maxAmount)
    }

    func testAnOperationThisVersionCannotSendIsDropped() {
        let newer = json("""
        {
          "success": true, "responseCode": "00", "message": "Sign-on accepted",
          "data": {
            "available": true,
            "permittedTransactions": [
              { "messageType": "SALE" },
              { "messageType": "PRE_AUTHORIZATION" }
            ]
          }
        }
        """)

        guard case let .available(_, capabilities, _) = EcrTerminal.signOn(
            from: newer,
            merchantReference: ""
        ) else {
            return XCTFail("expected available")
        }

        XCTAssertEqual(1, capabilities.permitted.count)
        XCTAssertTrue(capabilities.permits(.sale))
    }

    func testATerminalThatCannotServeSaysWhy() {
        let busy = json("""
        {
          "success": true,
          "responseCode": "00",
          "message": "The terminal is not on its idle screen",
          "data": {
            "available": false,
            "reason": "The terminal is not on its idle screen",
            "ecrMode": 1
          }
        }
        """)

        guard case let .unavailable(_, reason, capabilities, _) = EcrTerminal.signOn(
            from: busy,
            merchantReference: ""
        ) else {
            return XCTFail("expected unavailable")
        }

        XCTAssertEqual("The terminal is not on its idle screen", reason)
        XCTAssertEqual(.usbCable, capabilities.transport)
    }

    func testAnUnknownEcrModeIsNotReadAsAKnownTransport() {
        let future = json("""
        { "success": true, "responseCode": "00", "message": "Sign-on accepted",
          "data": { "available": true, "ecrMode": 9 } }
        """)

        guard case let .available(_, capabilities, _) = EcrTerminal.signOn(
            from: future,
            merchantReference: ""
        ) else {
            return XCTFail("expected available")
        }

        XCTAssertEqual(.unknown, capabilities.transport)
    }

    func testARefusalOnTheProfileCarriesWhatTheTerminalWillAcceptNow() {
        let refused = json("""
        {
          "success": false,
          "responseCode": "12",
          "message": "REFUND is not enabled on this terminal",
          "data": {
            "profileChanged": true,
            "available": true,
            "ecrMode": 2,
            "permittedTransactions": [
              { "messageType": "SALE", "maxAmount": "3.000" },
              { "messageType": "VOID" }
            ]
          }
        }
        """)

        guard case let .declined(declined) = EcrTerminal.result(
            from: refused,
            merchantReference: "REQ01",
            minorUnitDigits: 3
        ) else {
            return XCTFail("expected declined")
        }

        XCTAssertEqual("REFUND is not enabled on this terminal", declined.reason)
        XCTAssertEqual(true, declined.capabilities?.permits(.sale))
        XCTAssertEqual(false, declined.capabilities?.permits(.refund))
        XCTAssertEqual("3.000", declined.capabilities?.limitsFor(.sale)?.maxAmount)
    }

    func testAnOrdinaryDeclineCarriesNoProfile() {
        let declined = json("""
        {
          "success": false,
          "responseCode": "51",
          "message": "Insufficient funds",
          "data": { "systemTraceNr": "000215" }
        }
        """)

        guard case let .declined(value) = EcrTerminal.result(
            from: declined,
            merchantReference: "REQ01",
            minorUnitDigits: 3
        ) else {
            return XCTFail("expected declined")
        }

        XCTAssertNil(value.capabilities)
    }

    func testASignOnAnswerWithNoDataIsUnavailable() {
        let empty = json("""
        { "success": true, "responseCode": "00", "message": "" }
        """)

        guard case let .unavailable(_, _, capabilities, _) = EcrTerminal.signOn(
            from: empty,
            merchantReference: "REQ01"
        ) else {
            return XCTFail("expected unavailable")
        }

        XCTAssertFalse(capabilities.available)
        XCTAssertTrue(capabilities.permitted.isEmpty)
    }

    func testClosingTheReceiptReadsIdle() {
        let idle = json("""
        { "success": true, "responseCode": "00", "message": "Idle" }
        """)

        guard case let .idle(reference, _) = EcrTerminal.receiptClosed(
            from: idle,
            merchantReference: "REQ01"
        ) else {
            return XCTFail("expected idle")
        }

        XCTAssertEqual("REQ01", reference)
    }

    func testATerminalThatCannotCloseItsReceiptIsRefused() {
        let refused = json("""
        { "success": false, "responseCode": "12", "message": "Unknown message" }
        """)

        guard case let .refused(_, code, reason, _) = EcrTerminal.receiptClosed(
            from: refused,
            merchantReference: ""
        ) else {
            return XCTFail("expected refused")
        }

        XCTAssertEqual("12", code)
        XCTAssertEqual("Unknown message", reason)
    }
}
