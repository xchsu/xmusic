import 'package:flutter/material.dart';

import 'player_controller.dart';
import 'settings.dart';

/// 全局封面玻璃背景：开启「封面颜色」后，首页/音乐库/搜索/设置等页面背景
/// 透出当前播放歌曲封面主色（玻璃质感、随切歌自动更新）；未开启时回退
/// 手动背景色或主题表面，外观与原先一致。
class CoverGlassBackground extends StatelessWidget {
  const CoverGlassBackground({super.key, required this.controller, required this.settings});

  final PlayerController controller;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, settings]),
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final isCover = settings.coverColorBg;
        final tint = (isCover && controller.coverTint != null)
            ? controller.coverTint!
            : cs.primary;
        final customBg = settings.bgColor != 0
            ? Color(settings.bgColor).withValues(alpha: isDark ? 0.55 : 0.78)
            : null;
        return ColoredBox(
          color: isCover ? tint : (customBg ?? cs.surface),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.surface.withValues(
                  alpha: isDark ? (isCover ? 0.45 : 0.50) : (isCover ? 0.30 : 0.36)),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  tint.withValues(alpha: 0.14),
                  Colors.transparent,
                  tint.withValues(alpha: 0.09),
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
        );
      },
    );
  }
}
