class Profile {
  const Profile({
    required this.label,
    required this.path,
    required this.kind,
    this.safUri,
  });

  final String label;
  final String path;
  final String kind;

  /// 通过 Android SAF 访问时的目录 URI（例如元书暴露的 RimeUserData）。
  /// 非空时，所有文件操作都应改走 SAF，而不是 [path]。
  final String? safUri;

  bool get isSaf => safUri != null && safUri!.isNotEmpty;

  /// 稳定的身份标识：SAF 目录用 URI，其余用文件系统路径。
  String get identity => isSaf ? 'saf:$safUri' : path;
}

class Asset {
  const Asset({required this.name, required this.url, required this.size});

  final String name;
  final String url;
  final int size;
}

class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.assets,
    required this.assetName,
    required this.isDelta,
    required this.assetSize,
  });

  final String version;
  final List<Asset> assets;
  final String assetName;
  final bool isDelta;
  final int assetSize;

  Asset? get chosenAsset {
    for (final asset in assets) {
      if (asset.name == assetName) return asset;
    }
    return null;
  }
}

class BackupInfo {
  const BackupInfo({
    required this.stamp,
    required this.version,
    required this.previousVersion,
    required this.overwritten,
    required this.created,
    required this.deleted,
  });

  final String stamp;
  final String version;
  final String previousVersion;
  final int overwritten;
  final int created;
  final int deleted;
}

class Settings {
  const Settings({
    this.repo = 'viui798/viui-tiger-sentense',
    this.proxy = '',
    this.token = '',
    this.mirror = '',
    this.cacheDir = '',
    this.deploy = true,
    this.restart = false,
    this.snapshot = true,
    this.customDirs = const [],
    this.customNames = const {},
    this.hiddenDirs = const [],
    this.safDirs = const [],
    this.syncUrl = '',
    this.syncUser = '',
    this.syncPassword = '',
    this.deviceName = '',
    this.deviceOrder = const [],
    this.selectedScheme = '',
  });

  final String repo;
  final String proxy;
  final String token;

  /// 下载镜像前缀（可选）：填 `https://gh-proxy.com/` 之类，会把
  /// `https://github.com/...` 的 Release 资产拼在前面下载。
  final String mirror;
  final String cacheDir;
  final bool deploy;
  final bool restart;
  final bool snapshot;
  final List<String> customDirs;
  final Map<String, String> customNames;
  final List<String> hiddenDirs;

  /// SAF 目录：每项是 {"uri": ..., "label": ...}
  final List<Map<String, dynamic>> safDirs;
  final String syncUrl;
  final String syncUser;
  final String syncPassword;
  final String deviceName;

  /// 设备显示顺序（存 identity，SAF 用 URI、其余用路径）。
  final List<String> deviceOrder;

  /// 方案仓库里勾选的文件名；一键更新时优先用它。
  final String selectedScheme;

  Settings copyWith({
    String? repo,
    String? proxy,
    String? token,
    String? mirror,
    String? cacheDir,
    bool? deploy,
    bool? restart,
    bool? snapshot,
    List<String>? customDirs,
    Map<String, String>? customNames,
    List<String>? hiddenDirs,
    List<Map<String, dynamic>>? safDirs,
    String? syncUrl,
    String? syncUser,
    String? syncPassword,
    String? deviceName,
    List<String>? deviceOrder,
    String? selectedScheme,
  }) {
    return Settings(
      repo: repo ?? this.repo,
      proxy: proxy ?? this.proxy,
      token: token ?? this.token,
      mirror: mirror ?? this.mirror,
      cacheDir: cacheDir ?? this.cacheDir,
      deploy: deploy ?? this.deploy,
      restart: restart ?? this.restart,
      snapshot: snapshot ?? this.snapshot,
      customDirs: customDirs ?? this.customDirs,
      customNames: customNames ?? this.customNames,
      hiddenDirs: hiddenDirs ?? this.hiddenDirs,
      safDirs: safDirs ?? this.safDirs,
      syncUrl: syncUrl ?? this.syncUrl,
      syncUser: syncUser ?? this.syncUser,
      syncPassword: syncPassword ?? this.syncPassword,
      deviceName: deviceName ?? this.deviceName,
      deviceOrder: deviceOrder ?? this.deviceOrder,
      selectedScheme: selectedScheme ?? this.selectedScheme,
    );
  }

  factory Settings.fromJson(Map<String, dynamic> json) {
    return Settings(
      repo: json['repo'] as String? ?? 'viui798/viui-tiger-sentense',
      proxy: json['proxy'] as String? ?? '',
      token: json['token'] as String? ?? '',
      mirror: json['mirror'] as String? ?? '',
      cacheDir: json['cache_dir'] as String? ?? '',
      deploy: json['deploy'] as bool? ?? true,
      restart: json['restart'] as bool? ?? false,
      snapshot: json['snapshot'] as bool? ?? true,
      customDirs: (json['custom_dirs'] as List? ?? const []).cast<String>(),
      customNames: (json['custom_names'] as Map?)
              ?.map((key, value) => MapEntry(key.toString(), value.toString())) ??
          const {},
      hiddenDirs: (json['hidden_dirs'] as List? ?? const []).cast<String>(),
      safDirs: (json['saf_dirs'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(),
      syncUrl: json['sync_url'] as String? ?? '',
      syncUser: json['sync_user'] as String? ?? '',
      syncPassword: json['sync_password'] as String? ?? '',
      deviceName: json['device_name'] as String? ?? '',
      deviceOrder: (json['device_order'] as List? ?? const []).cast<String>(),
      selectedScheme: json['selected_scheme'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'repo': repo,
      'proxy': proxy,
      'token': token,
      'mirror': mirror,
      'cache_dir': cacheDir,
      'deploy': deploy,
      'restart': restart,
      'snapshot': snapshot,
      'custom_dirs': customDirs,
      'custom_names': customNames,
      'hidden_dirs': hiddenDirs,
      'saf_dirs': safDirs,
      'sync_url': syncUrl,
      'sync_user': syncUser,
      'sync_password': syncPassword,
      'device_name': deviceName,
      'device_order': deviceOrder,
      'selected_scheme': selectedScheme,
    };
  }
}

class ApplyStats {
  const ApplyStats({required this.copied, required this.skipped, this.backupStamp});

  final int copied;
  final int skipped;
  final String? backupStamp;
}
