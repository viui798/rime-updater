import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('com.viui798.rime_updater/platform');

/// Android 上是否已获得「所有文件访问权限」（用于读写 /storage/emulated/0/rime）。
Future<bool> hasAllFilesAccess() async {
  if (!Platform.isAndroid) return true;
  try {
    return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
  } catch (_) {
    return false;
  }
}

/// 跳转到系统设置页，让用户授予「所有文件访问权限」。
Future<void> requestAllFilesAccess() async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod<void>('requestAllFilesAccess');
  } catch (_) {
    // 系统页面不可用时由界面提示用户手动授权
  }
}

/// Android 系统文件选择框，返回复制到应用缓存后的本地路径。
Future<String?> pickAndroidFile() async {
  if (!Platform.isAndroid) return null;
  try {
    return await _channel.invokeMethod<String>('pickFile');
  } catch (_) {
    return null;
  }
}
