import Foundation

/// Reading the terminal's answer.
///
/// A direct translation of the Kotlin SDK's `toResult`, `toInquiry` and
/// `toReceipt`, kept in one file so the two can be read side by side. The
/// payloads in `ecr-sdk/src/test/.../InquiryReadingTest.kt` are the same ones
/// `EcrResponseReaderTests` uses here, for exactly that reason.
extension EcrTerminal {

    /// The backend's code for a plain approval.
    static let approvedCode = "00"

    /// Reads the terminal's answer into one of the three outcomes.
    ///
    /// `approved` is authoritative and is read first. A partial approval that
    /// the operator then voided comes back carrying the bank's own `00`,
    /// because the bank did approve before the void undid it — deciding from
    /// the code alone books that as a sale.
    static func result(
        from json: [String: Any],
        merchantReferenceId: String,
        minorUnitDigits: Int
    ) -> EcrResult {
        let responseCode = ecrString(json, "responseCode")
        let approved = strictBool(json["approved"]) ?? (responseCode == approvedCode)

        guard approved else {
            return .declined(
                EcrDeclined(
                    merchantReferenceId: merchantReferenceId,
                    responseCode: responseCode,
                    reason: ecrString(json, "responseMessage"),
                    nextStep: EcrNextStep.of(ecrString(json, "nextStep")),
                    raw: EcrMessageCodec.text(json)
                )
            )
        }

        return .approved(
            EcrApproved(
                merchantReferenceId: merchantReferenceId,
                amount: EcrDecimal.majorUnits(ecrString(json, "amount"), digits: minorUnitDigits),
                responseCode: responseCode,
                rrn: ecrString(json, "rrn"),
                authCode: ecrString(json, "authCode"),
                maskedPan: ecrString(json, "maskedPan"),
                partialApproval: strictBool(json["partialApproval"]) ?? false,
                requestedAmount: EcrDecimal.majorUnits(
                    ecrString(json, "requestedAmount"),
                    digits: minorUnitDigits
                ),
                raw: EcrMessageCodec.text(json)
            )
        )
    }

    /// Reads the terminal's answer to an inquiry.
    ///
    /// The transaction itself sits under `ecrResponse.data`, where the terminal
    /// passes its backend's own record through; the outer fields describe the
    /// lookup. `approved: true` there means **found**, not paid — what became
    /// of the transaction is `data.status`.
    static func inquiry(
        from json: [String: Any],
        merchantReferenceId: String,
        minorUnitDigits: Int
    ) -> EcrInquiry {
        let found = strictBool(json["approved"]) ?? false
        let data = (json["ecrResponse"] as? [String: Any])?["data"] as? [String: Any]

        guard found, let data = data else {
            return .notFound(
                merchantReferenceId: merchantReferenceId,
                reason: ecrString(json, "responseMessage"),
                raw: EcrMessageCodec.text(json)
            )
        }

        let type = ecrString(data, "transactionTypeDisplayName")
        let status = ecrString(data, "status")
        let backendAmount = ecrString(data, "amount")

        return .found(
            merchantReferenceId: merchantReferenceId,
            transaction: EcrTransaction(
                transactionId: ecrString(data, "transactionId"),
                stan: ecrString(data, "stan"),
                type: type.isEmpty ? ecrString(data, "transactionType") : type,
                // A terminal that has no status to give is a terminal answering
                // about something it does not know the fate of, which is not a
                // reason to report a blank a till will read as a failure. Kept
                // as a floor under the value, not as a translation: the terminal
                // states the status itself, whether the record came from its own
                // log or from the backend.
                status: status.isEmpty ? (found ? "Approved" : "Declined") : status,
                // The backend records amounts in major units already; the outer
                // `amount` field is the minor-unit one the wire format uses.
                amount: backendAmount.isEmpty
                    ? EcrDecimal.majorUnits(ecrString(json, "amount"), digits: minorUnitDigits)
                    : backendAmount,
                totalAmount: ecrString(data, "totalAmount"),
                currency: ecrString(data, "currency"),
                transactionTime: ecrString(data, "transactionTime"),
                maskedPan: ecrString(data, "cardNumber"),
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

    /// Reads the terminal's answer to a receipt request.
    ///
    /// An empty or absent `receiptUrl` means no receipt, whatever the response
    /// code says. A receipt with no URL is not a receipt.
    static func receipt(from json: [String: Any], merchantReferenceId: String) -> EcrReceipt {
        let data = (json["ecrResponse"] as? [String: Any])?["data"] as? [String: Any]
        let url = data.map { ecrString($0, "receiptUrl") } ?? ""

        guard !url.isEmpty else {
            return .unavailable(
                merchantReferenceId: merchantReferenceId,
                reason: ecrString(json, "responseMessage"),
                raw: EcrMessageCodec.text(json)
            )
        }

        return .ready(merchantReferenceId: merchantReferenceId, url: url, raw: EcrMessageCodec.text(json))
    }

    /// A boolean the way the Kotlin SDK reads one: a real JSON boolean or the
    /// exact text `"true"`/`"false"`, and `nil` for anything else — which is
    /// what makes "absent" distinguishable from "false" at the call sites that
    /// need to fall back to the response code.
    private static func strictBool(_ value: Any?) -> Bool? {
        guard let value = value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        switch value as? String {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}
