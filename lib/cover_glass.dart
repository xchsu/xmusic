import 'dart:io';

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
            // 1) 封面图片铺底（透出封面，切歌自动换图）；关闭时用自定义背景色/主题表面
            if (useCover)
              _coverImage(coverUrl!, cs)
            else
              ColoredBox(color: customBg ?? cs.surface),
            // 2) 玻璃洗色层：主题色半透明 + 上下渐变（浅色更透、深色沉稳），
            //    做出“玻璃透出封面”的质感，同时保证文字可读。
            DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surface.withValues(
                    alpha: isDark ? (useCover ? 0.35 : 0.50) : (useCover ? 0.16 : 0.36)),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    cs.primary.withValues(alpha: useCover ? 0.10 : 0.14),
                    Colors.transparent,
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
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
