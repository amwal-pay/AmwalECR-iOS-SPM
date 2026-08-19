import XCTest
@testable import AmwalECR

/// Amounts on iOS, which must agree with Kotlin's to the last minor unit.
///
/// The Kotlin SDK's `AmountReportingTest` and the Dart `ecr_amount_test.dart`
/// assert the same figures. Where a rounding boundary is involved the three are
/// written out identically on purpose — a platform that rounds 1.2345 the other
/// way charges a different amount, and nothing else in the system would notice.
final class EcrDecimalTests: XCTestCase {

    func testMinorUnitsArePaddedToTwelveDigits() {
        XCTAssertEqual("000000001234", EcrDecimal.minorUnits(Decimal(string: "1.234"), digits: 3))
        XCTAssertEqual("000000000365", EcrDecimal.minorUnits(Decimal(string: "0.365"), digits: 3))
        XCTAssertEqual("000000961100", EcrDecimal.minorUnits(Decimal(string: "961.100"), digits: 3))
    }

    func testTheCurrencysDecimalPlacesDecideWhereThePointFalls() {
        XCTAssertEqual("000000000123", EcrDecimal.minorUnits(Decimal(string: "1.23"), digits: 2))
        XCTAssertEqual("000000000123", EcrDecimal.minorUnits(Decimal(string: "123"), digits: 0))
    }

    func testAnAmountWrittenShortIsPaddedNotTruncated() {
        XCTAssertEqual("000000001200", EcrDecimal.minorUnits(Decimal(string: "1.2"), digits: 3))
        XCTAssertEqual("000000001000", EcrDecimal.minorUnits(Decimal(string: "1"), digits: 3))
    }

    func testRoundingIsHalfUpJustAsKotlinsIs() {
        // The boundary. RoundingMode.HALF_UP on Kotlin, NSRoundPlain here.
        XCTAssertEqual("000000001235", EcrDecimal.minorUnits(Decimal(string: "1.2345"), digits: 3))
        XCTAssertEqual("000000001234", EcrDecimal.minorUnits(Decimal(string: "1.2344"), digits: 3))
        XCTAssertEqual("000000001235", EcrDecimal.minorUnits(Decimal(string: "1.2346"), digits: 3))
        XCTAssertEqual("000000000001", EcrDecimal.minorUnits(Decimal(string: "0.0005"), digits: 3))
        XCTAssertEqual("000000000000", EcrDecimal.minorUnits(Decimal(string: "0.0004"), digits: 3))
    }

    func testAnAbsentAmountIsTwelveZeros() {
        // The field is present but says nothing, for an operation with no
        // amount — matching EcrMessage.minorUnits on Kotlin.
        XCTAssertEqual("000000000000", EcrDecimal.minorUnits(nil, digits: 3))
    }

    func testAnAmountIsReportedInMajorUnits() {
        XCTAssertEqual("0.365", EcrDecimal.majorUnits("000000000365", digits: 3))
        XCTAssertEqual("1.234", EcrDecimal.majorUnits("000000001234", digits: 3))
        XCTAssertEqual("961.100", EcrDecimal.majorUnits("000000961100", digits: 3))
    }

    func testMajorUnitsRespectTheCurrencysPlaces() {
        XCTAssertEqual("1.23", EcrDecimal.majorUnits("000000000123", digits: 2))
        XCTAssertEqual("123", EcrDecimal.majorUnits("000000000123", digits: 0))
    }

    func testZeroReadsAsZeroNotAsThePaddingItArrivedIn() {
        XCTAssertEqual("0.000", EcrDecimal.majorUnits("000000000000", digits: 3))
    }

    func testAnAbsentAmountStaysAbsent() {
        XCTAssertEqual("", EcrDecimal.majorUnits("", digits: 3))
    }

    func testAnAmountThatIsNotMinorUnitsIsPassedThroughUntouched() {
        // A terminal that sends "1.234" is already reporting major units;
        // converting again would report 0.001234 and be silently wrong.
        XCTAssertEqual("1.234", EcrDecimal.majorUnits("1.234", digits: 3))
        XCTAssertEqual("not-a-number", EcrDecimal.majorUnits("not-a-number", digits: 3))
    }

    func testParsingRefusesWhatATerminalWouldRefuse() {
        for bad in ["", "   ", "1.2e3", "1,234", "abc", "1.", ".5", "1.2.3"] {
            XCTAssertNil(EcrDecimal.parse(bad), "\"\(bad)\" should not parse")
        }
    }

    func testParsingAcceptsAPlainDecimal() {
        XCTAssertEqual(Decimal(string: "1.234"), EcrDecimal.parse("1.234"))
        XCTAssertEqual(Decimal(string: "0"), EcrDecimal.parse("0"))
        XCTAssertEqual(Decimal(string: "1.234"), EcrDecimal.parse("  1.234  "))
    }

    func testParsingIsLocaleIndependent() {
        // An Arabic-locale device must send the same digits as an English one.
        // `Decimal(string:)` without a locale would read "1,234" as 1234 in a
        // comma-decimal locale; parse() refuses it everywhere.
        XCTAssertNil(EcrDecimal.parse("1,234"))
        XCTAssertEqual(Decimal(string: "1.234"), EcrDecimal.parse("1.234"))
    }
}
