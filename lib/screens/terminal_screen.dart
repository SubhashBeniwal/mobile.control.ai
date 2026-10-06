import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/command.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Interactive shell for a repo on the daemon. Each command is dispatched as a
/// `deploy` action with `shell:true` (`sh -c "<command>"`) in the current
/// working directory, and its streamed output is rendered inline like a
/// terminal. `cd` and `clear` are handled client-side; the working directory is
/// optimistic (the daemon rejects any path outside its workspaces).
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key, required this.daemonId});

  final String daemonId;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

/// One line of the scrollback: either a real dispatched command (with [runId]),
/// or a synthetic local note (cd result, hints, errors).
class _Entry {
  _Entry.command(this.cwd, this.command, this.runId)
      : note = null,
        isError = false;
  _Entry.note(this.note, {this.isError = false})
      : cwd = '',
        command = '',
        runId = null;

  final String cwd;
  final String command;
  final String? runId;
  final String? note;
  final bool isError;
}

class _TerminalScreenState extends State<TerminalScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _entries = <_Entry>[];
  final _history = <String>[];
  int _historyCursor = 0;

  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _inputFocus = FocusNode();

  late String _cwd;
  List<String> _workspaces = const [];
  bool _detecting = false;

  @override
  void initState() {
    super.initState();
    _cwd = context.read<AppState>().workdirFor(widget.daemonId);
    if (_cwd.isEmpty) _detectWorkspaces();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  AppState get _app => context.read<AppState>();

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  Future<void> _detectWorkspaces() async {
    if (_detecting) return;
    setState(() => _detecting = true);
    final future = _app.dispatchAwait(
      daemonId: widget.daemonId,
      action: 'system.info',
    );
    if (future == null) {
      if (mounted) setState(() => _detecting = false);
      return;
    }
    final result = await future;
    if (!mounted) return;
    final data = result.data;
    final ws = (data is Map && data['workspaces'] is List)
        ? (data['workspaces'] as List).map((e) => e.toString()).toList()
        : <String>[];
    setState(() {
      _workspaces = ws;
      _detecting = false;
      if (_cwd.isEmpty && ws.length == 1) _setCwd(ws.first, silent: true);
    });
  }

  void _setCwd(String dir, {bool silent = false}) {
    _cwd = dir;
    _app.setWorkdir(widget.daemonId, dir);
    if (!silent) _entries.add(_Entry.note('cwd → $dir'));
    setState(() {});
  }

  /// Validate a directory exists on the daemon (via `file.list`) before making
  /// it the working directory — mirrors a shell's `cd` failing on a bad path.
  Future<void> _cd(String arg) async {
    if (arg.isEmpty || arg == '~') {
      // No home dir known; a bare `cd` is a no-op here.
      _addNote('cd: no home directory available — pass a path', isError: true);
      return;
    }
    if (arg == '/') {
      _addNote('cd: /: outside the daemon workspace', isError: true);
      return;
    }
    if (!arg.startsWith('/') && _cwd.isEmpty) {
      _addNote('cd: $arg: no working directory set (use an absolute path)',
          isError: true);
      return;
    }

    final target = arg.startsWith('/') ? _normalize(arg) : _normalize('$_cwd/$arg');

    final future = _app.dispatchAwait(
      daemonId: widget.daemonId,
      action: 'file.list',
      args: {'path': target},
    );
    if (future == null) {
      _addNote('Not connected — command not sent.', isError: true);
      return;
    }
    final result = await future;
    if (!mounted) return;
    if (result.ok) {
      _setCwd(target, silent: true); // shells are silent on success
      _scrollToBottom();
    } else {
      final err = result.error.toLowerCase();
      final msg = err.contains('not a directory')
          ? 'cd: $arg: Not a directory'
          : (err.contains('no such') || err.contains('not found') || err.contains('exist'))
              ? 'cd: $arg: No such file or directory'
              : 'cd: $arg: ${result.error.isEmpty ? 'cannot access' : result.error}';
      _addNote(msg, isError: true);
      _scrollToBottom();
    }
  }

  void _addNote(String text, {bool isError = false}) {
    setState(() => _entries.add(_Entry.note(text, isError: isError)));
  }

  String _normalize(String path) {
    final absolute = path.startsWith('/');
    final out = <String>[];
    for (final seg in path.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (out.isNotEmpty && out.last != '..') {
          out.removeLast();
        } else if (!absolute) {
          out.add('..');
        }
      } else {
        out.add(seg);
      }
    }
    return (absolute ? '/' : '') + out.join('/');
  }

  void _submit(String raw) {
    final cmd = raw.trim();
    _inputCtrl.clear();
    _inputFocus.requestFocus();
    if (cmd.isEmpty) return;

    _history.add(cmd);
    _historyCursor = _history.length;

    if (cmd == 'clear') {
      setState(_entries.clear);
      return;
    }
    if (cmd == 'cd' || cmd.startsWith('cd ')) {
      _cd(cmd == 'cd' ? '' : cmd.substring(3).trim());
      return;
    }
    if (_cwd.isEmpty) {
      setState(() => _entries.add(
          _Entry.note('Set a working directory first (tap the folder icon).')));
      _scrollToBottom();
      return;
    }

    final run = _app.dispatch(
      daemonId: widget.daemonId,
      action: 'deploy',
      args: {'workdir': _cwd, 'command': cmd, 'shell': true},
    );
    if (run == null) {
      setState(() => _entries
          .add(_Entry.note('Not connected — command not sent.')));
      return;
    }
    setState(() => _entries.add(_Entry.command(_cwd, cmd, run.id)));
    _scrollToBottom();
  }

  void _historyPrev() {
    if (_history.isEmpty || _historyCursor == 0) return;
    _historyCursor--;
    _inputCtrl.text = _history[_historyCursor];
    _inputCtrl.selection =
        TextSelection.collapsed(offset: _inputCtrl.text.length);
    setState(() {});
  }

  void _historyNext() {
    if (_historyCursor >= _history.length) return;
    _historyCursor++;
    _inputCtrl.text =
        _historyCursor == _history.length ? '' : _history[_historyCursor];
    _inputCtrl.selection =
        TextSelection.collapsed(offset: _inputCtrl.text.length);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // for keep-alive
    final app = context.watch<AppState>();
    final connected = app.isConnected;
    _scrollToBottom();

    return Column(
      children: [
        _cwdBar(context),
        Expanded(child: _console()),
        _inputBar(context, connected),
      ],
    );
  }

  Widget _cwdBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Row(
              children: [
                Icon(Icons.folder_open, size: 18, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: _editCwd,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _cwd.isEmpty ? 'No working directory — tap to set' : _cwd,
                        style: TextStyle(
                          fontFamily: AppTheme.monoFamily,
                          fontFamilyFallback: AppTheme.monoFallback,
                          fontSize: 13,
                          color: _cwd.isEmpty ? scheme.outline : scheme.onSurface,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Detect workspaces',
                  visualDensity: VisualDensity.compact,
                  icon: _detecting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.travel_explore, size: 20),
                  onPressed: _detecting ? null : _detectWorkspaces,
                ),
                IconButton(
                  tooltip: 'Clear',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.cleaning_services_outlined, size: 20),
                  onPressed: () => setState(_entries.clear),
                ),
              ],
            ),
          ),
          if (_workspaces.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(left: 44, right: 12, bottom: 6),
                children: [
                  for (final ws in _workspaces)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        label: Text(ws.split('/').last.isEmpty ? ws : ws.split('/').last),
                        avatar: const Icon(Icons.workspaces_outline, size: 14),
                        onPressed: () => _setCwd(ws),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _editCwd() async {
    final ctrl = TextEditingController(text: _cwd);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Working directory'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '/abs/path/to/repo',
            prefixIcon: Icon(Icons.folder),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text), child: const Text('Set')),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) _setCwd(result.trim());
  }

  Widget _console() {
    return Container(
      color: AppTheme.terminalBg,
      width: double.infinity,
      child: _entries.isEmpty
          ? const Center(
              child: Text('Type a command below to run it in the repo.',
                  style: TextStyle(color: AppTheme.terminalSystem, fontSize: 13)))
          : ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              itemCount: _entries.length,
              itemBuilder: (_, i) => _EntryView(entry: _entries[i]),
            ),
    );
  }

  Widget _inputBar(BuildContext context, bool connected) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              Text('\$',
                  style: TextStyle(
                    color: AppTheme.terminalPrompt,
                    fontFamily: AppTheme.monoFamily,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  )),
              const SizedBox(width: 10),
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowUp): _historyPrev,
                    const SingleActivator(LogicalKeyboardKey.arrowDown): _historyNext,
                  },
                  child: TextField(
                    controller: _inputCtrl,
                    focusNode: _inputFocus,
                    enabled: connected,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.send,
                    style: const TextStyle(
                      fontFamily: AppTheme.monoFamily,
                      fontFamilyFallback: AppTheme.monoFallback,
                      fontSize: 14,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: connected ? 'run a command…' : 'disconnected',
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                    onSubmitted: _submit,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filled(
                onPressed: connected ? () => _submit(_inputCtrl.text) : null,
                icon: const Icon(Icons.keyboard_return),
                tooltip: 'Run',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryView extends StatelessWidget {
  const _EntryView({required this.entry});
  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    if (entry.note != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: SelectableText(
          entry.note!,
          style: AppTheme.monoStyle.copyWith(
              color: entry.isError ? AppTheme.terminalStderr : AppTheme.terminalSystem,
              fontStyle: entry.isError ? FontStyle.normal : FontStyle.italic),
        ),
      );
    }

    final app = context.watch<AppState>();
    final run = app.commands.where((c) => c.id == entry.runId).firstOrNull;

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Prompt line.
          RichText(
            text: TextSpan(
              style: AppTheme.monoStyle,
              children: [
                TextSpan(
                    text: '${_short(entry.cwd)} ',
                    style: const TextStyle(color: AppTheme.terminalSystem)),
                const TextSpan(
                    text: '\$ ',
                    style: TextStyle(
                        color: AppTheme.terminalPrompt, fontWeight: FontWeight.bold)),
                TextSpan(
                    text: entry.command,
                    style: const TextStyle(color: AppTheme.terminalFg)),
              ],
            ),
          ),
          if (run != null) ...[
            for (final line in run.logs)
              SelectableText(
                line.data,
                style: AppTheme.monoStyle.copyWith(
                  color: switch (line.stream) {
                    'stderr' => AppTheme.terminalStderr,
                    'system' => AppTheme.terminalSystem,
                    _ => AppTheme.terminalFg,
                  },
                ),
              ),
            if (run.status == CommandStatus.running ||
                run.status == CommandStatus.pending)
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text('▍ running…',
                    style: TextStyle(
                        color: AppTheme.terminalSystem,
                        fontFamily: AppTheme.monoFamily,
                        fontSize: 12)),
              ),
            if (run.result != null && !run.result!.ok)
              SelectableText(
                run.result!.error.isNotEmpty
                    ? run.result!.error
                    : 'exited with code ${run.result!.exitCode ?? '?'}',
                style: AppTheme.monoStyle.copyWith(color: AppTheme.terminalStderr),
              ),
            if (run.result != null &&
                run.result!.ok &&
                (run.result!.exitCode ?? 0) != 0)
              SelectableText('exit ${run.result!.exitCode}',
                  style: AppTheme.monoStyle.copyWith(color: AppTheme.terminalStderr)),
          ],
        ],
      ),
    );
  }

  /// Compact cwd for the prompt (last two path segments).
  String _short(String cwd) {
    if (cwd.isEmpty) return '~';
    final parts = cwd.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.length <= 2) return cwd;
    return '…/${parts[parts.length - 2]}/${parts.last}';
  }
}
