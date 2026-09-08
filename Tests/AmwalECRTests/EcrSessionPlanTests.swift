import XCTest
@testable import AmwalECR

final class EcrSessionPlanTests: XCTestCase {

    private let lanConfig = EcrTestConfigs.lan
    private var lanKey: String { lanConfig.secureHashKey }

    func testLanPlanRequiresHostAndSecureHashKey() {
        let plan = EcrSessions.plan(
            link: .lan(host: "", port: 9100),
            config: EcrConfig()
        )

        XCTAssertFalse(plan.isReady)
        XCTAssertTrue(plan.issues.contains("IP address is required for LAN ECR"))
        XCTAssertTrue(plan.issues.contains("\(SecureHash.keyLabel) is not configured"))
    }

    func testUsbCablePlanRequiresSecureHashKey() {
        let plan = EcrSessions.plan(
            link: .usbCable,
            config: EcrConfig()
        )

        XCTAssertFalse(plan.isReady)
        XCTAssertTrue(plan.issues.contains("\(SecureHash.keyLabel) is not configured"))
        XCTAssertTrue(plan.usesUsbCable)
        XCTAssertEqual("USB cable", plan.connectionSummary)
        XCTAssertEqual(SecureHash.keyLabel, plan.signingKeyLabel)
    }

    func testUsbCablePlanReadyWhenKeyIsValid() {
        let plan = EcrSessions.plan(
            link: .usbCable,
            config: lanConfig
        )

        XCTAssertTrue(plan.isReady)
        XCTAssertTrue(plan.usesUsbCable)
        XCTAssertFalse(plan.usesLan)
        XCTAssertFalse(plan.usesWebService)
        XCTAssertEqual("USB cable", plan.connectionSummary)
        XCTAssertEqual(SecureHash.keyLabel, plan.signingKeyLabel)
    }

    func testUsbCableTerminalFactoryWorksWithFakeChannel() {
        let lanPlan = EcrSessions.plan(
            link: .lan(host: "127.0.0.1", port: 9100),
            config: lanConfig
        )
        XCTAssertFalse(
            lanPlan.usesUsbCable,
            "usbCableTerminal preconditions on usesUsbCable — LAN plans must fail that guard"
        )

        let plan = EcrSessions.plan(
            link: .usbCable,
            config: lanConfig
        )
        let channel = FakeEcrChannel()
        let terminal = EcrSessions.usbCableTerminal(
            terminalSerial: "SN1",
            plan: plan,
            channel: channel
        )

        let reachability = terminal.probeReachability()
        XCTAssertTrue(reachability.reachable)
        XCTAssertEqual("USB cable", reachability.endpoint)
        XCTAssertEqual("USB cable", reachability.host)
        XCTAssertEqual(0, reachability.port)
        XCTAssertEqual(1, channel.probeCount)
    }

    func testWebServicePlanRequiresNumericIds() {
        let plan = EcrSessions.plan(
            link: .webService(merchantId: "abc", terminalId: "123"),
            config: lanConfig
        )

        XCTAssertFalse(plan.isReady)
        XCTAssertTrue(plan.issues.contains("Merchant ID must be numeric"))
    }

    func testOpenDispatchesLanWithoutUsbChannel() {
        let plan = EcrSessions.plan(
            link: .lan(host: "127.0.0.1", port: 9100),
            config: lanConfig
        )
        let session = EcrSessions.open(terminalSerial: "SN1", plan: plan)
        XCTAssertTrue(session.usesLocalTerminal)
        XCTAssertFalse(session.usesWebService)
        XCTAssertTrue(session.supportsReceipt)
    }

    func testOpenDispatchesWebService() {
        let plan = EcrSessions.plan(
            link: .webService(merchantId: "13593", terminalId: "742001"),
            config: EcrTestConfigs.webService
        )
        let session = EcrSessions.open(terminalSerial: "SN1", plan: plan)
        XCTAssertTrue(session.usesWebService)
        XCTAssertFalse(session.usesLocalTerminal)
        XCTAssertFalse(session.supportsReceipt)
        XCTAssertNil(session.probeReachability())
    }

    func testOpenUsbWithChannelFactory() {
        let plan = EcrSessions.plan(link: .usbCable, config: lanConfig)
        XCTAssertTrue(plan.isReady)
        let channel = FakeEcrChannel()
        let session = EcrSessions.open(
            terminalSerial: "SN1",
            plan: plan,
            usbChannel: { channel }
        )
        XCTAssertTrue(session.usesLocalTerminal)
        XCTAssertTrue(session.supportsReceipt)
        XCTAssertEqual("USB cable", session.probeReachability()?.endpoint)
    }

    func testMenuOptionsMatchAndroid() {
        XCTAssertEqual(
            [EcrTransactionType.sale, .void, .refund, .inquiry],
            EcrTransactionType.menuOptions
        )
    }

    func testEnvironmentFromNameDefaultsToSit() {
        XCTAssertEqual(EcrEnvironment.sit, EcrEnvironment.fromName(nil))
        XCTAssertEqual(EcrEnvironment.uat, EcrEnvironment.fromName("uat"))
        XCTAssertEqual(EcrEnvironment.prod, EcrEnvironment.fromName("PROD"))
    }
}

private final class FakeEcrChannel: EcrChannel {
    var probeCount = 0

    var endpoint: String { "USB cable" }

    func probe(timeout: TimeInterval) -> String? {
        probeCount += 1
        return nil
    }

    func exchange(body: Data, timeout: TimeInterval) throws -> Data {
        body
    }
}
