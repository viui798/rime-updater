/// 客户端自身版本。
///
/// 必须与 `pubspec.yaml` 的 `version:` 保持一致——`test/app_update_test.dart`
/// 会读 pubspec 校验，防止两边漂移。
const String appVersion = '0.10.0';

/// 构建号，对应 pubspec 的 `+N`。
const int appBuild = 38;

/// Android versionCode = [appBuild] + 2000（详见构建脚本）。
const int androidVersionCodeBase = 2000;
