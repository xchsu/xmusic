import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'player_controller.dart';
import 'settings.dart';

/// 全局封面玻璃背景：开启「封面颜色(封面透出)」后，首页/音乐库/搜索/设置/播放页等
/// 页面背景透出**当前播放歌曲的封面图片**（玻璃质感、随切歌自动更新）；
/// 未开启时回退手动背景色或主题表面，外观与原先一致。
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
        final song = controller.current;
        final customBg = settings.bgColor != 0
            ? Color(settings.bgColor).withValues(alpha: isDark ? 0.55 : 0.78)
            : null;
        // 当前歌曲封面图片 URL（coverUrl 优先，其次服务器 coverArt；本地 file:// 也可）
        String? coverUrl;
        if (song != null) {
          if ((song.coverUrl ?? '').isNotEmpty) {
            coverUrl = song.coverUrl;
          } else if (song.coverArt != null && song.coverArt!.isNotEmpty) {
            coverUrl = controller.client
                .coverUrl(song.coverArt, size: 600)
                ?.toString();
          }
        }
        final useCover = isCover && (coverUrl != null && coverUrl.isNotEmpty);
        return Stack(
          fit: StackFit.expand,
          children: [
            // 1) 主体：跟随系统主题表面色（浅色近白 / 深色近黑），默认不加额外颜色
            ColoredBox(color: cs.surface),
            // 2) 当前封面：模糊后透明铺底（随切歌自动更新），玻璃质感透出封面图片。
            //    透明度保证封面明显可见（用户反馈 0.20 太淡看起来像纯色）。
            if (useCover)
              Positioned.fill(
                child: Opacity(
                  opacity: 0.38,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: _coverImage(coverUrl!, cs),
                  ),
                ),
              ),
            // 3) 自定义背景色：勾选时以半透明叠在封面之上混合，不默认加色
            if (customBg != null)
              Positioned.fill(child: ColoredBox(color: customBg)),
          ],
        );
      },
    );
  }


  Widget _coverImage(String url, ColorScheme cs) {
    final uri = Uri.tryParse(url);
    if (uri == null) return ColoredBox(color: cs.surface);
    if (uri.scheme == 'file') {
      return Image.file(
        File(uri.toFilePath()),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => ColoredBox(color: cs.surface),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      httpHeaders: const {
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://music.163.com/',
      },
      fadeInDuration: const Duration(milliseconds: 300),
      fadeOutDuration: const Duration(milliseconds: 200),
      placeholder: (_, __) => ColoredBox(color: cs.surfaceContainerHighest),
      errorWidget: (_, __, ___) => ColoredBox(color: cs.surface),
    );
  }
}


/// 页面级背景封装：给 push 出来的独立路由（搜索/歌单/专辑/歌手等）铺上
/// 封面玻璃背景，避免透明 Scaffold 透出黑色路由底层。
class PageBackground extends StatelessWidget {
  const PageBackground({
    super.key,
    required this.controller,
    required this.settings,
    required this.child,
  });
  final PlayerController controller;
  final AppSettings settings;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: CoverGlassBackground(controller: controller, settings: settings),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}
