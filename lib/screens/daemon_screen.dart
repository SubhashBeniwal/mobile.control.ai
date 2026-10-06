import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../actions/action_spec.dart';
import '../models/command.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../util/format.dart';
import '../widgets/connection_badge.dart';
import 'command_screen.dart';
import 'dispatch_sheet.dart';
import 'file_browser.dart';
import 'file_viewer_screen.dart';
import 'git_screen.dart';
import 'pr_screen.dart';
import 'remote_apps_screen.dart';
import 'system_screen.dart';
import 'terminal_screen.dart';

/// Detail for one daemon: capabilities, dispatchable actions, and this
/// daemon's command history.
class DaemonScreen extends StatelessWidget {
  const DaemonScreen({super.key, required this.daemonId});

  final String daemonId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final daemon = state.daemons.where((d) => d.id == daemonId).firstOrNull;
    if (daemon == null) {
      return const Scaffold(body: Center(child: Text('Daemon not found')));
    }

    final actions = ActionSpec.catalog
        .where((s) => daemon.supports(s.action))
        .toList(growable: false);
    final history = state.commandsFor(daemonId);
    final hasShell = daemon.supports('deploy');

    // Build tabs in order, tracking the System tab's index for its polling.
    final tabs = <Tab>[];
    final views = <Widget>[];
    var index = 0;
    if (hasShell) {
      final systemIndex = index++;
      tabs.add(const Tab(text: 'System', icon: Icon(Icons.speed)));
      views.add(SystemScreen(daemonId: daemonId, tabIndex: systemIndex));
    }
    tabs.add(const Tab(text: 'Actions', icon: Icon(Icons.bolt)));
    views.add(_ActionsTab(daemonId: daemonId, actions: actions, online: daemon.online));
    index++;
    if (hasShell) {
      tabs.add(const Tab(text: 'Terminal', icon: Icon(Icons.terminal)));
      views.add(TerminalScreen(daemonId: daemonId));
      index++;
    }
    // Remote apps only for daemons that advertise `stream.start`.
    if (daemon.supportsStreaming) {
      final live = state.liveStreams(daemonId) > 0;
      tabs.add(Tab(
        text: 'Remote',
        icon: Icon(live ? Icons.cast_connected : Icons.cast,
            color: live ? Colors.red : null),
      ));
      views.add(RemoteAppsTab(daemonId: daemonId));
      index++;
    }
    tabs.add(const Tab(text: 'History', icon: Icon(Icons.history)));
    views.add(_HistoryTab(history: history));

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(daemon.name, overflow: TextOverflow.ellipsis),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(child: ConnectionBadge(state: state.connection)),
            ),
          ],
          bottom: TabBar(isScrollable: true, tabs: tabs),
        ),
        body: TabBarView(children: views),
      ),
    );
  }
}

/// A short, human summary of a run's key argument (shown in history rows).
String runSummary(CommandRun run) {
  final a = run.args;
  switch (run.action) {
    case 'deploy':
      return (a['command'] ?? '').toString();
    case 'git':
      final args = (a['args'] as List?)?.join(' ') ?? '';
      return 'git $args'.trim();
    case 'file.read':
    case 'file.write':
    case 'file.list':
      return (a['path'] ?? '').toString();
    case 'agent.run':
      final p = (a['prompt'] ?? '').toString();
      return p.length > 60 ? '${p.substring(0, 60)}…' : p;
    case 'pr.review':
      return 'PR #${a['number']}';
    case 'app.launch':
      return (a['name'] ?? a['path'] ?? '').toString();
    default:
      return '';
  }
}

void _openCommand(BuildContext context, CommandRun run) {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => CommandScreen(commandId: run.id)),
  );
}

// ---------------------------------------------------------------------------
// Actions tab — categorized, colorful, quick-run aware.
// ---------------------------------------------------------------------------

class _ActionsTab extends StatelessWidget {
  const _ActionsTab({
    required this.daemonId,
    required this.actions,
    required this.online,
  });

  final String daemonId;
  final List<ActionSpec> actions;
  final bool online;

  Future<void> _dispatch(BuildContext context, ActionSpec spec) async {
    final state = context.read<AppState>();
    final daemon = state.daemons.where((d) => d.id == daemonId).firstOrNull;
    if (daemon == null) return;

    // Rich, interactive experiences replace the plain argument form for these.
    switch (spec.action) {
      case 'file.list':
        _push(context, FileBrowserScreen(daemonId: daemonId, title: 'Directory tree'));
        return;
      case 'file.read':
        _push(context,
            FileBrowserScreen(daemonId: daemonId, mode: BrowserMode.browse, title: 'Open a file'));
        return;
      case 'file.write':
        _openWriteFlow(context);
        return;
      case 'git':
        openGit(context, daemonId);
        return;
      case 'pr.review':
        openPr(context, daemonId);
        return;
    }

    Map<String, dynamic> args = const {};
    if (!spec.isQuickRun) {
      final result = await showDispatchSheet(context, spec: spec, daemon: daemon);
      if (result == null) return; // cancelled
      args = result;
    }

    if (!context.mounted) return;
    final run = state.dispatch(daemonId: daemonId, action: spec.action, args: args);
    if (run == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected — command not sent')),
      );
      return;
    }
    _openCommand(context, run);
  }

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  /// Write flow: search/pick (or create) a file, then open it in the editor.
  Future<void> _openWriteFlow(BuildContext context) async {
    final path = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => FileBrowserScreen(
        daemonId: daemonId,
        mode: BrowserMode.pickFile,
        title: 'Choose a file to edit',
        allowCreate: true,
      ),
    ));
    if (path == null || !context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FileViewerScreen(daemonId: daemonId, path: path, startInEdit: true),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Preserve catalog order within each category grouping.
    final byCategory = <ActionCategory, List<ActionSpec>>{};
    for (final s in actions) {
      byCategory.putIfAbsent(s.category, () => []).add(s);
    }
    final categories =
        ActionCategory.values.where(byCategory.containsKey).toList();

    return Column(
      children: [
        if (!online) const _OfflineBanner(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              for (final cat in categories) ...[
                _CategoryHeader(category: cat, count: byCategory[cat]!.length),
                const SizedBox(height: 8),
                for (final spec in byCategory[cat]!)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ActionCard(spec: spec, onTap: () => _dispatch(context, spec)),
                  ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({required this.category, required this.count});
  final ActionCategory category;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: category.color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            category.label.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.spec, required this.onTap});
  final ActionSpec spec;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = spec.category.color;
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
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(spec.icon, color: accent, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(spec.title,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(spec.description,
                        style: TextStyle(
                            fontSize: 12.5, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (spec.isQuickRun)
                _Tag(text: 'RUN', icon: Icons.play_arrow_rounded, color: accent)
              else
                Icon(Icons.tune, size: 18, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.icon, required this.color});
  final String text;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 2),
          Text(text,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Daemon is offline — commands will fail until it reconnects.',
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// History tab — filterable, rich rows with status, timing, and summaries.
// ---------------------------------------------------------------------------

enum _HistoryFilter { all, active, done, failed }

class _HistoryTab extends StatefulWidget {
  const _HistoryTab({required this.history});
  final List<CommandRun> history;

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  _HistoryFilter _filter = _HistoryFilter.all;

  bool _matches(CommandRun run) => switch (_filter) {
        _HistoryFilter.all => true,
        _HistoryFilter.active => run.isActive,
        _HistoryFilter.done => run.status == CommandStatus.done,
        _HistoryFilter.failed => run.status == CommandStatus.error,
      };

  @override
  Widget build(BuildContext context) {
    final all = widget.history;
    if (all.isEmpty) {
      return _EmptyHistory();
    }

    final counts = {
      _HistoryFilter.all: all.length,
      _HistoryFilter.active: all.where((r) => r.isActive).length,
      _HistoryFilter.done: all.where((r) => r.status == CommandStatus.done).length,
      _HistoryFilter.failed: all.where((r) => r.status == CommandStatus.error).length,
    };
    final items = all.where(_matches).toList();

    return Column(
      children: [
        _FilterBar(
          filter: _filter,
          counts: counts,
          onChanged: (f) => setState(() => _filter = f),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text('Nothing here',
                      style: Theme.of(context).textTheme.bodyMedium))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _HistoryRow(run: items[i]),
                ),
        ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filter,
    required this.counts,
    required this.onChanged,
  });
  final _HistoryFilter filter;
  final Map<_HistoryFilter, int> counts;
  final ValueChanged<_HistoryFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    const labels = {
      _HistoryFilter.all: 'All',
      _HistoryFilter.active: 'Active',
      _HistoryFilter.done: 'Done',
      _HistoryFilter.failed: 'Failed',
    };
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (final f in _HistoryFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                selected: filter == f,
                label: Text('${labels[f]} ${counts[f]}'),
                onSelected: (_) => onChanged(f),
              ),
            ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.run});
  final CommandRun run;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, icon) = switch (run.status) {
      CommandStatus.pending => (Colors.grey, Icons.hourglass_empty),
      CommandStatus.running => (Colors.orange, Icons.sync),
      CommandStatus.done => (Colors.green, Icons.check_circle),
      CommandStatus.error => (Colors.red, Icons.error),
    };
    final summary = runSummary(run);

    return Card(
      child: InkWell(
        onTap: () => _openCommand(context, run),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 34,
                height: 34,
                child: run.isActive
                    ? const Padding(
                        padding: EdgeInsets.all(7),
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : Container(
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.14),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(icon, color: color, size: 18),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(run.action,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14.5)),
                        const Spacer(),
                        Text(relativeTime(run.createdAt),
                            style: TextStyle(
                                fontSize: 11.5, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                    if (summary.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: AppTheme.monoFamily,
                              fontFamilyFallback: AppTheme.monoFallback,
                              fontSize: 12,
                              color: scheme.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: _meta(context, color),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _meta(BuildContext context, Color statusColor) {
    final scheme = Theme.of(context).colorScheme;
    final chips = <Widget>[
      _MetaChip(
        label: run.status.name,
        color: statusColor,
        filled: true,
      ),
    ];
    if (!run.isActive) {
      chips.add(_MetaChip(
          label: formatDuration(run.elapsed), icon: Icons.schedule));
    }
    if (run.result?.exitCode != null) {
      final ec = run.result!.exitCode!;
      chips.add(_MetaChip(
        label: 'exit $ec',
        color: ec == 0 ? null : scheme.error,
      ));
    }
    if (run.logs.isNotEmpty) {
      chips.add(_MetaChip(
          label: '${run.logs.length} lines', icon: Icons.notes));
    }
    if (run.status == CommandStatus.error &&
        (run.result?.error.isNotEmpty ?? false)) {
      chips.add(_MetaChip(label: run.result!.error, color: scheme.error, wide: true));
    }
    return chips;
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.label,
    this.icon,
    this.color,
    this.filled = false,
    this.wide = false,
  });
  final String label;
  final IconData? icon;
  final Color? color;
  final bool filled;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.onSurfaceVariant;
    return Container(
      constraints: wide ? const BoxConstraints(maxWidth: 260) : null,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled
            ? c.withValues(alpha: 0.14)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: c),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: filled ? FontWeight.w700 : FontWeight.w500,
                    color: c)),
          ),
        ],
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history, size: 52, color: scheme.outline),
          const SizedBox(height: 14),
          Text('No commands yet', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('Run an action or a terminal command to see it here.',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
