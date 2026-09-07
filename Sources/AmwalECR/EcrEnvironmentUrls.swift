import Foundation

/// ECR environment URLs — SDK-internal only.
///
/// SIT, UAT, and PROD currently target the same Amwal test host.
enum EcrEnvironmentUrls {
    private static let ecrHost = "https://test.amwalpg.com:25452"

    static func hubSocketUrl(environment: EcrEnvironment) -> String {
        switch environment {
        case .sit, .uat, .prod:
            return ecrHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }
}
