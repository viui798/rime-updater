import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 弹窗宽度：桌面保持设计宽度，手机屏幕窄时自动收缩。
double dialogWidth(BuildContext context, double max) {
  final width = MediaQuery.sizeOf(context).width - 64;
  return math.max(240, math.min(max, width));
}

/// 弹窗高度：手机屏幕上避免超出可用高度。
double dialogHeight(BuildContext context, double max) {
  final height = MediaQuery.sizeOf(context).height - 140;
  return math.max(180, math.min(max, height));
}
