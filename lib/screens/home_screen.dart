import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/daemon.dart';
import '../services/relay_client.dart';
import '../state/app_state.dart';
import 'daemon_screen.dart';
import 'settings_screen.dart';

/// Landing screen: relay status header + the list of registered daemons.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('AIO Control'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Relay settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => state.connect(),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _RelayHeader(state: state)),
            _buildContent(context, state),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, AppState state) {
    if (!state.settings.isConfigured) {
      return _emptySliver(
        context,
        icon: Icons.link_off,
        title: 'No relay configured',
        message: 'Set the relay URL and control token to get started.',
        actionLabel: 'Open settings',
        onAction: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        ),
      );
    }

    final daemons = state.daemons;
    if (daemons.isEmpty) {
      final connecting = state.connection == RelayConnectionState.connecting;
      return _emptySliver(
        context,
        icon: connecting ? Icons.sync : Icons.devices_other,
        title: connecting ? 'Connecting to relay…' : 'No daemons online',
        message: state.connection == RelayConnectionState.disconnected
            ? (state.lastError ?? 'Not connected. Pull to retry.')
            : 'Waiting for a daemon to register. Pull to refresh.',
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      sliver: SliverList.separated(
        itemCount: daemons.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _DaemonCard(daemon: daemons[i]),
      ),
    );
  }

  Widget _emptySliver(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 16),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium),
              if (actionLabel != null) ...[
                const SizedBox(height: 20),
                FilledButton(onPressed: onAction, child: Text(actionLabel)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RelayHeader extends StatelessWidget {
  const _RelayHeader({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (dot, label) = switch (state.connection) {
      RelayConnectionState.connected => (Colors.green, 'Connected'),
      RelayConnectionState.connecting => (Colors.orange, 'Connecting…'),
      RelayConnectionState.disconnected => (Colors.red, 'Offline'),
    };
    final host = Uri.tryParse(state.settings.relayUrl)?.host ?? state.settings.relayUrl;
    final count = state.daemons.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              _PulseDot(color: dot),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(label,
                            style: TextStyle(
                                color: dot,
                                fontWeight: FontWeight.w700,
                                fontSize: 15)),
                        const SizedBox(width: 8),
                        if (count > 0)
                          Container(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: scheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text('$count daemon${count == 1 ? '' : 's'}',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.onSecondaryContainer)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(host,
                        style: TextStyle(
                            fontSize: 12.5, color: scheme.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              if (state.connection == RelayConnectionState.disconnected)
                IconButton.filledTonal(
                  onPressed: state.connect,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Reconnect',
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulseDot extends StatelessWidget {
  const _PulseDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8, spreadRadius: 1),
        ],
      ),
    );
  }
}

class _DaemonCard extends StatelessWidget {
  const _DaemonCard({required this.daemon});
  final Daemon daemon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        onTap: () {
          context.read<AppState>().selectDaemon(daemon.id);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => DaemonScreen(daemonId: daemon.id)),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: daemon.online
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      daemon.os == 'darwin'
                          ? Icons.laptop_mac
                          : daemon.os == 'linux'
                              ? Icons.dns
                              : Icons.computer,
                      color: daemon.online ? scheme.onPrimaryContainer : scheme.outline,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(daemon.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 16)),
                        const SizedBox(height: 2),
                        Text('${daemon.os}/${daemon.arch} · ${daemon.version}',
                            style: TextStyle(
                                fontSize: 12.5, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  _StatusPill(online: daemon.online),
                ],
              ),
              if (daemon.providers.isNotEmpty) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final p in daemon.providers)
                      _MiniChip(icon: Icons.smart_toy_outlined, label: p),
                    _MiniChip(
                      icon: Icons.bolt,
                      label: '${daemon.actions.length} actions',
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.online});
  final bool online;

  @override
  Widget build(BuildContext context) {
    final color = online ? Colors.green : Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(online ? 'online' : 'offline',
              style: TextStyle(
                  color: color, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
