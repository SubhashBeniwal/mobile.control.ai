import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../util/format.dart';

/// View, edit, and save a single file on the daemon. Reads via `file.read`,
/// saves via `file.write`.
class FileViewerScreen extends StatefulWidget {
  const FileViewerScreen({
    super.key,
    required this.daemonId,
    required this.path,
    this.startInEdit = false,
    this.isNew = false,
  });

  final String daemonId;
  final String path;
  final bool startInEdit;
  final bool isNew;

  @override
  State<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends State<FileViewerScreen> {
  bool _loading = true;
  String? _error;
  int _size = 0;
  bool _editing = false;
  bool _saving = false;

  final _ctrl = TextEditingController();
  String _saved = '';

  @override
  void initState() {
    super.initState();
    _editing = widget.startInEdit;
    if (widget.isNew) {
      _loading = false;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await context.read<AppState>().readFile(widget.daemonId, widget.path);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res.ok) {
        _ctrl.text = res.content;
        _saved = res.content;
        _size = res.size;
      } else if (widget.startInEdit && _looksMissing(res.error)) {
        // New file: start empty in the editor rather than showing an error.
        _ctrl.text = '';
        _saved = '';
        _size = 0;
      } else {
        _error = res.error;
      }
    });
  }

  bool _looksMissing(String error) {
    final e = error.toLowerCase();
    return e.contains('no such') || e.contains('not exist') || e.contains('not found');
  }

  bool get _dirty => _ctrl.text != _saved;

  Future<void> _save() async {
    setState(() => _saving = true);
    final future = context
        .read<AppState>()
        .writeFile(widget.daemonId, widget.path, _ctrl.text);
    if (future == null) {
      _snack('Not connected — not saved');
      setState(() => _saving = false);
      return;
    }
    final res = await future;
    if (!mounted) return;
    setState(() => _saving = false);
    if (res.ok) {
      setState(() {
        _saved = _ctrl.text;
        _editing = false;
        _size = _ctrl.text.length;
      });
      _snack('Saved ${widget.path.split('/').last}');
    } else {
      _snack('Save failed: ${res.error}', error: true);
    }
  }

  void _snack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('You have unsaved edits.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep editing')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Discard')),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.path.split('/').last;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        final discard = await _confirmDiscard();
        if (!mounted) return;
        if (discard) nav.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, overflow: TextOverflow.ellipsis),
              Text(
                _dirty ? 'modified · ${humanBytes(_ctrl.text.length)}' : humanBytes(_size),
                style: TextStyle(
                    fontSize: 11,
                    color: _dirty
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy_all_outlined),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _ctrl.text));
                _snack('Copied');
              },
            ),
            if (!_editing)
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: _error != null ? null : () => setState(() => _editing = true),
              ),
            if (_editing)
              _saving
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : IconButton(
                      tooltip: 'Save',
                      icon: const Icon(Icons.save_outlined),
                      onPressed: _dirty ? _save : null,
                    ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _errorView()
                : _editing
                    ? _editor()
                    : _viewer(),
        floatingActionButton: (!_editing && _error == null && !_loading)
            ? FloatingActionButton.extended(
                onPressed: () => setState(() => _editing = true),
                icon: const Icon(Icons.edit),
                label: const Text('Edit'),
              )
            : null,
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
                onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _viewer() {
    return Container(
      color: AppTheme.terminalBg,
      width: double.infinity,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: SelectableText(
          _ctrl.text.isEmpty ? '(empty file)' : _ctrl.text,
          style: AppTheme.monoStyle.copyWith(color: AppTheme.terminalFg),
        ),
      ),
    );
  }

  Widget _editor() {
    return Container(
      color: AppTheme.terminalBg,
      child: TextField(
        controller: _ctrl,
        maxLines: null,
        expands: true,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        style: AppTheme.monoStyle.copyWith(color: AppTheme.terminalFg),
        decoration: const InputDecoration(
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.all(14),
        ),
      ),
    );
  }
}
