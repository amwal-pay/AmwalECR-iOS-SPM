import Foundation

/// POSTs signed JSON bodies to the Web Service ECR REST endpoints.
final class HttpEcrWebServiceApi {
    private let config: EcrConfig
    private let logger: EcrLogger
    private let routes: EcrWebServiceRoutes

    init(config: EcrConfig, logger: EcrLogger) {
        self.config = config
        self.logger = logger
        self.routes = EcrWebServiceRoutes(config: config)
    }

    func postJson(operation: EcrWebServiceOperation, body: [String: Any]) -> [String: Any] {
        let startedAt = Date()
        logSigning(body)

        guard let payloadData = try? JSONSerialization.data(withJSONObject: body),
              let payload = String(data: payloadData, encoding: .utf8)
        else {
            return errorBody(responseCode: "MALFORMED", message: "Request body could not be encoded as JSON")
        }

        let urlString = routes.fullUrl(operation)
        guard let url = URL(string: urlString) else {
            return errorBody(responseCode: "MALFORMED", message: "Invalid Web Service URL")
        }

        WebServiceHttpLog.request(
            logger: logger,
            operation: operation,
            url: urlString,
            environment: config.environment,
            payload: payload
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payloadData
        request.timeoutInterval = config.responseTimeout
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var response: URLResponse?
        var requestError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, urlResponse, error in
            responseData = data
            response = urlResponse
            requestError = error
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + config.responseTimeout + config.connectTimeout + 5)

        let elapsedMs = Int64(Date().timeIntervalSince(startedAt) * 1000)

        if let requestError = requestError {
            WebServiceHttpLog.error(
                logger: logger,
                operation: operation,
                message: requestError.localizedDescription,
                elapsedMs: elapsedMs
            )
            return errorBody(
                responseCode: "NO_RESPONSE",
                message: requestError.localizedDescription
            )
        }

        let httpResponse = response as? HTTPURLResponse
        let status = httpResponse?.statusCode ?? 0
        let text = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        WebServiceHttpLog.response(
            logger: logger,
            operation: operation,
            httpStatus: status,
            elapsedMs: elapsedMs,
            body: text.isEmpty ? "<empty>" : text
        )

        if text.isEmpty {
            WebServiceHttpLog.error(
                logger: logger,
                operation: operation,
                message: "Empty response (\(HTTPURLResponse.localizedString(forStatusCode: status)))",
                elapsedMs: elapsedMs
            )
            return errorBody(
                responseCode: String(status),
                message: "Empty response from Web Service (\(HTTPURLResponse.localizedString(forStatusCode: status)))"
            )
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            WebServiceHttpLog.error(
                logger: logger,
                operation: operation,
                message: "Invalid JSON",
                elapsedMs: elapsedMs
            )
            return errorBody(
                responseCode: String(status),
                message: "Response was not valid JSON"
            )
        }

        if status < 200 || status > 299 {
            let wire = EcrWireResponse.parse(parsed)
            if !wire.message.isEmpty || !wire.errorList.isEmpty {
                WebServiceHttpLog.error(
                    logger: logger,
                    operation: operation,
                    message: "HTTP \(status) — \(wire.displayMessage)",
                    elapsedMs: elapsedMs
                )
                return parsed
            }
            WebServiceHttpLog.error(
                logger: logger,
                operation: operation,
                message: HTTPURLResponse.localizedString(forStatusCode: status),
                elapsedMs: elapsedMs
            )
            return errorBody(
                responseCode: String(status),
                message: HTTPURLResponse.localizedString(forStatusCode: status)
            )
        }

        return parsed
    }

    private func logSigning(_ body: [String: Any]) {
        if config.secureHashKey.isEmpty {
            logger.debug("[Web Service] calcHash skipped — no \(WebServiceSecureHash.keyLabel) configured")
            return
        }
        let hash = ecrString(body, WebServiceSecureHash.field)
        if hash.isEmpty { return }
        WebServiceHttpLog.signing(
            logger: logger,
            keyLabel: WebServiceSecureHash.keyLabel,
            secretKey: config.secureHashKey,
            payloadToSign: WebServiceSecureHash.payloadString(body),
            secureHashValue: hash
        )
    }

    private func errorBody(responseCode: String, message: String) -> [String: Any] {
        [
            "success": false,
            "responseCode": responseCode,
            "message": message,
        ]
    }
}
