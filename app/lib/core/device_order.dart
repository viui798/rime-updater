import '../models.dart';

/// 按设置里保存的顺序排列设备；不在顺序表里的设备保持原有先后。
List<Profile> applyDeviceOrder(List<Profile> profiles, List<String> order) {
  if (order.isEmpty) return profiles;
  final ordered = <Profile>[];
  for (final id in order) {
    for (final profile in profiles) {
      if (profile.identity == id && !ordered.contains(profile)) {
        ordered.add(profile);
        break;
      }
    }
  }
  for (final profile in profiles) {
    if (!ordered.contains(profile)) ordered.add(profile);
  }
  return ordered;
}
