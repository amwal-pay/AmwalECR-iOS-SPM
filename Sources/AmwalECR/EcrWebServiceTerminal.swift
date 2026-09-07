import Foundation

/// Web Service ECR client — REST over HTTPS with JSON body signing.
///
/// Use this instead of `EcrTerminal` when the terminal is configured for
/// Web Service mode (`ecrMode: 4`).
public final class EcrWebServiceTerminal {
    private let terminalSerial: String
    private let config: EcrConfig
    private let logger: EcrLogger
    private let api: HttpEcrWebServiceApi

    public init(
        terminalSerial: String,
        config: EcrConfig = EcrConfig(),
        logger: EcrLogger = .none
    ) {
        self.terminalSerial = terminalSerial
        self.config = config
        self.logger = logger
        self.api = HttpEcrWebServiceApi(config: config, logger: logger)
    }

    public func sale(amount: Decimal, merchantReference: String = "") -> EcrResult {
        guard let ids = backendIds() else { return invalidIds() }
        do {
            let (reference, body) = try buildRequest(
                type: .sale,
                ids: ids,
                merchantReference: merchantReference,
                amountMinorUnits: amount.toMinorUnits(digits: config.minorUnitDigits)
            )
            let response = api.postJson(operation: .sale, body: body)
            return EcrTerminal.result(
                from: response,
                merchantReference: reference,
                minorUnitDigits: config.minorUnitDigits
            )
        } catch let error as EcrInvalidArgument {
            return .failed(
                merchantReference: merchantReference,
                failure: .malformed(error.message),
                recovered: nil
            )
        } catch {
            return .failed(
                merchantReference: merchantReference,
                failure: .malformed(error.localizedDescription),
                recovered: nil
            )
        }
    }

    public func void(receiptNumber: String, merchantReference: String = "") -> EcrResult {
        guard let ids = backendIds() else { return invalidIds() }
        do {
            let (reference, body) = try buildRequest(
                type: .void,
                ids: ids,
                merchantReference: merchantReference,
                stan: receiptNumber
            )
            let response = api.postJson(operation: .void, body: body)
            return EcrTerminal.result(
                from: response,
                merchantReference: reference,
                minorUnitDigits: config.minorUnitDigits
            )
        } catch let error as EcrInvalidArgument {
            return .failed(
                merchantReference: merchantReference,
                failure: .malformed(error.message),
                recovered: nil
            )
        } catch {
            return .failed(
                merchantReference: merchantReference,
                failure: .malformed(error.localizedDescription),
                recovered: nil
            )
        }
    }

    public func refund(
        amount: Decimal,
        receiptNumber: String,
        transactionDate: String,
        merchantReference: String = ""
    ) -> EcrResult {
        guard let ids = backendIds() else { return invalidIds() }
        do {
            let (reference, body) = try buildRequest(
                type: .refund,
                ids: ids,
                merchantReference: merchantReference,
                amountMinorUnits: amount.toMinorUnits(digits: config.minorUnitDigits),
                stan: receiptNumber,
                originalTransactionDate: transactionDate
            )
            let response = api.postJson(operation: .refund, body: body)
            return EcrTerminal.result(
                from: response,
                merchantReference: reference,
                minorUnitDigits: config.minorUnitDigits
            )
        } catch let error as EcrInvalidArgument {
            return .failed(
                merchantReference: merchantReference,
                failure: .malformed(error.message),
                recovered: nil
            )
        } catch {
            return .failed(
                merchantReference: merchantReference,
                failure: .malformed(error.localizedDescription),
                recovered: nil
            )
        }
    }

    public func inquire(
        receiptNumber: String,
        transactionDate: String,
        merchantReference: String = ""
    ) -> EcrInquiry {
        guard let ids = backendIds() else {
            return .failed(
                merchantReference: merchantReference,
                failure: .malformed("merchantId and terminalId are required for Web Service ECR")
            )
        }
        do {
            let (reference, body) = try buildRequest(
                type: .inquiry,
                ids: ids,
                merchantReference: merchantReference,
                stan: receiptNumber,
                originalTransactionDate: transactionDate
            )
            let response = api.postJson(operation: .transactionStatus, body: body)
            return EcrTerminal.inquiry(
                from: response,
                merchantReference: reference,
                minorUnitDigits: config.minorUnitDigits
            )
        } catch let error as EcrInvalidArgument {
            return .failed(merchantReference: merchantReference, failure: .malformed(error.message))
        } catch {
            return .failed(
                merchantReference: merchantReference,
                failure: .malformed(error.localizedDescription)
            )
        }
    }

    public func inquireByReference(
        originalReference: String,
        transactionDate: String,
        merchantReference: String = ""
    ) -> EcrInquiry {
        inquire(
            receiptNumber: "",
            transactionDate: transactionDate,
            merchantReference: merchantReference.isEmpty ? originalReference : merchantReference
        )
    }

    private func buildRequest(
        type: EcrTransactionType,
        ids: (Int64, Int64),
        merchantReference: String = "",
        amountMinorUnits: Int64? = nil,
        stan: String = "",
        originalTransactionDate: String = ""
    ) throws -> (String, [String: Any]) {
        let (merchantId, terminalId) = ids
        let built = try EcrWebServiceMessage.build(
            type: type,
            merchantId: merchantId,
            terminalId: terminalId,
            terminalSerial: terminalSerial,
            secureHashKey: config.secureHashKey,
            currencyCode: config.currencyCode,
            ecrId: config.ecrId,
            amountMinorUnits: amountMinorUnits,
            stan: stan,
            originalTransactionDate: originalTransactionDate,
            merchantReference: merchantReference
        )
        WebServiceHttpLog.operation(
            logger: logger,
            messageType: type.messageType,
            merchantReference: built.0,
            terminalSerial: terminalSerial,
            merchantId: merchantId,
            terminalId: terminalId
        )
        return built
    }

    private func backendIds() -> (Int64, Int64)? {
        guard let merchantId = Int64(config.merchantId),
              let terminalId = Int64(config.terminalId) else {
            return nil
        }
        return (merchantId, terminalId)
    }

    private func invalidIds() -> EcrResult {
        .failed(
            merchantReference: "",
            failure: .malformed(
                "merchantId and terminalId must be set on EcrConfig for Web Service ECR"
            ),
            recovered: nil
        )
    }
}

private extension Decimal {
    func toMinorUnits(digits: Int) -> Int64 {
        let scaled = NSDecimalNumber(decimal: self)
            .multiplying(byPowerOf10: Int16(digits))
            .rounding(accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            ))
        return scaled.int64Value
    }
}
