import Foundation

/// Structured request/response logging for Web Service ECR HTTP calls.
enum WebServiceHttpLog {
    private static let prefix = "[Web Service]"

    static func request(
        logger: EcrLogger,
        operation: EcrWebServiceOperation,
        url: String,
        environment: EcrEnvironment,
        payload: String
    ) {
        logger.debug("\(prefix) → \(operation.label.uppercased()) \(url) (env=\(environment.rawValue))")
        logger.debug("\(prefix) request: \(payload)")
    }

    static func signing(
        logger: EcrLogger,
        keyLabel: String,
        secretKey: String,
        payloadToSign: String,
        secureHashValue: String
    ) {
        logger.debug(
            "\(prefix) calcHash: HMAC-SHA256(sorted key=value payload, Hex.parse(secret)) → uppercase hex"
        )
        logger.debug("\(prefix) signing key (\(keyLabel)): \(EcrDiagnostics.secretFingerprint(secretKey))")
        logger.debug("\(prefix) payload to sign (excl. secureHashValue): \(payloadToSign)")
        logger.debug("\(prefix) secureHashValue: \(secureHashValue)")
    }

    static func response(
        logger: EcrLogger,
        operation: EcrWebServiceOperation,
        httpStatus: Int,
        elapsedMs: Int64,
        body: String
    ) {
        logger.debug("\(prefix) ← \(operation.label) HTTP \(httpStatus) (\(elapsedMs)ms)")
        logger.debug("\(prefix) response: \(body)")
    }

    static func error(
        logger: EcrLogger,
        operation: EcrWebServiceOperation,
        message: String,
        elapsedMs: Int64? = nil
    ) {
        let timing = elapsedMs.map { " (\($0)ms)" } ?? ""
        logger.debug("\(prefix) ✗ \(operation.label)\(timing) — \(message)")
    }

    static func operation(
        logger: EcrLogger,
        messageType: String,
        merchantReference: String,
        terminalSerial: String,
        merchantId: Int64,
        terminalId: Int64
    ) {
        logger.debug(
            "\(prefix) sending \(messageType) ref=\(merchantReference) "
                + "terminal=\(terminalSerial) merchantId=\(merchantId) terminalId=\(terminalId)"
        )
    }
}
