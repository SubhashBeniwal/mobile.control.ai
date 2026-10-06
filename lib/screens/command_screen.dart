import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/command.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Live view of one command: status, streamed log lines, and terminal result.
class CommandScreen extends StatefulWidget {
  const CommandScreen({super.key, required this.commandId});

  final String commandId;

  @override
  State<CommandScreen> createState() => _CommandScreenState();
}

class _CommandScreenState extends State<CommandScreen> {
  final _scrollCtrl = ScrollController();
  int _lastLogCount = 0;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _autoScroll(int logCount) {
    if (logCount == _lastLogCount) return;
    _lastLogCount = logCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final run = state.commands.where((c) => c.id == widget.commandId).firstOrNull;
    if (run == null) {
      return const Scaffold(body: Center(child: Text('Command not found')));
    }
    _autoScroll(run.logs.length);

    final running =
        run.status == CommandStatus.running || run.status == CommandStatus.pending;

    return Scaffold(
      appBar: AppBar(
        title: Text(run.action),
        actions: [
          if (running)
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: 'Cancel',
              onPressed: () => context.read<AppState>().cancel(run),
            ),
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: 'Copy logs',
            onPressed: () {
              Clipboard.setData(
                ClipboardData(text: run.logs.map((l) => l.data).join('\n')),
              );
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Logs copied')));
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _StatusHeader(run: run),
          Expanded(child: _LogView(run: run, controller: _scrollCtrl)),
          if (run.result != null) _ResultFooter(run: run),
        ],
      ),
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.run});
  final CommandRun run;

  @override
  Widget build(BuildContext context) {
    final (color, label, icon) = switch (run.status) {
      CommandStatus.pending => (Colors.grey, 'Pending', Icons.hourglass_empty),
      CommandStatus.running => (Colors.orange, 'Running', Icons.sync),
      CommandStatus.done => (Colors.green, 'Done', Icons.check_circle),
      CommandStatus.error => (Colors.red, 'Error', Icons.error),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: color.withValues(alpha: 0.10),
      child: Row(
        children: [
          if (run.status == CommandStatus.running)
            const SizedBox(
                width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text('${run.logs.length} lines',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _LogView extends StatelessWidget {
  const _LogView({required this.run, required this.controller});
  final CommandRun run;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    if (run.logs.isEmpty) {
      return Container(
        color: AppTheme.terminalBg,
        alignment: Alignment.center,
        child: Text(
          run.status == CommandStatus.done || run.status == CommandStatus.error
              ? 'No streamed output'
              : 'Waiting for output…',
          style: const TextStyle(color: AppTheme.terminalSystem, fontSize: 13),
        ),
      );
    }
    return Container(
      color: AppTheme.terminalBg,
      child: ListView.builder(
        controller: controller,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        itemCount: run.logs.length,
        itemBuilder: (_, i) {
          final line = run.logs[i];
          return SelectableText(
            line.data.isEmpty ? ' ' : line.data,
            style: AppTheme.monoStyle.copyWith(
              color: switch (line.stream) {
                'stderr' => AppTheme.terminalStderr,
                'system' => AppTheme.terminalSystem,
                _ => AppTheme.terminalFg,
              },
              fontStyle: line.stream == 'system' ? FontStyle.italic : null,
            ),
          );
        },
      ),
    );
  }
}

class _ResultFooter extends StatelessWidget {
  const _ResultFooter({required this.run});
  final CommandRun run;

  @override
  Widget build(BuildContext context) {
    final r = run.result!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 260),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: r.ok ? scheme.surfaceContainerHigh : scheme.errorContainer,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(r.ok ? Icons.check_circle : Icons.error_outline,
                    size: 18, color: r.ok ? Colors.green : scheme.error),
                const SizedBox(width: 8),
                Text(
                  r.ok
                      ? 'Success${r.exitCode != null ? ' · exit ${r.exitCode}' : ''}'
                      : 'Failed',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            if (!r.ok && r.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(r.error,
                    style: TextStyle(color: scheme.onErrorContainer)),
              ),
            if (r.ok && r.data != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  const JsonEncoder.withIndent('  ').convert(r.data),
                  style: AppTheme.monoStyle.copyWith(color: scheme.onSurface),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
