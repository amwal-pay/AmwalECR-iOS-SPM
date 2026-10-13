import Foundation

/// ECR Hub base URLs per `EcrEnvironment` — SDK-internal only.
///
/// Resolves Amwal Hub hosts for SIT / UAT / PROD. Hostnames are intentionally
/// not published in customer docs. Paths (`/Ecr/Sale`, …) are appended by
/// `EcrWebServiceRoutes`.
enum EcrEnvironmentUrls {
    private static let sitHost = "https://test.amwalpg.com:25452"
    private static let uatHost = "https://test.amwalpg.com:25453"
    private static let prodHost = "https://pos.amwalpg.com"

    static func hubSocketUrl(environment: EcrEnvironment) -> String {
        let host: String
        switch environment {
        case .sit: host = sitHost
        case .uat: host = uatHost
        case .prod: host = prodHost
        }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
