import Foundation

/// Fixed path suffixes for Web Service ECR REST operations.
enum EcrWebServiceEndpoints {
    static let sale = "/Ecr/Sale"
    static let void = "/Ecr/Void"
    static let refund = "/Ecr/Refund"
    static let transactionStatus = "/Ecr/Inquiry"
    static let settle = "/Ecr/settle"
    static let closeReceipt = "/Ecr/closeReceipt"
}
