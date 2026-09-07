import Foundation

/// Resolves the Hub URL and fixed ECR operation paths for an environment.
struct EcrWebServiceRoutes {
    let environment: EcrEnvironment

    init(config: EcrConfig) {
        self.environment = config.environment
    }

    func hubSocketUrl() -> String {
        EcrEnvironmentUrls.hubSocketUrl(environment: environment)
    }

    func fullUrl(_ operation: EcrWebServiceOperation) -> String {
        hubSocketUrl().trimmingCharacters(in: CharacterSet(charactersIn: "/")) + operation.path
    }
}
