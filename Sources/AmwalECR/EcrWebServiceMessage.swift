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
        /// Set for inquiry-by-reference; ignored for stan-based inquiry.
        originalMerchantReference: String = "",
        merchantReference: String = "",
        transactionDateTime: String = ""
    ) throws -> (String, [String: Any]) {
        if type == .closeReceipt {
            return try buildCloseReceipt(
                merchantId: merchantId,
                terminalId: terminalId,
                terminalSerial: terminalSerial,
                secureHashKey: secureHashKey,
                ecrId: ecrId,
                merchantReference: merchantReference,
                originalMerchantReference: originalMerchantReference,
                transactionDateTime: transactionDateTime
            )
        }
        if type == .settlement {
            return try buildPlain(
                merchantId: merchantId,
                terminalId: terminalId,
                terminalSerial: terminalSerial,
                secureHashKey: secureHashKey,
                currencyCode: currencyCode,
                ecrId: ecrId,
                merchantReference: merchantReference,
                transactionDateTime: transactionDateTime
            )
        }

        let reference = try EcrMessage.merchantReference(merchantReference)
        let wireDateTime = transactionDateTime.isEmpty ? timestamp() : transactionDateTime
        var body: [String: Any] = [
            "version": EcrMessage.protocolVersion,
            "messageType": type.messageType,
            "merchantId": merchantId,
            "terminalId": terminalId,
            "terminalSerial": terminalSerial,
            "ecrId": ecrId,
            "merchantReference": reference,
            "currencyCode": currencyCode,
            "transactionDateTime": wireDateTime,
            // Hub validates this separately from transactionDateTime
            // (`RequestDateTimeIsRequired` when omitted).
            "requestDateTime": wireDateTime,
        ]

        switch type {
        case .sale:
            body["amount"] = paddedAmount(amountMinorUnits)
        case .void:
            body["stan"] = EcrMessage.paddedStan(stan)
            body["originalMerchantReference"] = reference
            body["originalTerminalId"] = terminalId
        case .refund:
            body["amount"] = paddedAmount(amountMinorUnits)
            body["stan"] = EcrMessage.paddedStan(stan)
            body["originalTransactionDate"] = originalTransactionDate
            body["originalMerchantReference"] = reference
            body["originalTerminalId"] = terminalId
        case .inquiry:
            let invoiceStan = EcrMessage.paddedStan(stan)
            let byReference = invoiceStan.isEmpty && !originalMerchantReference.trimmed.isEmpty
            body["stan"] = invoiceStan
            body["originalTransactionDate"] = originalTransactionDate
            // By STAN → empty originalMerchantReference; by reference → set it.
            body["originalMerchantReference"] = byReference
                ? try EcrMessage.merchantReference(originalMerchantReference)
                : ""
            body["originalTerminalId"] = terminalId
        case .receipt:
            throw EcrInvalidArgument("Receipt is not a Web Service operation")
        case .signOn:
            throw EcrInvalidArgument("Sign-on is not a Web Service operation")
        case .closeReceipt:
            throw EcrInvalidArgument("unreachable")
        case .settlement:
            throw EcrInvalidArgument("unreachable")
        }

        let json: [String: Any]
        if secureHashKey.isEmpty {
            json = body
        } else {
            json = try WebServiceSecureHash.withHash(body, secretKey: secureHashKey)
        }

        return (reference, json)
    }

    /// Hub `/Ecr/closeReceipt` body. No `messageType` and no `currencyCode`.
    /// `originalMerchantReference` is the sale, void, or refund.
    /// `merchantReference` is this close request's own id.
    static func buildCloseReceipt(
        merchantId: Int64,
        terminalId: Int64,
        terminalSerial: String,
        secureHashKey: String,
        ecrId: String = "ECR01",
        merchantReference: String = "",
        originalMerchantReference: String,
        transactionDateTime: String = ""
    ) throws -> (String, [String: Any]) {
        if originalMerchantReference.trimmed.isEmpty {
            throw EcrInvalidArgument("Close receipt needs the original merchant reference")
        }
        let reference = try EcrMessage.merchantReference(merchantReference)
        let original = try EcrMessage.merchantReference(originalMerchantReference)
        let wireDateTime = transactionDateTime.isEmpty ? timestamp() : transactionDateTime
        let body: [String: Any] = [
            "version": EcrMessage.protocolVersion,
            "merchantId": merchantId,
            "terminalId": terminalId,
            "terminalSerial": terminalSerial,
            "ecrId": ecrId,
            "merchantReference": reference,
            "transactionDateTime": wireDateTime,
            "requestDateTime": wireDateTime,
            "originalMerchantReference": original,
        ]
        if secureHashKey.isEmpty {
            return (reference, body)
        }
        return (reference, try WebServiceSecureHash.withHash(body, secretKey: secureHashKey))
    }

    /// Hub `/Ecr/settle` body: identity, currency, both timestamps. No `messageType`.
    static func buildPlain(
        merchantId: Int64,
        terminalId: Int64,
        terminalSerial: String,
        secureHashKey: String,
        currencyCode: String = "512",
        ecrId: String = "ECR01",
        merchantReference: String = "",
        transactionDateTime: String = ""
    ) throws -> (String, [String: Any]) {
        let reference = try EcrMessage.merchantReference(merchantReference)
        let wireDateTime = transactionDateTime.isEmpty ? timestamp() : transactionDateTime
        let body: [String: Any] = [
            "version": EcrMessage.protocolVersion,
            "merchantId": merchantId,
            "terminalId": terminalId,
            "terminalSerial": terminalSerial,
            "ecrId": ecrId,
            "merchantReference": reference,
            "currencyCode": currencyCode,
            "transactionDateTime": wireDateTime,
            "requestDateTime": wireDateTime,
        ]
        if secureHashKey.isEmpty {
            return (reference, body)
        }
        return (reference, try WebServiceSecureHash.withHash(body, secretKey: secureHashKey))
    }

    private static func paddedAmount(_ amountMinorUnits: Int64?) -> String {
        let minor = String(amountMinorUnits ?? 0)
        return minor.count >= 12
            ? minor
            : String(repeating: "0", count: 12 - minor.count) + minor
    }

    private static func timestamp() -> String {
        EcrMessage.timestamp()
    }
}
