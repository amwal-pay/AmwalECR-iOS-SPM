import XCTest
@testable import AmwalECR

/// Hub wire payload per operation — mirrors Android `EcrWebServiceMessage`.
final class WebServiceMessageTests: XCTestCase {

    private func build(
        _ type: EcrTransactionType,
        amount: Int64? = nil,
        stan: String = "",
        date: String = "",
        originalReference: String = "",
        reference: String = "REF1"
    ) throws -> [String: Any] {
        try EcrWebServiceMessage.build(
            type: type,
            merchantId: 13593,
            terminalId: 742001,
            terminalSerial: "P653200085189",
            secureHashKey: "",
            amountMinorUnits: amount,
            stan: stan,
            originalTransactionDate: date,
            originalMerchantReference: originalReference,
            merchantReference: reference,
            transactionDateTime: "20260101120000"
        ).1
    }

    private func str(_ json: [String: Any], _ key: String) -> String? {
        json[key] as? String
    }

    private func assertCommon(_ json: [String: Any], _ type: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(type, str(json, "messageType"), file: file, line: line)
        XCTAssertEqual("REF1", str(json, "merchantReference"), file: file, line: line)
        XCTAssertEqual("P653200085189", str(json, "terminalSerial"), file: file, line: line)
        XCTAssertEqual("20260101120000", str(json, "transactionDateTime"), file: file, line: line)
        XCTAssertEqual("20260101120000", str(json, "requestDateTime"), file: file, line: line)
        XCTAssertEqual(13593, (json["merchantId"] as? NSNumber)?.int64Value, file: file, line: line)
        XCTAssertEqual(742001, (json["terminalId"] as? NSNumber)?.int64Value, file: file, line: line)
        XCTAssertNotNil(json["version"], file: file, line: line)
        XCTAssertNotNil(json["ecrId"], file: file, line: line)
        XCTAssertNotNil(json["currencyCode"], file: file, line: line)
    }

    func testSaleCarriesOnlyTheAmount() throws {
        let json = try build(.sale, amount: 1500)
        assertCommon(json, EcrTransactionType.sale.messageType)
        XCTAssertEqual("000000001500", str(json, "amount"))
        XCTAssertNil(json["stan"])
        XCTAssertNil(json["originalMerchantReference"])
        XCTAssertNil(json["originalTerminalId"])
    }

    func testVoidOriginalsPointAtTheSameReferenceAndTerminal() throws {
        let json = try build(.void, stan: "208")
        assertCommon(json, EcrTransactionType.void.messageType)
        XCTAssertEqual(EcrMessage.paddedStan("208"), str(json, "stan"))
        XCTAssertEqual("REF1", str(json, "originalMerchantReference"))
        XCTAssertEqual(742001, (json["originalTerminalId"] as? NSNumber)?.int64Value)
        XCTAssertNil(json["amount"])
    }

    func testRefundCarriesAmountStanDateAndOriginals() throws {
        let json = try build(.refund, amount: 250, stan: "208", date: "20260101")
        assertCommon(json, EcrTransactionType.refund.messageType)
        XCTAssertEqual("000000000250", str(json, "amount"))
        XCTAssertEqual(EcrMessage.paddedStan("208"), str(json, "stan"))
        XCTAssertEqual("20260101", str(json, "originalTransactionDate"))
        XCTAssertEqual("REF1", str(json, "originalMerchantReference"))
        XCTAssertEqual(742001, (json["originalTerminalId"] as? NSNumber)?.int64Value)
    }

    func testInquiryByStanLeavesTheOriginalReferenceEmpty() throws {
        let json = try build(.inquiry, stan: "208", date: "20260101", originalReference: "IGNORED")
        assertCommon(json, EcrTransactionType.inquiry.messageType)
        XCTAssertEqual(EcrMessage.paddedStan("208"), str(json, "stan"))
        XCTAssertEqual("20260101", str(json, "originalTransactionDate"))
        XCTAssertEqual("", str(json, "originalMerchantReference"))
        XCTAssertEqual(742001, (json["originalTerminalId"] as? NSNumber)?.int64Value)
        XCTAssertNil(json["amount"])
    }

    func testInquiryByReferenceSendsEmptyStanAndTheOriginalReference() throws {
        let json = try build(.inquiry, date: "20260101", originalReference: "ORIG123")
        assertCommon(json, EcrTransactionType.inquiry.messageType)
        XCTAssertEqual("", str(json, "stan"))
        XCTAssertEqual("ORIG123", str(json, "originalMerchantReference"))
        XCTAssertEqual(742001, (json["originalTerminalId"] as? NSNumber)?.int64Value)
    }

    func testInquiryWithNeitherStanNorReferenceSendsBothEmpty() throws {
        let json = try build(.inquiry)
        XCTAssertEqual("", str(json, "stan"))
        XCTAssertEqual("", str(json, "originalMerchantReference"))
    }

    func testRequestDateTimeAlwaysEqualsTransactionDateTime() throws {
        let json = try EcrWebServiceMessage.build(
            type: .sale,
            merchantId: 1,
            terminalId: 2,
            terminalSerial: "S",
            secureHashKey: "",
            amountMinorUnits: 1
        ).1
        XCTAssertFalse((json["transactionDateTime"] as? String ?? "").isEmpty)
        XCTAssertEqual(json["transactionDateTime"] as? String, json["requestDateTime"] as? String)
    }

    func testSigningAddsTheHashOnlyWhenAKeyIsConfigured() throws {
        let unsigned = try build(.sale, amount: 1)
        XCTAssertNil(unsigned[WebServiceSecureHash.field])

        let signed = try EcrWebServiceMessage.build(
            type: .sale,
            merchantId: 1,
            terminalId: 2,
            terminalSerial: "S",
            secureHashKey: EcrTestConfigs.SECURE_HASH_KEY_WEBSERVICE,
            amountMinorUnits: 1
        ).1
        XCTAssertFalse((signed[WebServiceSecureHash.field] as? String ?? "").isEmpty)
    }
}
