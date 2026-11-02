import XCTest
@testable import AmwalECR

/// A settlement answers in four shapes — closed with totals, nothing to close,
/// left open, refused before it started — and a till decides what to tell the
/// cashier from which one it got.
final class SettlementReadingTests: XCTestCase {

    private func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    func testAClosedBatchReadsItsTotalsInMajorUnits() {
        let settlement = EcrTerminal.settlement(
            from: json("""
            {
              "success": true,
              "responseCode": "00",
              "message": "Settlement successful",
              "data": {
                "merchantReference": "SET01",
                "settlementStatus": "SETTLED",
                "batchId": "00000007",
                "currency": "OMR",
                "startTime": "20261020080000",
                "endTime": "20261020130509",
                "totalTransactions": 4,
                "netAmount": "000000012500",
                "totals": {
                  "SALE": { "count": 3, "amount": "000000014750" },
                  "REFUND": { "count": 1, "amount": "000000002250" },
                  "VOID": { "count": 0, "amount": "000000000000" },
                  "PRE_AUTH": { "count": 0, "amount": "000000000000" },
                  "CAPTURE": { "count": 0, "amount": "000000000000" }
                }
              }
            }
            """),
            merchantReference: "SET01",
            minorUnitDigits: 3
        )

        guard case let .settled(
            reference, batchId, currency, _, endTime, total, net, totals, _
        ) = settlement else {
            return XCTFail("expected settled, got \(settlement)")
        }
        XCTAssertEqual("SET01", reference)
        XCTAssertEqual("00000007", batchId)
        XCTAssertEqual("OMR", currency)
        XCTAssertEqual("20261020130509", endTime)
        XCTAssertEqual(4, total)
        XCTAssertEqual("12.500", net)
        XCTAssertEqual(EcrSettlementTotal(count: 3, amount: "14.750"), totals["SALE"])
        XCTAssertEqual(EcrSettlementTotal(count: 1, amount: "2.250"), totals["REFUND"])
        XCTAssertEqual(EcrSettlementTotal(count: 0, amount: "0.000"), totals["VOID"])
    }

    func testAMissingRowReadsAsZeroSoEveryTypeIsPresent() {
        let settlement = EcrTerminal.settlement(
            from: json("""
            {
              "success": true,
              "responseCode": "00",
              "message": "Settlement successful",
              "data": {
                "settlementStatus": "SETTLED",
                "batchId": "00000008",
                "totalTransactions": 1,
                "netAmount": "000000001000",
                "totals": { "SALE": { "count": 1, "amount": "000000001000" } }
              }
            }
            """),
            merchantReference: "SET02",
            minorUnitDigits: 3
        )

        guard case let .settled(_, _, _, _, _, _, _, totals, _) = settlement else {
            return XCTFail("expected settled, got \(settlement)")
        }
        XCTAssertEqual(
            Set(["SALE", "REFUND", "VOID", "PRE_AUTH", "CAPTURE"]),
            Set(totals.keys)
        )
        XCTAssertEqual(EcrSettlementTotal(count: 0, amount: "0.000"), totals["CAPTURE"])
    }

    func testAnEmptyBatchIsNothingToSettleNotAFailure() {
        let settlement = EcrTerminal.settlement(
            from: json("""
            {
              "success": true,
              "responseCode": "00",
              "message": "There are no transactions to settle",
              "data": { "settlementStatus": "NO_TRANSACTIONS" }
            }
            """),
            merchantReference: "SET03",
            minorUnitDigits: 3
        )

        guard case let .nothingToSettle(_, message, _) = settlement else {
            return XCTFail("expected nothingToSettle, got \(settlement)")
        }
        XCTAssertEqual("There are no transactions to settle", message)
    }

    func testAMismatchLeavesTheBatchOpenAndSaysHowManyWentUp() {
        let settlement = EcrTerminal.settlement(
            from: json("""
            {
              "success": false,
              "responseCode": "91",
              "message": "Counts differ",
              "data": { "settlementStatus": "MISMATCH", "uploadedTransactions": 9 }
            }
            """),
            merchantReference: "SET04",
            minorUnitDigits: 3
        )

        guard case let .notSettled(_, responseCode, status, _, uploaded, _) = settlement else {
            return XCTFail("expected notSettled, got \(settlement)")
        }
        XCTAssertEqual("MISMATCH", status)
        XCTAssertEqual("91", responseCode)
        XCTAssertEqual(9, uploaded)
    }

    func testABusyTerminalRefusesWithNoSettlementStatus() {
        let settlement = EcrTerminal.settlement(
            from: json("""
            {
              "success": false,
              "responseCode": "96",
              "message": "A transaction is already in progress on this terminal"
            }
            """),
            merchantReference: "SET05",
            minorUnitDigits: 3
        )

        guard case let .notSettled(_, responseCode, status, _, uploaded, _) = settlement else {
            return XCTFail("expected notSettled, got \(settlement)")
        }
        XCTAssertEqual("96", responseCode)
        XCTAssertEqual("", status)
        XCTAssertNil(uploaded)
    }
}
