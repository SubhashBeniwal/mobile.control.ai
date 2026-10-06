import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/remote.dart';
import '../state/app_state.dart';

/// Bottom sheet listing the daemon's windows and displays so the stream can
/// jump to another app. Resolves to the picked [StreamTarget], or null.
Future<StreamTarget?> showWindowSwitcher(
  BuildContext context, {
  required String daemonId,
  required StreamTarget current,
}) {
  return showModalBottomSheet<StreamTarget>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF16181F),
    builder: (_) => _WindowSwitcher(daemonId: daemonId, current: current),
  );
}

class _WindowSwitcher extends StatefulWidget {
  const _WindowSwitcher({required this.daemonId, required this.current});
  final String daemonId;
  final StreamTarget current;

  @override
  State<_WindowSwitcher> createState() => _WindowSwitcherState();
}

class _WindowSwitcherState extends State<_WindowSwitcher> {
  ScreenWindows? _windows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final res = await context.read<AppState>().request(widget.daemonId, 'screen.windows');
    if (!mounted) return;
    setState(() {
      if (res.ok) {
        _windows = ScreenWindows.fromJson(res.data as Map<String, dynamic>? ?? const {});
      } else {
        _error = StreamError.parse(res.error).friendly;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = _windows;
    final targets = <(StreamTarget, IconData, String)>[
      if (w != null)
        for (final win in w.windows.where((x) => x.onScreen))
          (StreamTarget.window(win), Icons.web_asset, win.title.isEmpty ? '' : win.title),
      if (w != null)
        for (final d in w.displays)
          (StreamTarget.display(d), Icons.desktop_mac_outlined, '${d.width}×${d.height}'),
    ];

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Switch to',
                style: TextStyle(
                    color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: w == null && _error == null
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : _error != null
                    ? Center(
                        child: Text(_error!,
                            style: const TextStyle(color: Colors.redAccent)))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                        itemCount: targets.length,
                        itemBuilder: (_, i) {
                          final (t, icon, sub) = targets[i];
                          final active = t.sameAs(widget.current);
                          final name = t.isDisplay
                              ? t.title
                              : t.title.split(' — ').first;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Material(
                              color: active
                                  ? const Color(0xFF2B3350)
                                  : const Color(0xFF20232C),
                              borderRadius: BorderRadius.circular(12),
                              child: ListTile(
                                leading: Icon(icon, color: Colors.white70),
                                title: Text(name,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600)),
                                subtitle: sub.isEmpty
                                    ? null
                                    : Text(sub,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: Colors.white54)),
                                trailing: active
                                    ? const Icon(Icons.cast_connected,
                                        color: Colors.lightBlueAccent)
                                    : null,
                                onTap: () => Navigator.of(context).pop(active ? null : t),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
