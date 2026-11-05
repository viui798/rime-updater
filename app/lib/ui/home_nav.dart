import 'package:flutter/material.dart';

/// 底部导航的一项。
class HomeNavItem {
  const HomeNavItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// 悬浮式底部导航：选中项是一枚会**横向滑动**的胶囊，滑动过程中
/// 文字随之切换；未选中项只显示图标。
///
/// 配色跟随主题（雾白 + 淡紫），不再用与整体割裂的纯黑底。
class HomeNavBar extends StatelessWidget {
  const HomeNavBar({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
  });

  final List<HomeNavItem> items;
  final int index;
  final ValueChanged<int> onChanged;

  static const _slide = Duration(milliseconds: 280);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = items.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: SizedBox(
          height: 44,
          child: Stack(
            children: [
              // 滑动的胶囊：宽度恒为一个槽位，靠 alignment 在槽位间平移。
              AnimatedAlign(
                duration: _slide,
                curve: Curves.easeOutCubic,
                alignment: count <= 1
                    ? Alignment.center
                    : Alignment(-1 + 2 * index / (count - 1), 0),
                child: FractionallySizedBox(
                  widthFactor: 1 / count,
                  heightFactor: 1,
                  child: DecoratedBox(
                    key: const ValueKey('home-nav-pill'),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < count; i++)
                    Expanded(
                      child: _NavSlot(
                        key: ValueKey('home-nav-${items[i].label}'),
                        item: items[i],
                        active: i == index,
                        onTap: () => onChanged(i),
                        slide: _slide,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavSlot extends StatelessWidget {
  const _NavSlot({
    super.key,
    required this.item,
    required this.active,
    required this.onTap,
    required this.slide,
  });

  final HomeNavItem item;
  final bool active;
  final VoidCallback onTap;
  final Duration slide;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = active ? scheme.onPrimary : scheme.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: active,
      label: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: slide,
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(item.icon, size: 20, color: foreground),
              // 文字与胶囊同步出现：用宽度和透明度过渡，避免生硬跳变。
              // 窄屏时槽位放不下就省略，不能溢出。
              Flexible(
                child: AnimatedSize(
                  duration: slide,
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    duration: slide,
                    opacity: active ? 1 : 0,
                    child: active
                        ? Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(
                              item.label,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: foreground,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
