import AmwalECR

/// Shared `EcrConfig` values for unit tests.
///
/// Matches `ecr_sdk` `EcrTestConfigs`. Secrets use named placeholders — never
/// commit real Amwal keys. Values are synthetic valid hex so `EcrConfig`
/// accepts them; override in CI if needed.
enum EcrTestConfigs {
    /// Wi‑Fi / LAN / USB cable signing placeholder (valid hex, not a real secret).
    static let SECURE_HASH_KEY_ECR_WIFI =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    /// Alternate Wi‑Fi placeholder — wrong-key verification cases.
    static let SECURE_HASH_KEY_ECR_WIFI_OTHER =
        "cccccccccccccccccccccccccccccccc"

    /// Web Service REST signing placeholder (valid hex, not a real secret).
    static let SECURE_HASH_KEY_WEBSERVICE =
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    static let lan = EcrConfig(secureHashKey: SECURE_HASH_KEY_ECR_WIFI)

    static let lanOther = EcrConfig(secureHashKey: SECURE_HASH_KEY_ECR_WIFI_OTHER)

    static let webService = EcrConfig(
        merchantId: "13593",
        terminalId: "742001",
        environment: .uat,
        secureHashKey: SECURE_HASH_KEY_WEBSERVICE
    )
}
