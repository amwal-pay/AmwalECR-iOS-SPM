import Foundation

/// Deployment environment for Web Service ECR.
///
/// The SDK resolves Hub URLs internally; integrators pass only this enum in
/// `EcrConfig.environment`.
public enum EcrEnvironment: String, CaseIterable {
    case sit = "SIT"
    case uat = "UAT"
    case prod = "PROD"

    public static let `default`: EcrEnvironment = .sit

    public static func fromName(_ name: String?) -> EcrEnvironment {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return allCases.first { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame } ?? .default
    }
}
