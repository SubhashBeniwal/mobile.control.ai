import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/system_metrics.dart';
import '../state/app_state.dart';
import '../util/format.dart';

/// Live system dashboard for the daemon host — CPU, memory, storage, battery,
/// network, and uptime. Metrics are collected by running shell commands via the
/// `deploy` action and parsing their output; the panel polls while it's the
/// active tab.
class SystemScreen extends StatefulWidget {
  const SystemScreen({super.key, required this.daemonId, required this.tabIndex});

  final String daemonId;
  final int tabIndex;

  @override
  State<SystemScreen> createState() => _SystemScreenState();
}

class _SystemScreenState extends State<SystemScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  static const _interval = Duration(seconds: 3);

  SystemMetrics? _metrics;
  String? _error;
  bool _loading = false;
  String? _workdir;

  int? _lastRx, _lastTx;
  DateTime? _lastAt;

  Timer? _timer;
  TabController? _tab;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_interval, (_) => _maybePoll());
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePoll());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tab = DefaultTabController.maybeOf(context);
    if (tab != _tab) {
      _tab?.removeListener(_onTab);
      _tab = tab;
      _tab?.addListener(_onTab);
    }
  }

  void _onTab() {
    if (_isActive) _maybePoll();
  }

  bool get _isActive =>
      _tab == null || (_tab!.index == widget.tabIndex && !_tab!.indexIsChanging);

  @override
  void dispose() {
    _timer?.cancel();
    _tab?.removeListener(_onTab);
    super.dispose();
  }

  Future<void> _maybePoll() async {
    if (!mounted || _loading || !_isActive) return;
    final app = context.read<AppState>();
    if (!app.isConnected) return;
    await _poll(app);
  }

  Future<void> _poll(AppState app) async {
    _loading = true;
    try {
      final daemon = app.daemons.where((d) => d.id == widget.daemonId).firstOrNull;
      if (daemon == null) return;

      // Deploy needs a workdir inside a workspace; discover one once.
      if (_workdir == null) {
        final info = app.dispatchAwait(daemonId: widget.daemonId, action: 'system.info');
        if (info == null) return;
        final data = (await info).data;
        final ws = (data is Map && data['workspaces'] is List)
            ? (data['workspaces'] as List).map((e) => e.toString()).toList()
            : <String>[];
        if (ws.isEmpty) {
          if (mounted) setState(() => _error = 'No workspace available on this daemon');
          return;
        }
        _workdir = ws.first;
      }

      final future = app.runShell(
        daemonId: widget.daemonId,
        command: metricsScript(daemon.os),
        workdir: _workdir!,
      );
      if (future == null) return;
      final out = await future;
      if (!mounted) return;

      if (out.stdout.trim().isEmpty) {
        setState(() => _error = out.ok ? 'No metrics output' : out.error);
        return;
      }

      final m = SystemMetrics.parse(out.stdout);
      _computeRates(m);
      setState(() {
        _metrics = m;
        _error = null;
      });
    } catch (e) {
      if (mounted && _metrics == null) setState(() => _error = e.toString());
    } finally {
      _loading = false;
    }
  }

  void _computeRates(SystemMetrics m) {
    final now = DateTime.now();
    if (_lastAt != null && _lastRx != null && m.netRxBytes != null) {
      final dt = now.difference(_lastAt!).inMilliseconds / 1000.0;
      if (dt > 0) {
        m.rxRate = ((m.netRxBytes! - _lastRx!) / dt).clamp(0, double.infinity);
        m.txRate = ((m.netTxBytes! - _lastTx!) / dt).clamp(0, double.infinity);
      }
    }
    _lastRx = m.netRxBytes;
    _lastTx = m.netTxBytes;
    _lastAt = now;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final m = _metrics;

    if (m == null) {
      if (_error != null) {
        return _CenterMessage(
          icon: Icons.error_outline,
          title: 'Could not read metrics',
          message: _error!,
          onRetry: () => _maybePoll(),
        );
      }
      return const _CenterMessage(
        icon: Icons.speed,
        title: 'Reading system metrics…',
        loading: true,
      );
    }

    return RefreshIndicator(
      onRefresh: _maybePoll,
      child: LayoutBuilder(
        builder: (context, c) {
          final cols = c.maxWidth >= 560 ? 2 : 1;
          const gap = 12.0;
          final w = (c.maxWidth - 24 - gap * (cols - 1)) / cols;
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final card in _cards(m))
                  SizedBox(width: w, child: card),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _cards(SystemMetrics m) => [
        _CpuCard(m: m),
        _MemoryCard(m: m),
        _StorageCard(m: m),
        _BatteryCard(m: m),
        _NetworkCard(m: m),
        _HostCard(m: m),
      ];
}

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

Color _loadColor(double pct) => pct < 70
    ? const Color(0xFF10B981)
    : pct < 90
        ? const Color(0xFFF59E0B)
        : const Color(0xFFEF4444);

class _CpuCard extends StatelessWidget {
  const _CpuCard({required this.m});
  final SystemMetrics m;

  @override
  Widget build(BuildContext context) {
    final pct = m.cpuUsedPercent;
    final load = m.loadAvg.isNotEmpty ? m.loadAvg.first : null;
    return _MetricCard(
      title: 'CPU',
      icon: Icons.memory,
      accent: const Color(0xFF6366F1),
      child: Row(
        children: [
          _Ring(
            value: pct == null ? null : pct / 100,
            color: pct == null ? Colors.grey : _loadColor(pct),
            centerBig: pct == null ? '—' : '${pct.round()}%',
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (m.cpuCount != null)
                  _kv(context, 'Cores', '${m.cpuCount}'),
                if (load != null)
                  _kv(context, 'Load', m.loadAvg.map((e) => e.toStringAsFixed(2)).join('  ')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({required this.m});
  final SystemMetrics m;

  @override
  Widget build(BuildContext context) {
    final pct = m.memPercent;
    return _MetricCard(
      title: 'Memory',
      icon: Icons.dashboard_customize_outlined,
      accent: const Color(0xFF0EA5E9),
      trailing: pct != null ? '${pct.round()}%' : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Bar(value: pct == null ? null : pct / 100, color: const Color(0xFF0EA5E9)),
          const SizedBox(height: 10),
          Text(
            m.memUsedBytes != null && m.memTotalBytes != null
                ? '${humanBytes(m.memUsedBytes!)} used of ${humanBytes(m.memTotalBytes!)}'
                : 'unavailable',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.m});
  final SystemMetrics m;

  @override
  Widget build(BuildContext context) {
    final pct = m.diskPercent;
    return _MetricCard(
      title: 'Storage',
      icon: Icons.storage,
      accent: const Color(0xFF8B5CF6),
      trailing: pct != null ? '${pct.round()}%' : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Bar(value: pct == null ? null : pct / 100, color: const Color(0xFF8B5CF6)),
          const SizedBox(height: 10),
          Text(
            m.diskUsedBytes != null && m.diskTotalBytes != null
                ? '${humanBytes(m.diskUsedBytes!)} used of ${humanBytes(m.diskTotalBytes!)}'
                : 'unavailable',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _BatteryCard extends StatelessWidget {
  const _BatteryCard({required this.m});
  final SystemMetrics m;

  @override
  Widget build(BuildContext context) {
    if (!m.hasBattery) {
      return _MetricCard(
        title: 'Power',
        icon: Icons.power,
        accent: const Color(0xFF10B981),
        child: Row(
          children: [
            const Icon(Icons.electrical_services, size: 34, color: Color(0xFF10B981)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('AC power',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  Text('No battery (desktop)',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final pct = m.batteryPercent ?? 0;
    final charging = m.batteryState == 'Charging' || m.batteryState == 'Charged';
    final color = charging
        ? const Color(0xFF10B981)
        : pct <= 20
            ? const Color(0xFFEF4444)
            : pct <= 40
                ? const Color(0xFFF59E0B)
                : const Color(0xFF10B981);
    return _MetricCard(
      title: 'Battery',
      icon: charging ? Icons.battery_charging_full : Icons.battery_full,
      accent: color,
      trailing: '$pct%',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Bar(value: pct / 100, color: color),
          const SizedBox(height: 10),
          Text(
            m.batteryState.isEmpty
                ? (m.onAc ? 'Plugged in' : 'On battery')
                : m.batteryState,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _NetworkCard extends StatelessWidget {
  const _NetworkCard({required this.m});
  final SystemMetrics m;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = m.isWifi
        ? m.wifiName!
        : (m.iface.isEmpty ? 'Network' : 'Ethernet · ${m.iface}');
    return _MetricCard(
      title: 'Network',
      icon: m.isWifi ? Icons.wifi : Icons.settings_ethernet,
      accent: const Color(0xFF14B8A6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          if (m.ip.isNotEmpty)
            Text(m.ip, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _RateTile(
                  icon: Icons.south,
                  color: const Color(0xFF10B981),
                  label: 'Down',
                  rate: m.rxRate,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _RateTile(
                  icon: Icons.north,
                  color: const Color(0xFF6366F1),
                  label: 'Up',
                  rate: m.txRate,
                ),
              ),
            ],
          ),
          if (m.rxRate == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('measuring…',
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
            ),
        ],
      ),
    );
  }
}

class _RateTile extends StatelessWidget {
  const _RateTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.rate,
  });
  final IconData icon;
  final Color color;
  final String label;
  final double? rate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 10, color: color)),
                Text(rate == null ? '—' : humanRate(rate!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({required this.m});
  final SystemMetrics m;

  @override
  Widget build(BuildContext context) {
    return _MetricCard(
      title: 'Host',
      icon: Icons.dns_outlined,
      accent: const Color(0xFFF59E0B),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.model.isNotEmpty) _kv(context, 'Model', m.model),
          if (m.os.isNotEmpty) _kv(context, 'OS', m.os),
          if (m.uptime.isNotEmpty) _kv(context, 'Uptime', m.uptime),
        ],
      ),
    );
  }
}

Widget _kv(BuildContext context, String k, String v) {
  final scheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 58,
          child: Text(k, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
        Expanded(
          child: Text(v,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Building blocks
// ---------------------------------------------------------------------------

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.icon,
    required this.accent,
    required this.child,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Color accent;
  final Widget child;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: accent),
                const SizedBox(width: 8),
                Text(title,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const Spacer(),
                if (trailing != null)
                  Text(trailing!,
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w800, color: accent)),
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.value, required this.color, required this.centerBig});
  final double? value;
  final Color color;
  final String centerBig;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 78,
      height: 78,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 78,
            height: 78,
            child: CircularProgressIndicator(
              value: value,
              strokeWidth: 8,
              strokeCap: StrokeCap.round,
              backgroundColor: color.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          Text(centerBig,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.value, required this.color});
  final double? value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: LinearProgressIndicator(
        value: value,
        minHeight: 10,
        backgroundColor: color.withValues(alpha: 0.15),
        valueColor: AlwaysStoppedAnimation(color),
      ),
    );
  }
}

class _CenterMessage extends StatelessWidget {
  const _CenterMessage({
    required this.icon,
    required this.title,
    this.message,
    this.loading = false,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String? message;
  final bool loading;
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
            if (loading)
              const CircularProgressIndicator()
            else
              Icon(icon, size: 52, color: scheme.outline),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
