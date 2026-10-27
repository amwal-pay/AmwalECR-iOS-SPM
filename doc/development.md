# Development

Documentation, building, testing, and continuous integration for `AmwalECR-iOS-SPM`. Using the SDK is in the [README](../README.md).

## Documentation

The protocol and the operational detail are shared with the Android SDK and are
not duplicated here:

| | |
|---|---|
| **[Implementation](implementation.md)** | Plan, open, sign-on, sale, close receipt on this package |
| **[Wire protocol](https://github.com/amwal-pay/ECR-simulator/blob/main/ecr-sdk/docs/protocol.md)** | The bytes on the socket |
| **[Integration guide](https://github.com/amwal-pay/ECR-simulator/blob/main/ecr-sdk/docs/integration-guide.md)** | From an empty project to a till that reconciles properly |
| **[Troubleshooting](https://github.com/amwal-pay/ECR-simulator/blob/main/ecr-sdk/docs/troubleshooting.md)** | Symptom → cause → fix |
| **[Compatibility matrix](https://github.com/amwal-pay/amwal-ecr-flutter/blob/main/doc/compatibility-matrix.md)** | Versions, floors, and every place the platforms differ |
| **[Release policy](https://github.com/amwal-pay/amwal-ecr-flutter/blob/main/doc/release-policy.md)** | Versioning, release order, rollback |


## Building and testing

```bash
swift test            # no simulator needed
```

Unit tests share signing placeholders via `EcrTestConfigs` (aligned with
`ecr_sdk`): `SECURE_HASH_KEY_ECR_WIFI`, `SECURE_HASH_KEY_ECR_WIFI_OTHER`, and
`SECURE_HASH_KEY_WEBSERVICE`, exposed as `lan` / `lanOther` / `webService`
configs. Never commit real Amwal keys.

The suite is not incidental to the platform story: `EcrDecimalTests`,
`EcrMessageTests` and `EcrResponseReaderTests` assert this SDK against the Kotlin
SDK's own test payloads and rounding boundaries. That is what keeps "identical on
both platforms" a checkable claim.

### Continuous integration

[`codemagic.yaml`](../codemagic.yaml) runs on Codemagic:

| Workflow | When | What it does |
|---|---|---|
| `spm-verify` | every push and pull request | `swift test` and builds for iOS device + simulator |
| `spm-release` | a `vX.Y.Z` tag | same checks, verifies the tag matches the top `CHANGELOG.md` entry, then resolves that exact version from GitHub into a throwaway consumer package |

The tag *is* the SwiftPM release — nothing is uploaded and no credentials are
needed. Start a release by pushing the tag — `git push origin vX.Y.Z` — so
Codemagic receives a tag webhook (`CM_TAG` is set). A manual rebuild of a tagged
commit also works: the script falls back to `git describe` when `CM_TAG` is
empty. Do not start `spm-release` on a branch; that fails.

Tag SwiftPM first, then the matching `vX.Y.Z` on
[AmwalECR-iOS-CocoaPods](https://github.com/amwal-pay/AmwalECR-iOS-CocoaPods);
see the release policy in
[amwal-ecr-flutter](https://github.com/amwal-pay/amwal-ecr-flutter/blob/main/doc/release-policy.md).
