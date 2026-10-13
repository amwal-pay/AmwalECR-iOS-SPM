import XCTest
@testable import AmwalECR

final class EcrWebServiceRoutesTests: XCTestCase {

    func testEachEnvironmentResolvesADistinctHubHost() {
        let sit = EcrEnvironmentUrls.hubSocketUrl(environment: .sit)
        let uat = EcrEnvironmentUrls.hubSocketUrl(environment: .uat)
        let prod = EcrEnvironmentUrls.hubSocketUrl(environment: .prod)

        XCTAssertEqual("https://test.amwalpg.com:25452", sit)
        XCTAssertEqual("https://test.amwalpg.com:25453", uat)
        XCTAssertEqual("https://pos.amwalpg.com", prod)
        XCTAssertEqual(3, Set([sit, uat, prod]).count)
    }

    func testUatUrlsUsePort25453AndTheInquiryPath() {
        let routes = EcrWebServiceRoutes(config: EcrTestConfigs.webService)
        XCTAssertEqual(
            "https://test.amwalpg.com:25453/Ecr/Inquiry",
            routes.fullUrl(.transactionStatus)
        )
        XCTAssertEqual("https://test.amwalpg.com:25453/Ecr/Sale", routes.fullUrl(.sale))
    }

    func testOperationPathsAreFixedAcrossEnvironments() {
        XCTAssertEqual("/Ecr/Inquiry", EcrWebServiceEndpoints.transactionStatus)
        XCTAssertEqual("/Ecr/Refund", EcrWebServiceOperation.refund.path)
        XCTAssertEqual("/Ecr/Void", EcrWebServiceOperation.void.path)
    }
}

final class WebServiceTransportOutcomeTests: XCTestCase {

    func testErrorBodyMarksAnUnknownOutcomeByDefault() {
        let body = HttpEcrWebServiceApi.errorBody(responseCode: "NO_RESPONSE", message: "offline")
        XCTAssertEqual(false, body["success"] as? Bool)
        XCTAssertEqual("NO_RESPONSE", body["responseCode"] as? String)
        XCTAssertEqual("INQUIRE_BY_MERCHANT_REFERENCE", body["nextStep"] as? String)
    }

    func testErrorBodyOmitsNextStepWhenTheOutcomeIsKnown() {
        let body = HttpEcrWebServiceApi.errorBody(
            responseCode: "400",
            message: "Bad Request",
            outcomeUnknown: false
        )
        XCTAssertNil(body["nextStep"])
    }

    func testAnUnknownOutcomeWithoutDataIsAFailedInquiryNotNotFound() {
        let body = HttpEcrWebServiceApi.errorBody(responseCode: "503", message: "Unavailable")
        let inquiry = EcrWebServiceTerminal.inquiryTransportFailure(body, reference: "R1")

        guard case let .failed(reference, failure) = inquiry,
              case let .connectionLost(message) = failure
        else { return XCTFail("expected failed(connectionLost), got \(String(describing: inquiry))") }
        XCTAssertEqual("R1", reference)
        XCTAssertEqual("Unavailable", message)
    }

    func testAnUnknownOutcomeThatCarriesDataIsReadNormally() {
        var body = HttpEcrWebServiceApi.errorBody(responseCode: "500", message: "x")
        body["data"] = ["stan": "000001"]
        XCTAssertNil(EcrWebServiceTerminal.inquiryTransportFailure(body, reference: "R1"))
    }

    func testAKnownOutcomeIsNeverRewrittenAsATransportFailure() {
        let body = HttpEcrWebServiceApi.errorBody(
            responseCode: "404",
            message: "No transactions",
            outcomeUnknown: false
        )
        XCTAssertNil(EcrWebServiceTerminal.inquiryTransportFailure(body, reference: "R1"))
    }

    func testInquireByReferenceRequiresTheOriginalReference() {
        let terminal = EcrWebServiceTerminal(
            terminalSerial: "S",
            config: EcrTestConfigs.webService
        )
        let inquiry = terminal.inquireByReference(originalReference: "  ", transactionDate: "")
        guard case .failed(_, .malformed) = inquiry else {
            return XCTFail("expected malformed failure, got \(inquiry)")
        }
    }
}
