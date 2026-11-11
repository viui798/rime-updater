import 'package:flutter/material.dart';

/// 行内容向左滑动后露出一个操作按钮（默认「删除」），点按钮才真正执行。
///
/// 直接用 [Dismissible] 会在滑到底时立刻触发删除，误触代价太大；
/// 这里只负责「滑开 / 收起」，执行交给用户再点一次。
class SwipeActionRow extends StatefulWidget {
  const SwipeActionRow({
    super.key,
    required this.child,
    required this.onAction,
    this.label = '删除',
    this.icon = Icons.delete_outline,
    this.background,
    this.enabled = true,
    this.actionWidth = 88,
  });

  final Widget child;
  final Future<void> Function() onAction;
  final String label;
  final IconData icon;

  /// 行内容的底色（不透明），否则滑开时会透出下面的红色按钮。
  final Color? background;
  final bool enabled;
  final double actionWidth;

  @override
  State<SwipeActionRow> createState() => _SwipeActionRowState();
}

class _SwipeActionRowState extends State<SwipeActionRow> {
  double _offset = 0;
  bool _dragging = false;

  bool get _open => _offset < -1;

  void _close() => setState(() => _offset = 0);

  void _onDragStart(DragStartDetails _) {
    if (!widget.enabled) return;
    setState(() => _dragging = true);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!widget.enabled) return;
    setState(() {
      _offset = (_offset + details.delta.dx).clamp(-widget.actionWidth, 0.0);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (!widget.enabled) return;
    final velocity = details.primaryVelocity ?? 0;
    // 快速滑动按方向判断（左滑展开、右滑收回），慢速则看是否过半。
    final shouldOpen = velocity < -250 ||
        (velocity >= 0 && _offset < -widget.actionWidth * .5);
    setState(() {
      _dragging = false;
      _offset = shouldOpen ? -widget.actionWidth : 0;
    });
  }

  Future<void> _run() async {
    _close();
    await widget.onAction();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = widget.background ?? theme.colorScheme.surface;
    // 拖动监听包住整行：滑开后手指落在任意位置向右滑都能收回，
    // 而不是只有行内容区域可拖（操作按钮与遮罩都会挡住内容区）。
    return GestureDetector(
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: Stack(
        children: [
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: widget.actionWidth,
                child: Material(
                  color: theme.colorScheme.error,
                  child: InkWell(
                    onTap: widget.enabled && _open ? _run : null,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(widget.icon,
                            size: 18, color: theme.colorScheme.onError),
                        const SizedBox(height: 3),
                        Text(
                          widget.label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onError,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          AnimatedContainer(
            duration:
                _dragging ? Duration.zero : const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(_offset, 0, 0),
            child: Container(color: background, child: widget.child),
          ),
          if (_open)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              right: widget.actionWidth,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }
}
