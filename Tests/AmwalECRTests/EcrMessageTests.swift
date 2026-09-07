import XCTest
@testable import AmwalECR

/// The request as it goes on the wire.
final class EcrMessageTests: XCTestCase {

    private let config = EcrConfig()

    private func build(
        _ type: EcrTransactionType,
        amount: Decimal? = nil,
        stan: String = "",
        terminalId: String = "",
        date: String = "",
        originalReference: String = "",
        merchantReference: String = "",
        config: EcrConfig? = nil
    ) throws -> [String: Any] {
        try EcrMessage.build(
            type: type,
            config: config ?? self.config,
            terminalSerial: "P653200085189",
            amount: amount,
            originalStan: stan,
            originalTerminalId: terminalId,
            originalDate: date,
            originalReference: originalReference,
            merchantReference: merchantReference
        ).json
    }

    func testEveryRequestCarriesTheSameEnvelope() throws {
        let json = try build(.sale, amount: Decimal(string: "1.234"))

        XCTAssertEqual(1, json["version"] as? Int)
        XCTAssertEqual("SALE", json["messageType"] as? String)
        XCTAssertEqual("P653200085189", json["terminalSerial"] as? String)
        XCTAssertEqual("512", json["currencyCode"] as? String)
        XCTAssertEqual("ECR01", json["ecrId"] as? String)
        XCTAssertEqual(14, (json["transactionDateTime"] as? String)?.count)
        XCTAssertEqual(12, (json["merchantReference"] as? String)?.count)
    }

    func testAGeneratedReferenceIsTwelveUppercaseHexCharacters() {
        let reference = EcrMessage.newReference()

        XCTAssertEqual(12, reference.count)
        XCTAssertEqual(reference, reference.uppercased())
        XCTAssertTrue(reference.allSatisfy { $0.isHexDigit })
    }

    func testTheCallersReferenceIsSentAsGiven() throws {
        let json = try build(
            .sale,
            amount: Decimal(string: "1.234"),
            merchantReference: "ORDER-4471"
        )

        XCTAssertEqual("ORDER-4471", json["merchantReference"] as? String)
    }

    func testAReferenceIsTrimmedAndAnEmptyOneIsGenerated() throws {
        XCTAssertEqual(
            "ORDER-1",
            try EcrMessage.merchantReference("  ORDER-1  ")
        )
        XCTAssertEqual(12, try EcrMessage.merchantReference("   ").count)
    }

    func testAReferenceTheWireFormatCannotCarryIsRefused() {
        for bad in ["order&1", "order=1", "order 1", String(repeating: "x", count: 33)] {
            XCTAssertThrowsError(try EcrMessage.merchantReference(bad), bad) { error in
                XCTAssertTrue(error is EcrInvalidArgument, "expected EcrInvalidArgument for \(bad)")
            }
        }
    }

    func testOnlyAReadOnlyTypeMayNameATransactionByReference() throws {
        let inquiry = try build(.inquiry, date: "20260809", originalReference: "ORDER-4471")
        XCTAssertEqual("ORDER-4471", inquiry["originalMerchantReference"] as? String)

        let void = try build(.void, stan: "215", originalReference: "ORDER-4471")
        XCTAssertNil(void["originalMerchantReference"])
    }

    func testFieldsThatDoNotApplyAreAbsentRatherThanEmpty() throws {
        let sale = try build(.sale, amount: Decimal(string: "1.234"))

        XCTAssertNil(sale["stan"])
        XCTAssertNil(sale["originalTransactionDate"])
        XCTAssertNil(sale["originalTerminalId"])
        XCTAssertNotNil(sale["amount"])
    }

    func testAVoidCarriesNoAmountAndNoDate() throws {
        let json = try build(.void, stan: "215")

        XCTAssertNil(json["amount"])
        XCTAssertNil(json["originalTransactionDate"])
        XCTAssertEqual("000215", json["stan"] as? String)
    }

    func testARefundCarriesAmountStanAndDate() throws {
        let json = try build(
            .refund,
            amount: Decimal(string: "0.216"),
            stan: "208",
            date: "20260809"
        )

        XCTAssertEqual("000000000216", json["amount"] as? String)
        XCTAssertEqual("000208", json["stan"] as? String)
        XCTAssertEqual("20260809", json["originalTransactionDate"] as? String)
    }

    func testAnotherTerminalIsNamedOnlyWhereItIsMeaningful() throws {
        XCTAssertEqual(
            "31629",
            try build(.void, stan: "215", terminalId: "31629")["originalTerminalId"] as? String
        )
        XCTAssertNil(
            try build(
                .sale,
                amount: Decimal(string: "1.000"),
                terminalId: "31629"
            )["originalTerminalId"]
        )
    }

    func testReceiptNumbersArePaddedToSixDigits() {
        XCTAssertEqual("000024", EcrMessage.paddedStan("24"))
        XCTAssertEqual("000215", EcrMessage.paddedStan("215"))
        XCTAssertEqual("000215", EcrMessage.paddedStan("000215"))
        XCTAssertEqual("1234567", EcrMessage.paddedStan("1234567"))
        XCTAssertEqual("", EcrMessage.paddedStan("0000"))
        XCTAssertEqual("", EcrMessage.paddedStan(""))
        XCTAssertEqual("000215", EcrMessage.paddedStan("no. 215"))
    }

    func testTheTimestampIsGregorianWhateverTheDeviceIsSetTo() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 9
        components.hour = 17
        components.minute = 12
        components.second = 59

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = calendar.date(from: components)!

        XCTAssertEqual("20260809171259", EcrMessage.timestamp(date: date))
    }

    func testTheFramingIsATwoByteBigEndianLengthThenTheBody() throws {
        let message = EcrMessage(merchantReference: "A1B2C3D4E5F6", json: ["a": "b"])
        let packet = try EcrMessageCodec.encode(message)

        let body = packet.dropFirst(2)
        let length = (Int(packet[0]) << 8) | Int(packet[1])

        XCTAssertEqual(body.count, length)
        XCTAssertEqual("{\"a\":\"b\"}", String(data: body, encoding: .utf8))
    }

    func testAMessageTooLargeToFrameIsRefused() {
        let message = EcrMessage(
            merchantReference: "A1",
            json: ["big": String(repeating: "x", count: 70_000)]
        )

        XCTAssertThrowsError(try EcrMessageCodec.encode(message)) { error in
            guard case EcrMessageCodec.CodecError.tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
    }

    func testStringsAreReadWhateverJsonTypeTheyArrivedAs() {
        let json: [String: Any] = [
            "text": "hello",
            "number": 31629,
            "null": NSNull(),
        ]

        XCTAssertEqual("hello", ecrString(json, "text"))
        XCTAssertEqual("31629", ecrString(json, "number"))
        XCTAssertEqual("", ecrString(json, "null"))
        XCTAssertEqual("", ecrString(json, "missing"))
    }

    func testFlagsAreReadStrictly() {
        let json: [String: Any] = [
            "real": true,
            "text": "true",
            "textFalse": "false",
            "number": 1,
            "null": NSNull(),
        ]

        XCTAssertTrue(ecrFlag(json, "real"))
        XCTAssertTrue(ecrFlag(json, "text"))
        XCTAssertFalse(ecrFlag(json, "textFalse"))
        XCTAssertFalse(ecrFlag(json, "number"))
        XCTAssertFalse(ecrFlag(json, "null"))
        XCTAssertFalse(ecrFlag(json, "missing"))
    }
}
