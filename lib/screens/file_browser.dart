import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/file_entry.dart';
import '../state/app_state.dart';
import '../util/format.dart';
import 'file_viewer_screen.dart';

enum BrowserMode { browse, pickFile }

/// A directory browser rooted at the daemon's workspaces, backed by a lazy
/// expandable tree, with name search across workspaces. Used to browse and
/// open files, or to pick a file to read/edit.
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({
    super.key,
    required this.daemonId,
    this.mode = BrowserMode.browse,
    this.title,
    this.allowCreate = false,
  });

  final String daemonId;
  final BrowserMode mode;
  final String? title;

  /// Whether to offer a "New file" action (used by the write flow).
  final bool allowCreate;

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  List<String>? _roots;
  bool _showHidden = false;
  String? _error;

  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  String _query = '';
  bool _searching = false;
  List<String>? _results;

  @override
  void initState() {
    super.initState();
    _loadRoots();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadRoots() async {
    final ws = await context.read<AppState>().fetchWorkspaces(widget.daemonId);
    if (!mounted) return;
    setState(() {
      _roots = ws;
      if (ws.isEmpty) _error = 'No workspaces available on this daemon';
    });
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _query = q.trim();
    if (_query.isEmpty) {
      setState(() => _results = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), _runSearch);
  }

  Future<void> _runSearch() async {
    final roots = _roots;
    if (roots == null || roots.isEmpty || _query.isEmpty) return;
    setState(() => _searching = true);
    final app = context.read<AppState>();
    final quoted = roots.map((r) => '"$r"').join(' ');
    // Escape double quotes in the query for the shell.
    final safe = _query.replaceAll('"', r'\"');
    final cmd =
        'for r in $quoted; do find "\$r" -type f -iname "*$safe*" -not -path "*/.git/*" 2>/dev/null; done | head -200';
    final f = app.runShell(daemonId: widget.daemonId, command: cmd, workdir: roots.first);
    final out = f == null ? null : await f;
    if (!mounted) return;
    setState(() {
      _searching = false;
      _results = (out?.stdout ?? '')
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    });
  }

  void _openFile(String path) {
    if (widget.mode == BrowserMode.pickFile) {
      Navigator.of(context).pop(path);
    } else {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => FileViewerScreen(daemonId: widget.daemonId, path: path),
      ));
    }
  }

  Future<void> _newFile() async {
    final roots = _roots ?? const [];
    final base = roots.isNotEmpty ? roots.first : '';
    final ctrl = TextEditingController(text: base.isEmpty ? '' : '$base/');
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New file'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '/abs/path/newfile.txt',
            prefixIcon: Icon(Icons.note_add_outlined),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text), child: const Text('Create')),
        ],
      ),
    );
    if (path == null || path.trim().isEmpty || !mounted) return;
    Navigator.of(context).pop(path.trim());
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title ??
        (widget.mode == BrowserMode.pickFile ? 'Pick a file' : 'Files');

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: _showHidden ? 'Hide hidden' : 'Show hidden',
            icon: Icon(_showHidden ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showHidden = !_showHidden),
          ),
          if (widget.allowCreate)
            IconButton(
              tooltip: 'New file',
              icon: const Icon(Icons.note_add_outlined),
              onPressed: _newFile,
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _onQueryChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search files by name…',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          _onQueryChanged('');
                        },
                      ),
              ),
            ),
          ),
        ),
      ),
      body: _roots == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : _query.isNotEmpty
                  ? _searchResults(context)
                  : _tree(),
    );
  }

  Widget _tree() => ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final root in _roots!)
            DirectoryNode(
              daemonId: widget.daemonId,
              path: root,
              label: root,
              depth: 0,
              showHidden: _showHidden,
              isRoot: true,
              mode: widget.mode,
              onOpenFile: _openFile,
            ),
        ],
      );

  Widget _searchResults(BuildContext context) {
    if (_searching && _results == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final results = _results ?? const [];
    if (results.isEmpty) {
      return Center(
        child: Text(_searching ? 'Searching…' : 'No matches for "$_query"',
            style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        if (_searching) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView.builder(
            itemCount: results.length,
            itemBuilder: (_, i) {
              final path = results[i];
              final name = path.split('/').last;
              final dir = path.substring(0, path.length - name.length);
              final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
              return ListTile(
                dense: true,
                leading: Icon(fileIcon(ext), size: 20, color: fileColor(ext, scheme)),
                title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(dir,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: scheme.outline)),
                onTap: () => _openFile(path),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A single expandable directory in the tree. Loads its children lazily the
/// first time it's expanded.
class DirectoryNode extends StatefulWidget {
  const DirectoryNode({
    super.key,
    required this.daemonId,
    required this.path,
    required this.label,
    required this.depth,
    required this.showHidden,
    required this.mode,
    required this.onOpenFile,
    this.isRoot = false,
  });

  final String daemonId;
  final String path;
  final String label;
  final int depth;
  final bool showHidden;
  final bool isRoot;
  final BrowserMode mode;
  final ValueChanged<String> onOpenFile;

  @override
  State<DirectoryNode> createState() => _DirectoryNodeState();
}

class _DirectoryNodeState extends State<DirectoryNode> {
  bool _expanded = false;
  bool _loading = false;
  String? _error;
  List<FileEntry>? _entries;

  @override
  void initState() {
    super.initState();
    if (widget.isRoot) _toggle();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await context.read<AppState>().listDir(widget.daemonId, widget.path);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res.ok) {
        _entries = res.entries;
      } else {
        _error = res.error;
      }
    });
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded && _entries == null && !_loading) _load();
  }

  Future<void> _refresh() async {
    _entries = null;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final indent = 12.0 + widget.depth * 16.0;
    final entries =
        _entries?.where((e) => widget.showHidden || !e.isHidden).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _toggle,
          child: Padding(
            padding: EdgeInsets.fromLTRB(indent, 9, 12, 9),
            child: Row(
              children: [
                Icon(_expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: 2),
                Icon(_expanded ? Icons.folder_open : Icons.folder,
                    size: 19, color: const Color(0xFF60A5FA)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: widget.isRoot ? FontWeight.w700 : FontWeight.w500,
                      fontSize: widget.isRoot ? 13 : 14,
                      color: widget.isRoot ? scheme.onSurfaceVariant : scheme.onSurface,
                    ),
                  ),
                ),
                if (_expanded)
                  InkWell(
                    onTap: _refresh,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.refresh, size: 15, color: scheme.outline),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          if (_loading)
            Padding(
              padding: EdgeInsets.fromLTRB(indent + 26, 4, 0, 8),
              child: const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_error != null)
            Padding(
              padding: EdgeInsets.fromLTRB(indent + 26, 4, 12, 8),
              child: Text(_error!, style: TextStyle(color: scheme.error, fontSize: 12)),
            )
          else if (entries != null && entries.isEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(indent + 26, 4, 12, 8),
              child: Text('empty', style: TextStyle(color: scheme.outline, fontSize: 12)),
            )
          else if (entries != null)
            for (final e in entries)
              e.isDir
                  ? DirectoryNode(
                      daemonId: widget.daemonId,
                      path: joinPath(widget.path, e.name),
                      label: e.name,
                      depth: widget.depth + 1,
                      showHidden: widget.showHidden,
                      mode: widget.mode,
                      onOpenFile: widget.onOpenFile,
                    )
                  : _FileRow(
                      entry: e,
                      indent: indent + 16,
                      onTap: () => widget.onOpenFile(joinPath(widget.path, e.name)),
                    ),
        ],
      ],
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.entry, required this.indent, required this.onTap});
  final FileEntry entry;
  final double indent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(indent + 22, 8, 12, 8),
        child: Row(
          children: [
            Icon(fileIcon(entry.ext), size: 17, color: fileColor(entry.ext, scheme)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5)),
            ),
            Text(humanBytes(entry.size),
                style: TextStyle(fontSize: 11, color: scheme.outline)),
          ],
        ),
      ),
    );
  }
}

IconData fileIcon(String ext) => switch (ext) {
      'dart' || 'go' || 'py' || 'js' || 'ts' || 'java' || 'kt' || 'rs' || 'c' ||
      'cpp' || 'h' || 'swift' || 'rb' || 'php' =>
        Icons.code,
      'json' || 'yaml' || 'yml' || 'toml' || 'xml' || 'ini' || 'env' =>
        Icons.data_object,
      'md' || 'txt' || 'rst' => Icons.article_outlined,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'svg' || 'webp' => Icons.image_outlined,
      'pdf' => Icons.picture_as_pdf_outlined,
      'zip' || 'tar' || 'gz' || 'tgz' => Icons.folder_zip_outlined,
      'sh' || 'bash' || 'zsh' => Icons.terminal,
      _ => Icons.insert_drive_file_outlined,
    };

Color fileColor(String ext, ColorScheme scheme) => switch (ext) {
      'dart' || 'go' || 'py' || 'js' || 'ts' || 'java' || 'kt' || 'rs' =>
        const Color(0xFF10B981),
      'json' || 'yaml' || 'yml' || 'toml' || 'xml' => const Color(0xFFF59E0B),
      'md' || 'txt' => const Color(0xFF60A5FA),
      'png' || 'jpg' || 'jpeg' || 'gif' || 'svg' => const Color(0xFFA855F7),
      _ => scheme.onSurfaceVariant,
    };
