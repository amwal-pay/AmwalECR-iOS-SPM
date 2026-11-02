import Foundation

/// Web Service ECR operations exposed as REST endpoints on the ECR API host.
enum EcrWebServiceOperation {
    case sale
    case void
    case refund
    case transactionStatus
    case settle
    case closeReceipt

    var path: String {
        switch self {
        case .sale: return EcrWebServiceEndpoints.sale
        case .void: return EcrWebServiceEndpoints.void
        case .refund: return EcrWebServiceEndpoints.refund
        case .transactionStatus: return EcrWebServiceEndpoints.transactionStatus
        case .settle: return EcrWebServiceEndpoints.settle
        case .closeReceipt: return EcrWebServiceEndpoints.closeReceipt
        }
    }

    var label: String {
        switch self {
        case .sale: return "Sale"
        case .void: return "Void"
        case .refund: return "Refund"
        case .transactionStatus: return "Transaction status"
        case .settle: return "Settlement"
        case .closeReceipt: return "Close receipt"
        }
    }

    static func from(_ transactionType: EcrTransactionType) -> EcrWebServiceOperation? {
        switch transactionType {
        case .sale: return .sale
        case .void: return .void
        case .refund: return .refund
        case .inquiry: return .transactionStatus
        case .receipt, .signOn: return nil
        case .closeReceipt: return .closeReceipt
        case .settlement: return .settle
        }
    }
}
