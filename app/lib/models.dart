class Profile {
  const Profile({required this.label, required this.path, required this.kind});

  final String label;
  final String path;
  final String kind;
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
    this.cacheDir = '',
    this.deploy = true,
    this.restart = false,
    this.snapshot = true,
    this.customDirs = const [],
    this.customNames = const {},
    this.syncUrl = '',
    this.syncUser = '',
    this.syncPassword = '',
    this.deviceName = '',
  });

  final String repo;
  final String proxy;
  final String token;
  final String cacheDir;
  final bool deploy;
  final bool restart;
  final bool snapshot;
  final List<String> customDirs;
  final Map<String, String> customNames;
  final String syncUrl;
  final String syncUser;
  final String syncPassword;
  final String deviceName;

  Settings copyWith({
    String? repo,
    String? proxy,
    String? token,
    String? cacheDir,
    bool? deploy,
    bool? restart,
    bool? snapshot,
    List<String>? customDirs,
    Map<String, String>? customNames,
    String? syncUrl,
    String? syncUser,
    String? syncPassword,
    String? deviceName,
  }) {
    return Settings(
      repo: repo ?? this.repo,
      proxy: proxy ?? this.proxy,
      token: token ?? this.token,
      cacheDir: cacheDir ?? this.cacheDir,
      deploy: deploy ?? this.deploy,
      restart: restart ?? this.restart,
      snapshot: snapshot ?? this.snapshot,
      customDirs: customDirs ?? this.customDirs,
      customNames: customNames ?? this.customNames,
      syncUrl: syncUrl ?? this.syncUrl,
      syncUser: syncUser ?? this.syncUser,
      syncPassword: syncPassword ?? this.syncPassword,
      deviceName: deviceName ?? this.deviceName,
    );
  }

  factory Settings.fromJson(Map<String, dynamic> json) {
    return Settings(
      repo: json['repo'] as String? ?? 'viui798/viui-tiger-sentense',
      proxy: json['proxy'] as String? ?? '',
      token: json['token'] as String? ?? '',
      cacheDir: json['cache_dir'] as String? ?? '',
      deploy: json['deploy'] as bool? ?? true,
      restart: json['restart'] as bool? ?? false,
      snapshot: json['snapshot'] as bool? ?? true,
      customDirs: (json['custom_dirs'] as List? ?? const []).cast<String>(),
      customNames: (json['custom_names'] as Map?)
              ?.map((key, value) => MapEntry(key.toString(), value.toString())) ??
          const {},
      syncUrl: json['sync_url'] as String? ?? '',
      syncUser: json['sync_user'] as String? ?? '',
      syncPassword: json['sync_password'] as String? ?? '',
      deviceName: json['device_name'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'repo': repo,
      'proxy': proxy,
      'token': token,
      'cache_dir': cacheDir,
      'deploy': deploy,
      'restart': restart,
      'snapshot': snapshot,
      'custom_dirs': customDirs,
      'custom_names': customNames,
      'sync_url': syncUrl,
      'sync_user': syncUser,
      'sync_password': syncPassword,
      'device_name': deviceName,
    };
  }
}

class ApplyStats {
  const ApplyStats({required this.copied, required this.skipped, this.backupStamp});

  final int copied;
  final int skipped;
  final String? backupStamp;
}
