import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cover_glass.dart';
import '../external_api.dart';
import '../player_controller.dart';
import '../settings.dart';
import '../subsonic.dart';
import '../widgets.dart';
import 'mini_player.dart';
import 'player_page.dart';
import 'search_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.settings, required this.controller});

  final AppSettings settings;
  final PlayerController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Future<List<Map<String, dynamic>>> _toplists;
  late Future<List<Song>> _daily30;
  late Future<List<Song>> _localRec;
  late Future<List<Map<String, dynamic>>> _qqPlaylists;

  SubsonicClient get _client => widget.controller.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final ext = widget.controller.external;
    // 真实排行榜：网易云 + （有QQ cookie时）QQ 榜单
    _toplists = _loadToplists();
    // 每日30首：飙升榜/新歌榜/原创榜 各取前10去重（避开热歌榜，避免与下方排行榜网格重复）
    _daily30 = _loadDaily30();
    // QQ 精选歌单（硬编码 dissid，本地列表零网络请求；点进去才拉歌曲）
    _qqPlaylists = ext.qqPlaylists();
    // 本地推荐
    _localRec = _dailyLocalRec();
  }

  /// 排行榜：网易云榜单 + QQ 热榜/新歌榜/飙升榜/流行指数榜混排（网易云前8 + QQ前4）。
  /// [xmusic] 2026-09-24 修复：QQ 榜单数据接口匿名可用（fcg_v8_toplist_cp），
  /// 不再依赖 QQ cookie 才显示——车机/未填 cookie 也能看到 QQ 四大榜；
  /// 有 cookie 时点进榜单走 QQ 音源播放，无 cookie 时由播放链网易云/酷我兜底。
  Future<List<Map<String, dynamic>>> _loadToplists() async {
    final ext = widget.controller.external;
    var lists = await ext
        .getToplists()
        .timeout(const Duration(seconds: 15))
        .catchError((_) => <Map<String, dynamic>>[]);
    final qq = await ext
        .qqToplists()
        .timeout(const Duration(seconds: 15))
        .catchError((_) => <Map<String, dynamic>>[]);
    if (qq.isNotEmpty) {
      lists = [...lists, ...qq.map((m) => {...m, 'source': 'qq'})];
    }
    return lists;
  }

  /// 每日30首：设置了 QQ cookie 用 QQ 热歌榜（播放走 QQ）；否则酷狗TOP500 → 网易云匹配播放。
  Future<List<Song>> _loadDaily30() async {
    final ext = widget.controller.external;
    final cookie = widget.settings.qqCookie;
    if (cookie.trim().isNotEmpty) {
      final qq = await ext.daily30FromQq(cookie: cookie);
      if (qq.isNotEmpty) return qq;
    }
    return ext.daily30FromKugou();
  }

  /// 本地推荐：类似"每日30首"——按日期播种 + 当天缓存，每天变化（同日内稳定）。
  DateTime _localRecDay = DateTime(2000);
  List<Song> _localRecCached = const [];
  Future<List<Song>> _dailyLocalRec() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (_localRecDay == today && _localRecCached.isNotEmpty) return _localRecCached;
    final pool = await _client.randomSongs(size: 60).catchError((_) => <Song>[]);
    pool.shuffle(Random(today.year * 10000 + today.month * 100 + today.day));
    final picked = pool.take(30).toList();
    _localRecDay = today;
    _localRecCached = picked;
    return picked;
  }

  Future<void> _reload() async {
    _load();
    await Future.wait([_toplists, _daily30, _qqPlaylists]);
  }

  Future<void> _playSongs(List<Song> songs, int index) async {
    await widget.controller.playQueue(songs, index);
    if (mounted) setState(() {});
    if (context.mounted) {
      await openPlayerPage(context, settings: widget.settings, controller: widget.controller);
    }
  }

  Future<void> _openPlaylist(String name, String playlistId,
      {String? coverUrl, List<Song>? songs}) async {
    // 已有数据（如热歌榜大卡片首页已加载）：直接进详情页，秒开不转圈、不再二次请求
    if (songs != null) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _PlaylistDetail(
          title: name,
          songs: songs,
          client: _client,
          settings: widget.settings,
          controller: widget.controller,
          coverUrl: coverUrl,
          onPlay: (i) => _playSongs(songs, i),
        ),
      ));
      return;
    }
    final ext = widget.controller.external;
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    List<Song> fetched;
    String? error;
    try {
      fetched = await ext.getPlaylistSongs(playlistId).timeout(const Duration(seconds: 20));
    } catch (e) {
      fetched = const [];
      error = '加载失败（$e）';
    }
    if (fetched.isEmpty && error == null) error = '没有歌曲数据';
    if (!mounted) return;
    Navigator.pop(context); // dismiss loading
    // 无论成败都进入详情页：失败显示原因+重试，绝不空白页或无声返回
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PlaylistDetail(
        title: name,
        songs: fetched,
        client: _client,
        settings: widget.settings,
        controller: widget.controller,
        coverUrl: coverUrl,
        error: error,
        onRetry: () => _openPlaylist(name, playlistId, coverUrl: coverUrl),
        onPlay: (i) => _playSongs(fetched, i),
      ),
    ));
  }

  /// QQ 榜单详情：拉 QQ 榜单歌曲（songmid），进列表页，播放走 QQ（带 cookie）。
  Future<void> _openQqToplist(String name, String id, String? coverUrl) async {
    final ext = widget.controller.external;
    final cookie = widget.settings.qqCookie;
    final songs = await ext.qqToplistSongs(id, cookie: cookie, limit: 50);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PlaylistDetail(
        title: name,
        songs: songs,
        client: _client,
        settings: widget.settings,
        controller: widget.controller,
        coverUrl: coverUrl,
        onPlay: (i) => _playSongs(songs, i),
      ),
    ));
  }

  /// QQ 精选歌单详情：qzone 老接口拉歌曲（songmid），进列表页，播放走 QQ→网易云/酷我兜底。
  Future<void> _openQqPlaylist(String name, String dissid) async {
    final ext = widget.controller.external;
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    List<Song> songs;
    String? error;
    try {
      songs = await ext.qqPlaylistSongs(dissid, limit: 100).timeout(const Duration(seconds: 20));
    } catch (e) {
      songs = const [];
      error = '加载失败（$e）';
    }
    if (songs.isEmpty && error == null) error = '没有歌曲数据';
    if (!mounted) return;
    Navigator.pop(context);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PlaylistDetail(
        title: name,
        songs: songs,
        client: _client,
        settings: widget.settings,
        controller: widget.controller,
        error: error,
        onRetry: () => _openQqPlaylist(name, dissid),
        onPlay: (i) => _playSongs(songs, i),
      ),
    ));
  }

  /// 每日30首·本地：每天随机30首本地歌，点卡先进歌单列表页。
  Future<void> _openDailyLocal() async {
    final songs = await _dailyLocalRec();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PlaylistDetail(
        title: '每日30首·本地',
        songs: songs,
        client: _client,
        settings: widget.settings,
        controller: widget.controller,
        onPlay: (i) => _playSongs(songs, i),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return BigScreenText(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('音素'),
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SearchPage(settings: widget.settings, controller: widget.controller),
            )),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            // 每日30首：在线 + 本地 两栏（横屏下整块限宽，避免图片过大）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('每日30首',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
            FutureBuilder<List<Song>>(
              future: _daily30,
              builder: (context, snap) {
                final car = isCarScreen(context);
                final online = snap.hasData ? snap.data! : const <Song>[];
                final card = Row(
                  children: [
                    Expanded(
                      child: _daily30Card(
                        title: '在线',
                        subtitle: online.isNotEmpty ? '${online.length}首 · 飙升/新歌/原创' : '加载中...',
                        icon: Icons.cloud_download_rounded,
                        coverUrl: online.isNotEmpty ? online.first.coverUrl : null,
                        colors: const [Color(0xFF3A6DF0), Color(0xFF5B8CFA)],
                        onTap: online.isNotEmpty
                            ? () => _openPlaylist('每日30首·在线', '', songs: online)
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _daily30Card(
                        title: '本地',
                        subtitle: '每天变化 · 本地随机',
                        icon: Icons.folder_rounded,
                        colors: const [Color(0xFF00A884), Color(0xFF2FB8A0)],
                        onTap: _openDailyLocal,
                      ),
                    ),
                  ],
                );
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: car
                      ? Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: card))
                      : card,
                );
              },
            ),
            // 排行榜网格
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('排行榜',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700)),
            ),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _toplists,
              builder: (context, snap) {
                if (!snap.hasData || snap.data!.isEmpty) {
                  return const Padding(padding: EdgeInsets.all(16), child: Center(child: Text('加载排行榜...')));
                }
                // 网易云前8 + QQ前4
                final ne = snap.data!.where((t) => t['source'] != 'qq').take(8).toList();
                final qq = snap.data!.where((t) => t['source'] == 'qq').take(4).toList();
                final lists = [...ne, ...qq];
                // [xmusic] 2026-09-24 车机横屏参考网易云车机版：一行6个、方形封面+下方标题，
                // 卡片更小不占满整屏；手机仍 3 列。
                final car = isCarScreen(context);
                // [xmusic] 2026-09-28 横屏减小卡片：GridView.extent 自动多列、每图限宽~176
                return GridView.extent(
                  maxCrossAxisExtent: car ? 176 : 118,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  mainAxisSpacing: car ? 12 : 10,
                  crossAxisSpacing: car ? 10 : 10,
                  childAspectRatio: car ? 0.98 : 1.1,
                  children: lists.map((t) => _toplistCard(
                    t['name'] as String,
                    t['id'] as String,
                    t['coverImgUrl'] as String?,
                    source: (t['source'] ?? '') as String,
                  )).toList(),
                );
              },
            ),
            // QQ 精选歌单（用户强烈要求；硬编码 dissid，点进才拉歌曲）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('QQ歌单',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    tooltip: '换一批',
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    onPressed: () {
                      setState(() => _qqPlaylists = widget.controller.external.qqPlaylists());
                    },
                  ),
                ],
              ),
            ),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _qqPlaylists,
              builder: (context, snap) {
                final list = snap.data ?? const [];
                return GridView.extent(
                  maxCrossAxisExtent: isCarScreen(context) ? 176 : 118,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  mainAxisSpacing: isCarScreen(context) ? 12 : 10,
                  crossAxisSpacing: isCarScreen(context) ? 10 : 10,
                  childAspectRatio: isCarScreen(context) ? 0.86 : 0.72,
                  children: list.map((p) => _qqPlaylistCard(
                    p['name'] as String,
                    p['dissid'] as String,
                    p['coverImgUrl'] as String?,
                  )).toList(),
                );
              },
            ),
            // LX 精选（网易云榜单/精选歌单，meting 先行版）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('LX精选',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
            GridView.extent(
              maxCrossAxisExtent: isCarScreen(context) ? 176 : 118,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              mainAxisSpacing: isCarScreen(context) ? 12 : 10,
              crossAxisSpacing: isCarScreen(context) ? 10 : 10,
              childAspectRatio: isCarScreen(context) ? 0.86 : 0.72,
              children: ExternalApi.lxPresets.map((p) => _lxCard(p['name']!, p['id']!, p['coverUrl'] as String?)).toList(),
            ),
                      ],
          ),
      ),
    ));
  }

  /// 每日30首小卡（在线/本地两栏）：渐变底 + 图标 + 标题副标题，点击进对应歌单。
  Widget _daily30Card({
    required String title,
    required String subtitle,
    required IconData icon,
    required List<Color> colors,
    String? coverUrl,
    VoidCallback? onTap,
  }) {
    return Material(
      borderRadius: BorderRadius.circular(14),
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(8)),
                    clipBehavior: Clip.antiAlias,
                    child: (coverUrl != null && coverUrl!.isNotEmpty)
                        ? Image.network(coverUrl!, width: 36, height: 36, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Icon(icon, color: Colors.white, size: 22))
                        : Icon(icon, color: Colors.white, size: 22),
                  ),
                  const Spacer(),
                  const Icon(Icons.play_arrow_rounded, color: Colors.white70),
                ],
              ),
              const SizedBox(height: 10),
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  /// 半宽歌单卡（本地推荐）：渐变底 + 图标 + 标题 + 副标题，点击进歌单页。
  Widget _miniCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required List<Color> colors,
    VoidCallback? onTap,
  }) {
    return Material(
      borderRadius: BorderRadius.circular(14),
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          height: 110,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(
              colors: colors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: Colors.white, size: 30),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toplistCard(String name, String id, String? coverUrl,
      {String source = ''}) {
    // [xmusic] 车机横屏参考网易云车机版：方封面 + 下方标题；手机保持原铺满卡。
    if (isCarScreen(context)) {
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => source == 'qq'
            ? _openQqToplist(name, id, coverUrl)
            : _openPlaylist(name, id, coverUrl: coverUrl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: (coverUrl != null && coverUrl.isNotEmpty)
                    ? CachedNetworkImage(
                        imageUrl: coverUrl,
                        fit: BoxFit.cover,
                        httpHeaders: const {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://music.163.com/'},
                        placeholder: (_, __) => Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
                        errorWidget: (_, __, ___) => Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
                      )
                    : Container(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.all(8),
                        child: Text(name,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 12, fontWeight: FontWeight.w700)),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 13, fontWeight: FontWeight.w500)),
          ],
        ),
      );
    }
    final theme = Theme.of(context);
    return Material(
      borderRadius: BorderRadius.circular(12),
      elevation: 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => source == 'qq'
            ? _openQqToplist(name, id, coverUrl)
            : _openPlaylist(name, id, coverUrl: coverUrl),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (coverUrl != null && coverUrl.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: coverUrl,
                  fit: BoxFit.cover,
                  httpHeaders: const {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://music.163.com/'},
                  placeholder: (_, __) => Container(color: theme.colorScheme.surfaceContainerHighest),
                  errorWidget: (_, __, ___) => Container(color: theme.colorScheme.surfaceContainerHighest),
                )
              else
                // QQ 榜单等无封面：渐变底 + 榜单名文字，不再只显示灰块
                Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    name,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              if (coverUrl != null && coverUrl.isNotEmpty)
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black.withOpacity(0.6)],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
  /// QQ 精选歌单卡：方形圆角封面 + 下方标题（文字放图下完整显示，不叠在图上截断；横竖屏同排布）。
  Widget _qqPlaylistCard(String name, String dissid, String? coverUrl) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _openQqPlaylist(name, dissid),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: (coverUrl != null && coverUrl.isNotEmpty)
                  ? CachedNetworkImage(
                      imageUrl: coverUrl,
                      fit: BoxFit.cover,
                      httpHeaders: const {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://y.qq.com/'},
                      placeholder: (_, __) => Container(color: theme.colorScheme.surfaceContainerHighest),
                      errorWidget: (_, __, ___) => Container(color: theme.colorScheme.surfaceContainerHighest),
                    )
                  : Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      alignment: Alignment.center,
                      child: Icon(Icons.queue_music_rounded, color: theme.colorScheme.onSurfaceVariant),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.onSurface, fontSize: 13, fontWeight: FontWeight.w500, height: 1.25)),
        ],
      ),
    );
  }

  /// LX 精选卡（网易云榜单/精选歌单，meting 先行版）：真实封面(可回退渐变) + 下方标题。
  Widget _lxCard(String name, String id, String? coverUrl) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _openLxPlaylist(name, id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: (coverUrl != null && coverUrl.isNotEmpty)
                  ? CachedNetworkImage(
                      imageUrl: coverUrl,
                      fit: BoxFit.cover,
                      httpHeaders: const {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://music.163.com/'},
                      placeholder: (_, __) => Container(color: theme.colorScheme.surfaceContainerHighest),
                      errorWidget: (_, __, ___) => Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft, end: Alignment.bottomRight,
                            colors: [Color(0xFF1F2733), Color(0xFF3A4A5F)],
                          ),
                        ),
                        child: const Icon(Icons.album_rounded, color: Colors.white70, size: 34),
                      ),
                    )
                  : Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft, end: Alignment.bottomRight,
                          colors: [Color(0xFF1F2733), Color(0xFF3A4A5F)],
                        ),
                      ),
                      child: const Icon(Icons.album_rounded, color: Colors.white70, size: 34),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.onSurface, fontSize: 13, fontWeight: FontWeight.w500, height: 1.25)),
        ],
      ),
    );
  }

  /// LX 精选歌单/榜单详情：meting 拉歌曲（已带直链），进列表页直接播放。
  Future<void> _openLxPlaylist(String name, String id) async {
    final ext = widget.controller.external;
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    List<Song> songs;
    String? error;
    try {
      songs = await ext.lxMetingPlaylistSongs(id).timeout(const Duration(seconds: 20));
    } catch (e) {
      songs = const [];
      error = '加载失败（$e）';
    }
    if (songs.isEmpty && error == null) error = '没有歌曲数据';
    if (!mounted) return;
    Navigator.pop(context);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PlaylistDetail(
        title: name,
        songs: songs,
        client: _client,
        settings: widget.settings,
        controller: widget.controller,
        error: error,
        onRetry: () => _openLxPlaylist(name, id),
        onPlay: (i) => _playSongs(songs, i),
      ),
    ));
  }

}

/// 歌单详情页（支持左滑删除歌曲，移除记录按歌单名本地持久化）
class _PlaylistDetail extends StatefulWidget {
  const _PlaylistDetail({
    required this.title,
    required this.songs,
    required this.client,
    required this.settings,
    required this.controller,
    required this.onPlay,
    this.coverUrl,
    this.error,
    this.onRetry,
  });

  final String title;
  final List<Song> songs;
  final SubsonicClient client;
  final AppSettings settings;
  final PlayerController controller;
  final void Function(int index) onPlay;
  final String? coverUrl;
  final String? error;
  final VoidCallback? onRetry;

  @override
  State<_PlaylistDetail> createState() => _PlaylistDetailState();
}

class _PlaylistDetailState extends State<_PlaylistDetail> {
  Set<String> _removed = <String>{};

  @override
  void initState() {
    super.initState();
    _loadRemoved();
  }

  Future<void> _loadRemoved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'playlist_removed_${widget.title}';
      final list = prefs.getStringList(key) ?? const <String>[];
      if (!mounted) return;
      setState(() => _removed = list.toSet());
    } catch (_) {}
  }

  Future<void> _removeSong(Song song) async {
    setState(() => _removed = {..._removed, song.id});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          'playlist_removed_${widget.title}', _removed.toList());
    } catch (_) {}
  }

  /// 未被移除的歌曲在原始列表中的索引（onPlay 需要原始索引）
  List<int> get _visibleIndices {
    final out = <int>[];
    for (var i = 0; i < widget.songs.length; i++) {
      if (!_removed.contains(widget.songs[i].id)) out.add(i);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    final songs = widget.songs;
    final client = widget.client;
    final settings = widget.settings;
    final controller = widget.controller;
    final onPlay = widget.onPlay;
    final coverUrl = widget.coverUrl;
    final error = widget.error;
    final onRetry = widget.onRetry;
    return PageBackground(
        controller: widget.controller,
        settings: widget.settings,
        child: BigScreenText(
        child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          Expanded(
            child: Column(
              children: [
                if (coverUrl != null && coverUrl!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CachedNetworkImage(
                      imageUrl: coverUrl!,
                      width: 80, height: 80, fit: BoxFit.cover,
                      httpHeaders: const {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://music.163.com/'},
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text('共 ${_visibleIndices.length} 首', style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _visibleIndices.isEmpty || error != null ? null : () => onPlay(0),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('播放全部'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _visibleIndices.isEmpty || error != null ? null : () {
                    songs.shuffle();
                    onPlay(0);
                  },
                  icon: const Icon(Icons.shuffle_rounded),
                  label: const Text('随机'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_rounded, size: 40),
                      const SizedBox(height: 8),
                      Text(error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      if (onRetry != null)
                        FilledButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('重试'),
                        ),
                    ],
                  ),
                )
              : _visibleIndices.isEmpty
                ? const Center(child: Text('已全部移除'))
                : ListView.builder(
                    itemCount: _visibleIndices.length,
                    itemBuilder: (context, k) {
                      final i = _visibleIndices[k];
                      final song = songs[i];
                      return Dismissible(
                        key: ValueKey('pl_${title}_${song.id}'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          color: Theme.of(context).colorScheme.error,
                          child: const Icon(Icons.delete_outline_rounded,
                              color: Colors.white),
                        ),
                        onDismissed: (_) => _removeSong(song),
                        child: SongTile(
                          song: song,
                          client: client,
                          onTap: () => onPlay(i),
                        ),
                      );
                    },
                  ),
              ),
            ],
          ),
        ),
        // 迷你播放条放 body 底部而不是 bottomNavigationBar：
        // 避免个别设备上 bottomNavigationBar 槽位把迷你条撑满全屏、挤没列表（0.2.x 修复回归）
        MiniPlayer(settings: settings, controller: controller),
      ],
      )),
    ));
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.song, required this.client, required this.onTap});
  final Song song;
  final SubsonicClient client;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 130,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(children: [
              CoverImage(client: client, coverId: song.coverArt, coverUrl: song.coverUrl, size: 130, radius: 12, requestSize: 360),
              Positioned(right: 4, bottom: 4, child: Icon(Icons.play_circle_fill_rounded, size: 28, color: Colors.white.withOpacity(0.9))),
            ]),
            const SizedBox(height: 6),
            Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
            Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
