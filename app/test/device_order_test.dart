import 'package:flutter_test/flutter_test.dart';
import 'package:rime_updater/core/device_order.dart';
import 'package:rime_updater/models.dart';

void main() {
  test('按保存的顺序排列，未知设备保持原有先后', () {
    const a = Profile(label: 'A', path: '/a', kind: 'unknown');
    const b = Profile(label: 'B', path: '/b', kind: 'squirrel');
    const c = Profile(label: 'C', path: '/c', kind: 'unknown');

    final ordered = applyDeviceOrder([a, b, c], ['/c', '/a']);
    expect(ordered.map((item) => item.path).toList(), ['/c', '/a', '/b']);
  });

  test('没有保存顺序时原样返回', () {
    const list = [
      Profile(label: 'A', path: '/a', kind: 'unknown'),
      Profile(label: 'B', path: '/b', kind: 'unknown'),
    ];
    expect(applyDeviceOrder(list, const []), list);
  });
}
