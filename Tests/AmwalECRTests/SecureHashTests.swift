import XCTest
@testable import AmwalECR

private let key = "881dc200c9833da726e9376c2e32cff7"
private let otherKey = "0123456789abcdef0123456789abcdef"

/// Message authentication on the ECR link.
///
/// The canonical form is an agreement with the terminal and with the Kotlin SDK,
/// so these are the same cases as `ecr-sdk/src/test/.../SecureHashTest.kt`, with
/// the same key and the same payloads. A signature that verifies on one platform
/// and not the other is the failure this file exists to catch.
final class SecureHashTests: XCTestCase {

    // MARK: The agreement with the terminal

    func testFieldsAreSignedInSortedOrder() {
        let json: [String: Any] = [
            "messageType": "SALE",
            "amount": "000000001234",
            "version": 1,
        ]

        XCTAssertEqual(
            "amount=000000001234&messageType=SALE&version=1",
            SecureHash.compose(json)
        )
    }

    func testTheSignatureFieldIsNeverPartOfWhatIsSigned() {
        let unsigned: [String: Any] = ["amount": "1"]
        let signed: [String: Any] = ["amount": "1", SecureHash.field: "WHATEVER"]

        XCTAssertEqual(SecureHash.compose(unsigned), SecureHash.compose(signed))
    }

    func testNestedValuesAndNullsAreLeftOut() {
        // ecrResponse passes the backend's own record through, and two JSON
        // libraries cannot be relied on to write it identically.
        let json: [String: Any] = [
            "amount": "1",
            "ecrResponse": ["data": "x"],
            "list": [1, 2],
            "missing": NSNull(),
        ]

        XCTAssertEqual("amount=1", SecureHash.compose(json))
    }

    func testBooleansAndNumbersAreSignedAsTheyAreWritten() {
        let json: [String: Any] = ["approved": true, "version": 1]

        XCTAssertEqual("approved=true&version=1", SecureHash.compose(json))
    }

    func testTheIntegerOneIsNotSignedAsTrue() {
        // NSNumber(1) casts to Bool in Swift, so the order of the type checks in
        // `scalar` is load-bearing: get it wrong and this platform signs "true"
        // where the terminal signed "1".
        XCTAssertEqual("flag=1", SecureHash.compose(["flag": 1]))
        XCTAssertEqual("flag=true", SecureHash.compose(["flag": true]))
    }

    // MARK: Signing and verifying

    func testASignatureVerifiesAgainstTheKeyThatMadeIt() throws {
        let signed = try sign(["amount": "000000001234"], with: key)

        XCTAssertTrue(SecureHash.verify(signed, key: key))
    }

    func testASignatureDoesNotVerifyAgainstAnotherKey() throws {
        let signed = try sign(["amount": "000000001234"], with: key)

        XCTAssertFalse(SecureHash.verify(signed, key: otherKey))
    }

    func testChangingTheAmountInvalidatesTheSignature() throws {
        // The whole point: an attacker on the network cannot rewrite a figure.
        let signature = try SecureHash.sign(
            SecureHash.compose(["amount": "000000001234"]),
            key: key
        )
        let tampered: [String: Any] = [
            "amount": "000000009999",
            SecureHash.field: signature,
        ]

        XCTAssertFalse(SecureHash.verify(tampered, key: key))
    }

    func testAnUnsignedMessageNeverVerifies() {
        XCTAssertFalse(SecureHash.verify(["amount": "1"], key: key))
    }

    func testAKeyThatIsNotHexIsRefusedRatherThanReadAsText() {
        // Reading it as text would have both sides agree on nothing and report
        // every message as tampered with, which is a miserable thing to debug.
        XCTAssertThrowsError(try SecureHash.sign("a=1", key: "not-hex!!"))
    }

    /// The one value in this file that is not derived by the code under test.
    ///
    /// Everything else here checks the two halves against each other, which
    /// would still pass if both drifted together. This is HMAC-SHA256 of
    /// `amount=000000001234` under the shared test key, and it is what the
    /// Kotlin SDK and the terminal produce for the same input.
    func testTheDigestIsHmacSha256AsUppercaseHex() throws {
        let signature = try SecureHash.sign("amount=000000001234", key: key)

        XCTAssertEqual(
            "D833F180DB6385C7188D9E07FC622662B58A7D79A2291DC312B943377DDF11ED",
            signature
        )
    }

    // MARK: Nonces

    func testNoncesDoNotRepeat() {
        let seen = Set((0..<500).map { _ in SecureHash.newNonce() })

        XCTAssertEqual(500, seen.count)
    }

    func testANonceIs128BitsOfHex() {
        let nonce = SecureHash.newNonce()

        XCTAssertEqual(32, nonce.count)
        XCTAssertTrue(nonce.allSatisfy(\.isHexDigit))
    }

    // MARK: What the message builder actually produces

    func testAMessageIsUnsignedWhenNoKeyIsConfigured() throws {
        let json = try build(EcrConfig()).json

        XCTAssertNil(json[SecureHash.field], "nothing to sign with")
        XCTAssertNil(json["nonce"], "a nonce without a signature could just be changed")
    }

    func testAMessageIsSignedAndCarriesANonceWhenAKeyIsConfigured() throws {
        let json = try build(EcrConfig(secureHashKey: key)).json

        XCTAssertNotNil(json[SecureHash.field])
        XCTAssertEqual(32, (json["nonce"] as? String)?.count)
        XCTAssertTrue(SecureHash.verify(json, key: key))
    }

    func testTwoIdenticalSalesAreSignedDifferently() throws {
        // Because each carries its own nonce — otherwise a captured message
        // would be indistinguishable from a fresh one.
        let first = try build(EcrConfig(secureHashKey: key)).json
        let second = try build(EcrConfig(secureHashKey: key)).json

        XCTAssertNotEqual(
            first[SecureHash.field] as? String,
            second[SecureHash.field] as? String
        )
    }

    func testTheNonceSentIsTheOneReportedForCheckingTheAnswer() throws {
        let message = try build(EcrConfig(secureHashKey: key))

        XCTAssertEqual(message.json["nonce"] as? String, message.nonce)
    }

    // MARK: Configuration

    func testAMalformedKeyIsRefusedBeforeAnythingIsSent() {
        for bad in ["nothex", "abc", "aabb"] {
            XCTAssertNotNil(EcrConfig(secureHashKey: bad).secureHashKeyError, bad)
            XCTAssertThrowsError(try build(EcrConfig(secureHashKey: bad)), bad) { error in
                XCTAssertTrue(error is EcrInvalidArgument)
            }
        }
    }

    func testAnEmptyKeyIsAllowedAndMeansUnsigned() {
        XCTAssertFalse(EcrConfig(secureHashKey: "").signsMessages)
        XCTAssertNil(EcrConfig(secureHashKey: "").secureHashKeyError)
        XCTAssertTrue(EcrConfig(secureHashKey: key).signsMessages)
        XCTAssertNil(EcrConfig(secureHashKey: key).secureHashKeyError)
    }

    // MARK: Helpers

    private func sign(_ json: [String: Any], with key: String) throws -> [String: Any] {
        var signed = json
        signed[SecureHash.field] = try SecureHash.sign(SecureHash.compose(json), key: key)
        return signed
    }

    private func build(_ config: EcrConfig) throws -> EcrMessage {
        try EcrMessage.build(
            type: .sale,
            config: config,
            terminalSerial: "TW1",
            amount: Decimal(string: "1.234"),
            originalStan: "",
            originalTerminalId: "",
            originalDate: ""
        )
    }
}
