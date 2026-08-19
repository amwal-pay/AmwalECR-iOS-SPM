import XCTest
@testable import AmwalECR

/// The request as it goes on the wire.
///
/// The framing and the field rules are a contract with the terminal, which has
/// its own copy of both. These assert the iOS side against
/// `ecr-sdk/docs/protocol.md` §3.
final class EcrMessageTests: XCTestCase {

    private let config = EcrConfig()

    private func build(
        _ type: EcrTransactionType,
        amount: Decimal? = nil,
        stan: String = "",
        terminalId: String = "",
        date: String = "",
        originalReference: String = "",
        merchantReferenceId: String = "",
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
            merchantReferenceId: merchantReferenceId
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
        XCTAssertEqual(12, (json["merchantReferenceId"] as? String)?.count)
    }

    func testAGeneratedReferenceIsTwelveUppercaseHexCharacters() {
        let reference = EcrMessage.newReference()

        XCTAssertEqual(12, reference.count)
        XCTAssertEqual(reference, reference.uppercased())
        XCTAssertTrue(reference.allSatisfy { $0.isHexDigit })
    }

    // ── The till's own reference ──────────────────────────────────────────

    func testTheCallersReferenceIsSentAsGiven() throws {
        // A till that already numbers its orders passes that number, so the same
        // string names the transaction in its books and in the terminal's.
        let json = try build(
            .sale,
            amount: Decimal(string: "1.234"),
            merchantReferenceId: "ORDER-4471"
        )

        XCTAssertEqual("ORDER-4471", json["merchantReferenceId"] as? String)
    }

    func testAReferenceIsTrimmedAndAnEmptyOneIsGenerated() throws {
        XCTAssertEqual(
            "ORDER-1",
            try EcrMessage.merchantReference("  ORDER-1  ")
        )
        XCTAssertEqual(12, try EcrMessage.merchantReference("   ").count)
    }

    func testAReferenceTheWireFormatCannotCarryIsRefused() {
        // '&' and '=' are the separators the signature is built from: a
        // reference carrying one could make two different messages hash alike.
        for bad in ["order&1", "order=1", "order 1", String(repeating: "x", count: 33)] {
            XCTAssertThrowsError(try EcrMessage.merchantReference(bad), bad) { error in
                XCTAssertTrue(error is EcrInvalidArgument, "expected EcrInvalidArgument for \(bad)")
            }
        }
    }

    func testOnlyAReadOnlyTypeMayNameATransactionByReference() throws {
        // Acting on a transaction goes by the number on the printed receipt,
        // which is what the operator at the terminal is reading.
        let inquiry = try build(.inquiry, date: "20260809", originalReference: "ORDER-4471")
        XCTAssertEqual("ORDER-4471", inquiry["originalMerchantReference"] as? String)

        let void = try build(.void, stan: "215", originalReference: "ORDER-4471")
        XCTAssertNil(void["originalMerchantReference"])
    }

    func testFieldsThatDoNotApplyAreAbsentRatherThanEmpty() throws {
        let sale = try build(.sale, amount: Decimal(string: "1.234"))

        // The terminal reads a field's presence as meaning the operation uses
        // it, so an empty `stan` on a sale is not the same message as no `stan`.
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
        // A sale has no original, so there is no other terminal to name.
        XCTAssertNil(
            try build(
                .sale,
                amount: Decimal(string: "1.000"),
                terminalId: "31629"
            )["originalTerminalId"]
        )
    }

    func testReceiptNumbersArePaddedToSixDigits() {
        // The terminal stores them padded; an operator types "24".
        XCTAssertEqual("000024", EcrMessage.paddedStan("24"))
        XCTAssertEqual("000215", EcrMessage.paddedStan("215"))
        XCTAssertEqual("000215", EcrMessage.paddedStan("000215"))
        XCTAssertEqual("1234567", EcrMessage.paddedStan("1234567"))
        XCTAssertEqual("", EcrMessage.paddedStan("0000"))
        XCTAssertEqual("", EcrMessage.paddedStan(""))
        // Non-digits are dropped, so "no. 215" is still 000215.
        XCTAssertEqual("000215", EcrMessage.paddedStan("no. 215"))
    }

    func testTheTimestampIsGregorianWhateverTheDeviceIsSetTo() {
        // A device on a non-Gregorian calendar must still send a Gregorian
        // timestamp, or the terminal files the transaction under a year that
        // does not exist.
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
        let message = EcrMessage(merchantReferenceId: "A1B2C3D4E5F6", json: ["a": "b"])
        let packet = try EcrMessageCodec.encode(message)

        let body = packet.dropFirst(2)
        let length = (Int(packet[0]) << 8) | Int(packet[1])

        XCTAssertEqual(body.count, length)
        XCTAssertEqual("{\"a\":\"b\"}", String(data: body, encoding: .utf8))
    }

    func testAMessageTooLargeToFrameIsRefused() {
        let message = EcrMessage(
            merchantReferenceId: "A1",
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
        // An identifier, not a quantity: 31629, never 31629.0.
        XCTAssertEqual("31629", ecrString(json, "number"))
        // Absent, not the text "null".
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
        // Strictly, matching Kotlin's toBooleanStrictOrNull: a numeric 1 is not
        // true. The backend does not send flags that way, and accepting it here
        // would make the two platforms disagree about a payload neither should
        // ever see.
        XCTAssertFalse(ecrFlag(json, "number"))
        XCTAssertFalse(ecrFlag(json, "null"))
        XCTAssertFalse(ecrFlag(json, "missing"))
    }
}
