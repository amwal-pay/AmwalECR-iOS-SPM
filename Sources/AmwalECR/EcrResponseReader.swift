import Foundation

/// Reading the terminal's answer.
///
/// Mirrors the Kotlin SDK's `toEcrResult`, `toInquiry` and `toReceipt`.
extension EcrTerminal {

    static func result(
        from json: [String: Any],
        merchantReference: String,
        minorUnitDigits: Int
    ) -> EcrResult {
        let envelope = EcrResponseEnvelope.parse(json)
        let data = envelope.data
        let resolvedReference = envelope.merchantReference.isEmpty
            ? merchantReference
            : envelope.merchantReference

        if !envelope.success {
            return .declined(
                EcrDeclined(
                    merchantReference: resolvedReference,
                    responseCode: envelope.responseCode,
                    reason: envelope.displayMessage.isEmpty ? "Declined" : envelope.displayMessage,
                    nextStep: EcrNextStep.of(ecrString(json, "nextStep")),
                    raw: EcrMessageCodec.text(json)
                )
            )
        }

        let amountMajor = settledAmountMajor(
            data: data,
            minorUnitDigits: minorUnitDigits,
            root: json
        )

        let requestedMajor: String = {
            if let data = data {
                let amount = ecrString(data, "amount")
                if !amount.isEmpty { return amount }
            }
            return majorUnits(ecrString(json, "requestedAmount"), digits: minorUnitDigits)
        }()

        let rrn = {
            let fromData = data.map { ecrString($0, "rrn") } ?? ""
            return fromData.isEmpty ? ecrString(json, "rrn") : fromData
        }()

        let authCode = {
            let fromData = data.map { ecrString($0, "authCode") } ?? ""
            return fromData.isEmpty ? ecrString(json, "authCode") : fromData
        }()

        let maskedPan = {
            if let data = data {
                let cardMask = ecrString(data, "cardMask")
                if !cardMask.isEmpty { return cardMask }
                let masked = ecrString(data, "maskedPan")
                if !masked.isEmpty { return masked }
            }
            return ecrString(json, "maskedPan")
        }()

        let partialApproval = data.map { ecrFlag($0, "isPartialApprove") } ?? ecrFlag(json, "partialApproval")

        return .approved(
            EcrApproved(
                merchantReference: resolvedReference,
                amount: amountMajor,
                responseCode: envelope.responseCode,
                rrn: rrn,
                authCode: authCode,
                maskedPan: maskedPan,
                partialApproval: partialApproval,
                requestedAmount: requestedMajor,
                raw: EcrMessageCodec.text(json)
            )
        )
    }

    static func inquiry(
        from json: [String: Any],
        merchantReference: String,
        minorUnitDigits: Int
    ) -> EcrInquiry {
        let envelope = EcrResponseEnvelope.parse(json)
        let data = envelope.data
        let resolvedReference = envelope.merchantReference.isEmpty
            ? merchantReference
            : envelope.merchantReference

        guard let data = data else {
            return .notFound(
                merchantReference: resolvedReference,
                reason: envelope.displayMessage.isEmpty
                    ? "Transaction not found"
                    : envelope.displayMessage,
                raw: EcrMessageCodec.text(json)
            )
        }

        let stan = ecrString(data, "stan")
        let typeDisplay = ecrString(data, "transactionTypeDisplayName")
        let status = ecrString(data, "status")

        return .found(
            merchantReference: resolvedReference,
            transaction: EcrTransaction(
                transactionId: ecrString(data, "transactionId"),
                stan: stan.isEmpty ? ecrString(data, "systemTraceNr") : stan,
                type: typeDisplay.isEmpty ? ecrString(data, "transactionType") : typeDisplay,
                status: status.isEmpty ? (envelope.success ? "Approved" : "Declined") : status,
                partialApproval: ecrFlag(data, "isPartialApprove"),
                authorizedAmount: ecrString(data, "authorizeAmount"),
                amount: settledAmountMajor(data: data, minorUnitDigits: minorUnitDigits, root: json),
                totalAmount: ecrString(data, "totalAmount"),
                currency: {
                    let currency = ecrString(data, "currency")
                    return currency.isEmpty ? ecrString(data, "currencyId") : currency
                }(),
                transactionTime: ecrString(data, "transactionTime"),
                maskedPan: {
                    let cardMask = ecrString(data, "cardMask")
                    return cardMask.isEmpty ? ecrString(data, "cardNumber") : cardMask
                }(),
                cardHolderName: ecrString(data, "cardHolderName"),
                rrn: ecrString(data, "rrn"),
                authCode: ecrString(data, "authCode"),
                batchId: ecrString(data, "batchId"),
                terminalId: ecrString(data, "terminalId"),
                isRefunded: ecrFlag(data, "isRefunded"),
                canVoid: ecrFlag(data, "canVoid"),
                canRefund: ecrFlag(data, "canRefund")
            ),
            raw: EcrMessageCodec.text(json)
        )
    }

    static func receipt(from json: [String: Any], merchantReference: String) -> EcrReceipt {
        let envelope = EcrResponseEnvelope.parse(json)
        let resolvedReference = envelope.merchantReference.isEmpty
            ? merchantReference
            : envelope.merchantReference
        let url = envelope.data.map { ecrString($0, "receiptUrl") } ?? ""

        guard !url.isEmpty else {
            return .unavailable(
                merchantReference: resolvedReference,
                reason: envelope.displayMessage.isEmpty
                    ? "The receipt could not be generated"
                    : envelope.displayMessage,
                raw: EcrMessageCodec.text(json)
            )
        }

        return .ready(
            merchantReference: resolvedReference,
            url: url,
            raw: EcrMessageCodec.text(json)
        )
    }

    /// The amount actually settled, in major units.
    static func settledAmountMajor(
        data: [String: Any]?,
        minorUnitDigits: Int,
        root: [String: Any]
    ) -> String {
        if let data = data {
            if let authorized = Decimal(string: ecrString(data, "authorizeAmount")),
               authorized > 0 {
                return ecrString(data, "authorizeAmount")
            }
            let amount = ecrString(data, "amount")
            if !amount.isEmpty { return amount }
        }
        return majorUnits(ecrString(root, "amount"), digits: minorUnitDigits)
    }

    static func majorUnits(_ minorUnits: String, digits: Int) -> String {
        if minorUnits.isEmpty { return "" }
        guard minorUnits.allSatisfy(\.isNumber) else { return minorUnits }
        return EcrDecimal.majorUnits(minorUnits, digits: digits)
    }
}
