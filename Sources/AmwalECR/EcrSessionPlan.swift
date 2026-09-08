import Foundation

/// Validated SDK configuration for one terminal link.
///
/// Built by `EcrSessions.plan` so the app does not duplicate transport rules,
/// signing-key labels, or `EcrConfig` invariants.
public struct EcrSessionPlan {
    public let link: EcrLink
    public let config: EcrConfig
    public let issues: [String]

    public init(link: EcrLink, config: EcrConfig, issues: [String] = []) {
        self.link = link
        self.config = config
        self.issues = issues
    }

    public var isReady: Bool { issues.isEmpty }

    public var usesLan: Bool {
        if case .lan = link { return true }
        return false
    }

    public var usesWebService: Bool {
        if case .webService = link { return true }
        return false
    }

    public var usesUsbCable: Bool {
        if case .usbCable = link { return true }
        return false
    }

    public var signingKeyLabel: String {
        switch link {
        // The cable is signed exactly as the socket is — same key, same
        // construction. Only how the bytes travel is different.
        case .lan, .usbCable: return SecureHash.keyLabel
        case .webService: return WebServiceSecureHash.keyLabel
        }
    }

    public var signingKeyConfigured: Bool { config.secureHashKey.isEmpty == false }

    /// Operator-facing connection summary — no secrets.
    public var connectionSummary: String {
        switch link {
        case let .lan(host, _):
            return "\(host):\(config.port)"
        case .usbCable:
            return "USB cable"
        case let .webService(merchantId, terminalId):
            var parts = [config.environment.rawValue]
            if !merchantId.isEmpty { parts.append("merchant \(merchantId)") }
            if !terminalId.isEmpty { parts.append("terminal \(terminalId)") }
            return parts.joined(separator: " · ")
        }
    }
}

/// Resolves `EcrLink` + credentials into a validated `EcrSessionPlan` and clients.
public enum EcrSessions {

    /// Validates `link` and `config` without opening a connection.
    ///
    /// Returns issues rather than throwing so the UI can show what is missing.
    public static func plan(
        link: EcrLink,
        config: EcrConfig,
        rawSecureHashKey: String? = nil
    ) -> EcrSessionPlan {
        var issues: [String] = []
        let key = rawSecureHashKey ?? config.secureHashKey
        let safe = makeSafeConfig(requested: config, rawSecureHashKey: key, issues: &issues)

        switch link {
        case .lan:
            validateLan(link, issues: &issues)
        case .usbCable:
            // Nothing to validate: a cable has no address to get wrong. Whether
            // one is plugged in is answered by the probe, not by configuration.
            break
        case .webService:
            validateWebService(link, issues: &issues)
        }

        let resolvedConfig = resolveConfig(link: link, config: safe)

        if resolvedConfig.secureHashKey.isEmpty {
            issues.append("\(signingKeyLabel(link)) is not configured")
        }

        return EcrSessionPlan(
            link: link,
            config: resolvedConfig,
            issues: Array(Set(issues))
        )
    }

    /// Opens the transport that `plan` describes.
    ///
    /// One dispatch for LAN / USB cable / Web Service so callers (and recovery
    /// paths) cannot diverge on which client they build.
    ///
    /// - Parameter usbChannel: required when `plan.usesUsbCable`; ignored otherwise.
    public static func open(
        terminalSerial: String,
        plan: EcrSessionPlan,
        usbChannel: (() -> EcrChannel)? = nil,
        logger: EcrLogger = .none
    ) -> EcrOpenedSession {
        precondition(
            plan.isReady,
            "Cannot open a session with unresolved issues: \(plan.issues.joined(separator: "; "))"
        )
        if plan.usesUsbCable {
            guard let makeChannel = usbChannel else {
                preconditionFailure("USB cable sessions require a channel factory")
            }
            return EcrOpenedSession(
                plan: plan,
                local: usbCableTerminal(
                    terminalSerial: terminalSerial,
                    plan: plan,
                    channel: makeChannel(),
                    logger: logger
                ),
                web: nil
            )
        }
        if plan.usesLan {
            return EcrOpenedSession(
                plan: plan,
                local: lanTerminal(
                    terminalSerial: terminalSerial,
                    plan: plan,
                    logger: logger
                ),
                web: nil
            )
        }
        if plan.usesWebService {
            return EcrOpenedSession(
                plan: plan,
                local: nil,
                web: webServiceTerminal(
                    terminalSerial: terminalSerial,
                    plan: plan,
                    logger: logger
                )
            )
        }
        preconditionFailure("Unsupported ECR link")
    }

    public static func lanTerminal(
        terminalSerial: String,
        plan: EcrSessionPlan,
        logger: EcrLogger = .none
    ) -> EcrTerminal {
        guard plan.usesLan else {
            preconditionFailure("plan is not for LAN ECR")
        }
        guard case let .lan(host, _) = plan.link else {
            preconditionFailure("plan is not for LAN ECR")
        }
        return EcrTerminal(
            host: host,
            serialNumber: terminalSerial,
            config: plan.config,
            logger: logger
        )
    }

    /// A terminal reached down a USB cable.
    ///
    /// The channel comes from the caller because finding a cable is a platform
    /// job — External Accessory / DriverKit on iOS, libusb on a Mac — and this
    /// library is plain Swift on purpose. Everything above the channel is
    /// identical to `lanTerminal`: the same signing, the same messages, the
    /// same answers.
    public static func usbCableTerminal(
        terminalSerial: String,
        plan: EcrSessionPlan,
        channel: EcrChannel,
        logger: EcrLogger = .none
    ) -> EcrTerminal {
        guard plan.usesUsbCable else {
            preconditionFailure("plan is not for USB cable ECR")
        }
        return EcrTerminal(
            channel: channel,
            serialNumber: terminalSerial,
            config: plan.config,
            logger: logger
        )
    }

    public static func webServiceTerminal(
        terminalSerial: String,
        plan: EcrSessionPlan,
        logger: EcrLogger = .none
    ) -> EcrWebServiceTerminal {
        guard plan.usesWebService else {
            preconditionFailure("plan is not for Web Service ECR")
        }
        return EcrWebServiceTerminal(
            terminalSerial: terminalSerial,
            config: plan.config,
            logger: logger
        )
    }

    private static func makeSafeConfig(
        requested: EcrConfig,
        rawSecureHashKey: String,
        issues: inout [String]
    ) -> EcrConfig {
        let key = rawSecureHashKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty && !EcrConfig.isValidSecureHashKey(key) {
            issues.append(
                "Secure hash key must be an even-length hex string of at least 16 characters"
            )
        }

        let port = min(max(requested.port, 1), 65535)
        let sanitizedKey = (!key.isEmpty && EcrConfig.isValidSecureHashKey(key)) ? key : ""

        if requested.minorUnitDigits < 0 || requested.minorUnitDigits > 4 {
            issues.append("minorUnitDigits must be between 0 and 4")
        }

        return EcrConfig(
            ecrId: requested.ecrId,
            currencyCode: requested.currencyCode,
            minorUnitDigits: requested.minorUnitDigits,
            port: port,
            connectTimeout: requested.connectTimeout,
            responseTimeout: requested.responseTimeout,
            probeTimeout: requested.probeTimeout,
            secureHashKey: sanitizedKey,
            merchantId: requested.merchantId,
            terminalId: requested.terminalId,
            environment: requested.environment,
            autoInquireOnFailure: requested.autoInquireOnFailure
        )
    }

    private static func validateLan(_ link: EcrLink, issues: inout [String]) {
        guard case let .lan(host, port) = link else { return }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("IP address is required for LAN ECR")
        }
        if port < 1 || port > 65535 {
            issues.append("Port must be between 1 and 65535 (default \(EcrConfig.defaultPort))")
        }
    }

    private static func validateWebService(_ link: EcrLink, issues: inout [String]) {
        guard case let .webService(merchantId, terminalId) = link else { return }
        if merchantId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Merchant ID is required for Web Service")
        }
        if terminalId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Terminal ID is required for Web Service")
        }
        if !merchantId.isEmpty && Int64(merchantId) == nil {
            issues.append("Merchant ID must be numeric")
        }
        if !terminalId.isEmpty && Int64(terminalId) == nil {
            issues.append("Terminal ID must be numeric")
        }
    }

    private static func signingKeyLabel(_ link: EcrLink) -> String {
        switch link {
        case .lan, .usbCable: return SecureHash.keyLabel
        case .webService: return WebServiceSecureHash.keyLabel
        }
    }

    /// Merge transport addressing from `link` into `config` so callers cannot drift.
    private static func resolveConfig(link: EcrLink, config: EcrConfig) -> EcrConfig {
        switch link {
        case let .lan(_, port):
            var resolved = config
            resolved.port = port
            return resolved
        case .usbCable:
            // Nothing to merge — a cable is not addressed, so the port in the
            // config stays whatever it was and is simply never read.
            return config
        case let .webService(merchantId, terminalId):
            var resolved = config
            resolved.merchantId = merchantId
            resolved.terminalId = terminalId
            return resolved
        }
    }
}
