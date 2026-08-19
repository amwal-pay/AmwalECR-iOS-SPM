import XCTest
@testable import AmwalECR

/// Reading the terminal's answer on iOS.
///
/// The payloads are the ones in `ecr-sdk/docs/protocol.md` and in the Kotlin
/// SDK's `InquiryReadingTest`, field for field, so the two hosts can be
/// compared directly rather than trusted separately.
final class EcrResponseReaderTests: XCTestCase {

    private func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    // MARK: - Sales

    func testAnApprovalReportsMajorUnitsAndTheBanksDetails() {
        let result = EcrTerminal.result(
            from: json("""
            {
              "responseCode": "00",
              "responseMessage": "Approved",
              "approved": true,
              "amount": "000000000216",
              "rrn": "622113155340",
              "authCode": "517842",
              "maskedPan": "543173xxxx5785"
            }
            """),
            merchantReferenceId: "A1B2C3D4E5F6",
            minorUnitDigits: 3
        )

        guard case let .approved(approved) = result else {
            return XCTFail("expected approved, got \(result)")
        }
        // 0.216, never 000000000216.
        XCTAssertEqual("0.216", approved.amount)
        XCTAssertEqual("622113155340", approved.rrn)
        XCTAssertEqual("517842", approved.authCode)
        XCTAssertEqual("543173xxxx5785", approved.maskedPan)
        XCTAssertFalse(approved.partialApproval)
    }

    func testApprovedIsAuthoritativeAndResponseCodeIsNot() {
        // A partial approval the operator then voided comes back carrying the
        // bank's own 00, because the bank did approve before the void undid it.
        // A client deciding from the code alone books that as a sale.
        let result = EcrTerminal.result(
            from: json("""
            {"responseCode": "00", "approved": false, "responseMessage": "Voided"}
            """),
            merchantReferenceId: "A1",
            minorUnitDigits: 3
        )

        guard case let .declined(declined) = result else {
            return XCTFail("expected declined, got \(result)")
        }
        XCTAssertEqual("00", declined.responseCode)
        XCTAssertEqual("Voided", declined.reason)
    }

    func testAnAbsentApprovedFlagFallsBackToTheResponseCode() {
        let approved = EcrTerminal.result(
            from: json("{\"responseCode\": \"00\", \"amount\": \"000000001000\"}"),
            merchantReferenceId: "A1",
            minorUnitDigits: 3
        )
        let declined = EcrTerminal.result(
            from: json("{\"responseCode\": \"51\"}"),
            merchantReferenceId: "A1",
            minorUnitDigits: 3
        )

        guard case .approved = approved else { return XCTFail("expected approved") }
        guard case .declined = declined else { return XCTFail("expected declined") }
    }

    func testAPartialApprovalIsAnApprovalThatNamesWhatWasAskedFor() {
        let result = EcrTerminal.result(
            from: json("""
            {
              "responseCode": "00",
              "approved": true,
              "amount": "000000000500",
              "partialApproval": true,
              "requestedAmount": "000000002000"
            }
            """),
            merchantReferenceId: "A1",
            minorUnitDigits: 3
        )

        guard case let .approved(approved) = result else {
            return XCTFail("expected approved, got \(result)")
        }
        // 2.000 was asked for and 0.500 was taken. The goods go out only once
        // the remaining 1.500 is collected by other means — but this is not a
        // refusal.
        XCTAssertTrue(approved.partialApproval)
        XCTAssertEqual("0.500", approved.amount)
        XCTAssertEqual("2.000", approved.requestedAmount)
    }

    func testADeclinePrefersTheBackendsOwnWords() {
        let result = EcrTerminal.result(
            from: json("""
            {
              "responseCode": "909",
              "responseMessage": "Insufficient funds",
              "approved": false
            }
            """),
            merchantReferenceId: "A1",
            minorUnitDigits: 3
        )

        guard case let .declined(declined) = result else {
            return XCTFail("expected declined")
        }
        XCTAssertEqual("909", declined.responseCode)
        XCTAssertEqual("Insufficient funds", declined.reason)
    }

    // MARK: - Inquiries

    private let found = """
    {
      "responseCode": "00",
      "responseMessage": "Transaction found",
      "approved": true,
      "amount": "000000000258",
      "ecrResponse": {
        "success": true,
        "data": {
          "transactionId": "e970c800-93f1-11f1-9485-e7dd858253ff",
          "stan": "000208",
          "transactionType": "Purchase",
          "transactionTypeDisplayName": "Purchase",
          "status": "Approved",
          "amount": 0.258,
          "totalAmount": 0.258,
          "currency": "OMR",
          "transactionTime": "2026-08-09T16:58:16.804271",
          "cardNumber": "543173******5785",
          "cardHolderName": null,
          "rrn": "7862802964726844904806",
          "authCode": null,
          "batchId": "00000003",
          "terminalId": 31629,
          "isRefunded": false,
          "canVoid": true,
          "canRefund": true
        }
      }
    }
    """

    func testAFoundInquiryCarriesTheBackendsOwnRecord() {
        let inquiry = EcrTerminal.inquiry(
            from: json(found),
            merchantReferenceId: "D4E5F6A1B2C3",
            minorUnitDigits: 3
        )

        guard case let .found(_, transaction, _) = inquiry else {
            return XCTFail("expected found, got \(inquiry)")
        }
        XCTAssertEqual("000208", transaction.stan)
        XCTAssertEqual("Purchase", transaction.type)
        XCTAssertEqual("Approved", transaction.status)
        // Amounts inside `data` are already in major units — the backend's own
        // record. The outer `amount` is the wire's minor-unit encoding.
        XCTAssertEqual("0.258", transaction.amount)
        XCTAssertEqual("OMR", transaction.currency)
        XCTAssertEqual("543173******5785", transaction.maskedPan)
        // An identifier, not a quantity.
        XCTAssertEqual("31629", transaction.terminalId)
        XCTAssertFalse(transaction.isRefunded)
        XCTAssertTrue(transaction.canVoid)
        XCTAssertTrue(transaction.canRefund)
        // JSON nulls read as empty, never as the text "null".
        XCTAssertEqual("", transaction.cardHolderName)
        XCTAssertEqual("", transaction.authCode)
    }

    func testApprovedTrueOnAnInquiryMeansFoundNotPaid() {
        // The inquiry succeeded. What became of the transaction is data.status.
        let payload = found.replacingOccurrences(
            of: "\"status\": \"Approved\"",
            with: "\"status\": \"Declined\""
        )

        let inquiry = EcrTerminal.inquiry(
            from: json(payload),
            merchantReferenceId: "A1",
            minorUnitDigits: 3
        )

        guard case let .found(_, transaction, _) = inquiry else {
            return XCTFail("expected found")
        }
        XCTAssertEqual("Declined", transaction.status)
    }

    func testAnInquiryWithNoDataIsNotFoundEvenIfApproved() {
        let inquiry = EcrTerminal.inquiry(
            from: json("""
            {"approved": true, "responseMessage": "odd", "ecrResponse": {"data": null}}
            """),
            merchantReferenceId: "A1",
            minorUnitDigits: 3
        )

        guard case let .notFound(_, reason, _) = inquiry else {
            return XCTFail("expected notFound, got \(inquiry)")
        }
        XCTAssertEqual("odd", reason)
    }

    func testAnInquiryThatFoundNothingCarriesTheBackendsWords() {
        let inquiry = EcrTerminal.inquiry(
            from: json("""
            {
              "responseCode": "25",
              "responseMessage": "No transactions found for the provided STAN and Terminal",
              "approved": false
            }
            """),
            merchantReferenceId: "A1",
            minorUnitDigits: 3
        )

        guard case let .notFound(_, reason, _) = inquiry else {
            return XCTFail("expected notFound")
        }
        XCTAssertEqual("No transactions found for the provided STAN and Terminal", reason)
    }

    func testAnInquiryFallsBackToTheWireAmountWhenTheRecordHasNone() {
        let payload = found.replacingOccurrences(of: "\"amount\": 0.258,", with: "")

        let inquiry = EcrTerminal.inquiry(
            from: json(payload),
            merchantReferenceId: "A1",
            minorUnitDigits: 3
        )

        guard case let .found(_, transaction, _) = inquiry else {
            return XCTFail("expected found")
        }
        // Converted from the outer minor-unit field, as Kotlin does.
        XCTAssertEqual("0.258", transaction.amount)
    }

    // MARK: - Receipts

    func testAReceiptCarriesTheUrl() {
        let receipt = EcrTerminal.receipt(
            from: json("""
            {
              "responseCode": "00",
              "ecrResponse": {
                "data": {"receiptUrl": "https://test.amwalpg.com/r/1"}
              }
            }
            """),
            merchantReferenceId: "A1"
        )

        guard case let .ready(_, url, _) = receipt else {
            return XCTFail("expected ready, got \(receipt)")
        }
        XCTAssertEqual("https://test.amwalpg.com/r/1", url)
    }

    func testAReceiptWithNoUrlIsNotAReceiptWhateverTheCodeSays() {
        for payload in [
            "{\"responseCode\": \"00\", \"responseMessage\": \"Receipt ready\", \"ecrResponse\": {\"data\": {\"receiptUrl\": \"\"}}}",
            "{\"responseCode\": \"00\", \"responseMessage\": \"Receipt ready\", \"ecrResponse\": {\"data\": {}}}",
            "{\"responseCode\": \"00\", \"responseMessage\": \"Receipt ready\"}",
        ] {
            let receipt = EcrTerminal.receipt(from: json(payload), merchantReferenceId: "A1")

            guard case let .unavailable(_, reason, _) = receipt else {
                return XCTFail("expected unavailable for \(payload)")
            }
            XCTAssertEqual("Receipt ready", reason)
        }
    }
}
