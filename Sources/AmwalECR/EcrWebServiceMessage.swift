import Foundation

/// Web Service ECR wire payload — fixed field set per operation, signed with
/// `WebServiceSecureHash` (HMAC over the JSON body).
enum EcrWebServiceMessage {

    static func build(
        type: EcrTransactionType,
        merchantId: Int64,
        terminalId: Int64,
        terminalSerial: String,
        secureHashKey: String,
        currencyCode: String = "512",
        ecrId: String = "ECR01",
        amountMinorUnits: Int64? = nil,
        stan: String = "",
        originalTransactionDate: String = "",
        merchantReference: String = "",
        transactionDateTime: String = "",
        requestDateTime: String = ""
    ) throws -> (String, [String: Any]) {
        let reference = try EcrMessage.merchantReference(merchantReference)
        let wireDateTime = transactionDateTime.isEmpty ? timestamp() : transactionDateTime
        var body: [String: Any] = [
            "version": EcrMessage.protocolVersion,
            "messageType": type.messageType,
            "merchantReference": reference,
            "terminalSerial": terminalSerial,
            "currencyCode": currencyCode,
            "transactionDateTime": wireDateTime,
            "requestDateTime": requestDateTime.isEmpty ? wireDateTime : requestDateTime,
            "ecrId": ecrId,
            "merchantId": merchantId,
            "terminalId": terminalId,
        ]

        switch type {
        case .sale:
            let minor = String(amountMinorUnits ?? 0)
            body["amount"] = minor.count >= 12
                ? minor
                : String(repeating: "0", count: 12 - minor.count) + minor
        case .void:
            body["stan"] = EcrMessage.paddedStan(stan)
        case .refund:
            let minor = String(amountMinorUnits ?? 0)
            body["amount"] = minor.count >= 12
                ? minor
                : String(repeating: "0", count: 12 - minor.count) + minor
            body["stan"] = EcrMessage.paddedStan(stan)
            body["originalTransactionDate"] = originalTransactionDate
        case .inquiry:
            body["stan"] = EcrMessage.paddedStan(stan)
            body["originalTransactionDate"] = originalTransactionDate
        case .receipt:
            throw EcrInvalidArgument("Receipt is not a Web Service operation")
        }

        let json: [String: Any]
        if secureHashKey.isEmpty {
            json = body
        } else {
            json = try WebServiceSecureHash.withHash(body, secretKey: secureHashKey)
        }

        return (reference, json)
    }

    private static func timestamp() -> String {
        EcrMessage.timestamp()
    }
}
