import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/remote.dart';
import '../state/app_state.dart';
import 'remote_view_screen.dart';
import 'repo_picker.dart';

/// Remote apps tab: checks `stream.config`, lists streamable windows and
/// displays (`screen.windows`), launches apps (`app.list` / `app.launch`), and
/// opens a [RemoteViewScreen] for the picked target.
class RemoteAppsTab extends StatefulWidget {
  const RemoteAppsTab({super.key, required this.daemonId});

  final String daemonId;

  @override
  State<RemoteAppsTab> createState() => _RemoteAppsTabState();
}

class _RemoteAppsTabState extends State<RemoteAppsTab>
    with AutomaticKeepAliveClientMixin {
  StreamConfig? _config;
  ScreenWindows? _windows;
  StreamError? _error;
  bool _loading = true;
  Timer? _pollTimer;

  @override
  bool get wantKeepAlive => true;

  AppState get _app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await _app.request(widget.daemonId, 'stream.config');
    if (!mounted) return;
    if (!res.ok) {
      setState(() {
        _loading = false;
        _error = StreamError.parse(res.error);
      });
      return;
    }
    final cfg = StreamConfig.fromJson(res.data as Map<String, dynamic>? ?? const {});
    setState(() => _config = cfg);
    if (cfg.supported && cfg.screenRecording) {
      await _refreshWindows();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refreshWindows() async {
    final res = await _app.request(widget.daemonId, 'screen.windows');
    if (!mounted) return;
    setState(() {
      if (res.ok) {
        _windows = ScreenWindows.fromJson(res.data as Map<String, dynamic>? ?? const {});
        _error = null;
      } else {
        _error = StreamError.parse(res.error);
      }
    });
  }

  Future<void> _open(StreamTarget target) async {
    final cfg = _config;
    if (cfg == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RemoteViewScreen(
        daemonId: widget.daemonId,
        config: cfg,
        target: target,
      ),
    ));
    // Windows may have closed or moved while streaming.
    if (mounted) _refreshWindows();
  }

  Future<void> _launch() async {
    final pick = await showModalBottomSheet<_LaunchPick>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _LaunchSheet(daemonId: widget.daemonId),
    );
    if (pick == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final res = await _app.request(widget.daemonId, 'app.launch', args: {
      'path': pick.app.path,
      if (pick.folder != null) 'args': [pick.folder],
    });
    if (!mounted) return;
    if (!res.ok) {
      messenger.showSnackBar(
          SnackBar(content: Text(StreamError.parse(res.error).friendly)));
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text('Launched ${pick.app.name}')));

    // Windows can take a few seconds to appear: poll a few times.
    _pollTimer?.cancel();
    var ticks = 0;
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (t) {
      if (++ticks >= 4 || !mounted) t.cancel();
      if (mounted) _refreshWindows();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cfg = _config;

    if (_loading && cfg == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (cfg != null && !cfg.supported ||
        _error?.code == StreamErrorCode.unsupported) {
      return _Message(
        icon: Icons.desktop_access_disabled,
        title: 'Streaming isn\'t available',
        text: 'This daemon\'s OS or build can\'t stream apps. In v1 that needs '
            'the macOS desktop app.',
      );
    }

    if (cfg != null && !cfg.screenRecording ||
        _error?.code == StreamErrorCode.permissionScreen) {
      return _Message(
        icon: Icons.screen_lock_portrait_outlined,
        title: 'Screen Recording needed',
        text: 'On the Mac, approve AIO Agent under System Settings → Privacy & '
            'Security → Screen Recording, then restart the app there.',
        onRetry: _load,
      );
    }

    if (cfg == null) {
      return _Message(
        icon: Icons.error_outline,
        title: 'Couldn\'t load stream settings',
        text: _error?.friendly ?? 'Unknown error',
        onRetry: _load,
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final windows = [...?_windows?.windows]
      ..sort((a, b) => a.onScreen == b.onScreen ? 0 : (a.onScreen ? -1 : 1));
    final displays = _windows?.displays ?? const <RemoteDisplay>[];
    final live = context.select<AppState, int>((s) => s.liveStreams(widget.daemonId));

    return RefreshIndicator(
      onRefresh: _refreshWindows,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          if (!cfg.accessibility)
            const _Notice(
              icon: Icons.touch_app_outlined,
              text: 'Accessibility isn\'t granted on the Mac, so you can watch but '
                  'not control. Approve AIO Agent under System Settings → Privacy '
                  '& Security → Accessibility.',
            ),
          if (live > 0)
            _Notice(
              icon: Icons.fiber_manual_record,
              color: Colors.red,
              text: '$live live stream${live == 1 ? '' : 's'} on this Mac.',
            ),
          Row(
            children: [
              Expanded(
                child: Text('Windows',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700)),
              ),
              FilledButton.tonalIcon(
                onPressed: _launch,
                icon: const Icon(Icons.rocket_launch_outlined, size: 18),
                label: const Text('Launch app'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(_error!.friendly, style: TextStyle(color: scheme.error)),
            ),
          if (_windows == null && _error == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (windows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('No app windows open. Launch an app to start.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          for (final w in windows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _WindowCard(
                window: w,
                onTap: w.onScreen
                    ? () => _open(StreamTarget.window(w))
                    : null,
              ),
            ),
          if (displays.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Displays',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            for (final d in displays)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  child: ListTile(
                    leading: const Icon(Icons.desktop_mac_outlined),
                    title: Text('Display ${d.id}'),
                    subtitle: Text('Entire screen · ${d.width}×${d.height}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(StreamTarget.display(d)),
                  ),
                ),
              ),
          ],
          if (!cfg.hasTurn) ...[
            const SizedBox(height: 12),
            Text(
              'Direct connection only (no TURN relay configured). Streaming may '
              'fail on some cellular networks.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _WindowCard extends StatelessWidget {
  const _WindowCard({required this.window, this.onTap});
  final RemoteWindow window;
  final VoidCallback? onTap;

  IconData get _icon {
    final b = window.bundleId.toLowerCase();
    final a = window.app.toLowerCase();
    if (b.contains('vscode') || a.contains('code') || b.contains('jetbrains') ||
        a.contains('studio') || a.contains('xcode')) {
      return Icons.code;
    }
    if (a.contains('brave') || a.contains('chrome') || a.contains('safari') ||
        a.contains('firefox') || a.contains('arc')) {
      return Icons.public;
    }
    if (a.contains('terminal') || a.contains('iterm') || a.contains('warp')) {
      return Icons.terminal;
    }
    return Icons.web_asset;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: (enabled ? scheme.primary : scheme.outline)
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(_icon, color: enabled ? scheme.primary : scheme.outline),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(window.app,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    if (window.title.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(window.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5, color: scheme.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      enabled
                          ? '${window.width}×${window.height}'
                          : 'Minimized — restore it on the Mac to stream',
                      style: TextStyle(fontSize: 11.5, color: scheme.outline),
                    ),
                  ],
                ),
              ),
              Icon(enabled ? Icons.cast : Icons.minimize, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}

class _LaunchPick {
  const _LaunchPick(this.app, this.folder);
  final RemoteApp app;
  final String? folder;
}

/// Searchable `app.list` picker; IDEs and browsers pinned at the top. Each
/// app can optionally be opened with a project folder from the workspaces.
class _LaunchSheet extends StatefulWidget {
  const _LaunchSheet({required this.daemonId});
  final String daemonId;

  @override
  State<_LaunchSheet> createState() => _LaunchSheetState();
}

class _LaunchSheetState extends State<_LaunchSheet> {
  List<RemoteApp>? _apps;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final res = await context.read<AppState>().request(widget.daemonId, 'app.list');
    if (!mounted) return;
    setState(() {
      if (res.ok) {
        _apps = RemoteApp.listFrom(res.data);
      } else {
        _error = StreamError.parse(res.error).friendly;
      }
    });
  }

  Future<void> _withFolder(RemoteApp app) async {
    final folder = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => RepoPickerScreen(
        daemonId: widget.daemonId,
        title: 'Open in ${app.name}',
        subtitle: 'Pick a project to open',
        icon: Icons.folder_open,
        onOpen: (ctx, repo) => Navigator.of(ctx).pop(repo),
      ),
    ));
    if (folder != null && mounted) Navigator.of(context).pop(_LaunchPick(app, folder));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _query.toLowerCase();
    final apps = (_apps ?? const <RemoteApp>[])
        .where((a) => q.isEmpty || a.name.toLowerCase().contains(q))
        .toList();

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search apps',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: _apps == null && _error == null
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!, style: TextStyle(color: scheme.error)),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                        itemCount: apps.length,
                        itemBuilder: (_, i) {
                          final app = apps[i];
                          return ListTile(
                            leading: Icon(app.isPinned ? Icons.push_pin : Icons.apps,
                                color: app.isPinned ? scheme.primary : scheme.outline),
                            title: Text(app.name),
                            subtitle: Text(app.path,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: IconButton(
                              tooltip: 'Open a project',
                              icon: const Icon(Icons.folder_open),
                              onPressed: () => _withFolder(app),
                            ),
                            onTap: () => Navigator.of(context).pop(_LaunchPick(app, null)),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.color});
  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.tertiary;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.text,
    this.onRetry,
  });
  final IconData icon;
  final String title;
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: scheme.outline),
            const SizedBox(height: 14),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              FilledButton.tonal(onPressed: onRetry, child: const Text('Check again')),
            ],
          ],
        ),
      ),
    );
  }
}
