import XCTest
@testable import AmwalECR

/// Reading the terminal's answer on iOS.
final class EcrResponseReaderTests: XCTestCase {

    private func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    // MARK: - Envelope

    func testUnifiedEnvelopeParsesSuccessDataAndErrorList() {
        let wire = EcrWireResponse.parse(json("""
        {
          "success": true,
          "responseCode": "00",
          "message": "Approved",
          "data": {
            "amount": "1.234",
            "merchantReference": "ORDER-1"
          },
          "errorList": ["first", "second"]
        }
        """))

        XCTAssertTrue(wire.success)
        XCTAssertEqual("00", wire.responseCode)
        XCTAssertEqual("Approved", wire.message)
        XCTAssertEqual("ORDER-1", wire.merchantReference)
        XCTAssertEqual(["first", "second"], wire.errorList)
        XCTAssertEqual("first\nsecond", wire.displayMessage)
    }

    func testLegacyMerchantReferenceIdInDataIsAccepted() {
        let wire = EcrWireResponse.parse(json("""
        {
          "success": true,
          "data": {"merchantReferenceId": "LEGACY-1"}
        }
        """))

        XCTAssertEqual("LEGACY-1", wire.merchantReference)
    }

    func testDisplayMessageFromRawUsesErrorListFirst() {
        let message = EcrWireResponse.displayMessageFromRaw(
            """
            {"success": false, "message": "Generic", "errorList": ["Specific"]}
            """,
            fallback: "fallback"
        )
        XCTAssertEqual("Specific", message)
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
            merchantReference: "A1B2C3D4E5F6",
            minorUnitDigits: 3
        )

        guard case let .approved(approved) = result else {
            return XCTFail("expected approved, got \(result)")
        }
        XCTAssertEqual("0.216", approved.amount)
        XCTAssertEqual("622113155340", approved.rrn)
        XCTAssertEqual("517842", approved.authCode)
        XCTAssertEqual("543173xxxx5785", approved.maskedPan)
        XCTAssertFalse(approved.partialApproval)
    }

    func testEnvelopeApprovalUsesAuthorizeAmountWhenPresent() {
        let result = EcrTerminal.result(
            from: json("""
            {
              "success": true,
              "responseCode": "00",
              "data": {
                "authorizeAmount": "0.500",
                "amount": "2.000",
                "isPartialApprove": true
              }
            }
            """),
            merchantReference: "A1",
            minorUnitDigits: 3
        )

        guard case let .approved(approved) = result else {
            return XCTFail("expected approved, got \(result)")
        }
        XCTAssertEqual("0.500", approved.amount)
        XCTAssertTrue(approved.partialApproval)
    }

    func testApprovedIsAuthoritativeAndResponseCodeIsNot() {
        let result = EcrTerminal.result(
            from: json("""
            {"responseCode": "00", "approved": false, "responseMessage": "Voided"}
            """),
            merchantReference: "A1",
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
            merchantReference: "A1",
            minorUnitDigits: 3
        )
        let declined = EcrTerminal.result(
            from: json("{\"responseCode\": \"51\"}"),
            merchantReference: "A1",
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
            merchantReference: "A1",
            minorUnitDigits: 3
        )

        guard case let .approved(approved) = result else {
            return XCTFail("expected approved, got \(result)")
        }
        XCTAssertTrue(approved.partialApproval)
        XCTAssertEqual("0.500", approved.amount)
        XCTAssertEqual("2.000", approved.requestedAmount)
    }

    func testADeclinePrefersTheBackendsOwnWords() {
        let result = EcrTerminal.result(
            from: json("""
            {
              "success": false,
              "responseCode": "909",
              "message": "Insufficient funds",
              "errorList": ["Card declined"]
            }
            """),
            merchantReference: "A1",
            minorUnitDigits: 3
        )

        guard case let .declined(declined) = result else {
            return XCTFail("expected declined")
        }
        XCTAssertEqual("909", declined.responseCode)
        XCTAssertEqual("Card declined", declined.reason)
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
            merchantReference: "D4E5F6A1B2C3",
            minorUnitDigits: 3
        )

        guard case let .found(_, transaction, _) = inquiry else {
            return XCTFail("expected found, got \(inquiry)")
        }
        XCTAssertEqual("000208", transaction.stan)
        XCTAssertEqual("Purchase", transaction.type)
        XCTAssertEqual("Approved", transaction.status)
        XCTAssertEqual("0.258", transaction.amount)
        XCTAssertEqual("OMR", transaction.currency)
        XCTAssertEqual("543173******5785", transaction.maskedPan)
        XCTAssertEqual("31629", transaction.terminalId)
        XCTAssertFalse(transaction.isRefunded)
        XCTAssertTrue(transaction.canVoid)
        XCTAssertTrue(transaction.canRefund)
        XCTAssertEqual("", transaction.cardHolderName)
        XCTAssertEqual("", transaction.authCode)
    }

    func testInquiryPartialApprovalFieldsAreReadFromData() {
        let payload = found.replacingOccurrences(
            of: "\"status\": \"Approved\"",
            with: "\"status\": \"Approved\", \"isPartialApprove\": true, \"authorizeAmount\": \"0.100\""
        )

        let inquiry = EcrTerminal.inquiry(
            from: json(payload),
            merchantReference: "A1",
            minorUnitDigits: 3
        )

        guard case let .found(_, transaction, _) = inquiry else {
            return XCTFail("expected found")
        }
        XCTAssertTrue(transaction.partialApproval)
        XCTAssertEqual("0.258", transaction.amount)
        XCTAssertEqual("0.100", transaction.authorizedAmount)
    }

    func testApprovedTrueOnAnInquiryMeansFoundNotPaid() {
        let payload = found.replacingOccurrences(
            of: "\"status\": \"Approved\"",
            with: "\"status\": \"Declined\""
        )

        let inquiry = EcrTerminal.inquiry(
            from: json(payload),
            merchantReference: "A1",
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
            merchantReference: "A1",
            minorUnitDigits: 3
        )

        guard case let .notFound(_, reason, _) = inquiry else {
            return XCTFail("expected notFound, got \(inquiry)")
        }
        XCTAssertEqual("odd", reason)
    }

    func testDeclinedTransactionInDataIsStillFound() {
        let payload = """
        {
          "success": false,
          "message": "Declined",
          "data": {
            "status": "Declined",
            "stan": "000208",
            "amount": "0.258"
          }
        }
        """

        let inquiry = EcrTerminal.inquiry(
            from: json(payload),
            merchantReference: "A1",
            minorUnitDigits: 3
        )

        guard case let .found(_, transaction, _) = inquiry else {
            return XCTFail("expected found for declined transaction record")
        }
        XCTAssertEqual("Declined", transaction.status)
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
            merchantReference: "A1",
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
            merchantReference: "A1",
            minorUnitDigits: 3
        )

        guard case let .found(_, transaction, _) = inquiry else {
            return XCTFail("expected found")
        }
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
            merchantReference: "A1"
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
            let receipt = EcrTerminal.receipt(from: json(payload), merchantReference: "A1")

            guard case let .unavailable(_, reason, _) = receipt else {
                return XCTFail("expected unavailable for \(payload)")
            }
            XCTAssertEqual("Receipt ready", reason)
        }
    }
}
