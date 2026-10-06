import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme.dart';
import 'command_screen.dart';
import 'repo_picker.dart';

/// Entry point: pick a repo, then open its Git dashboard.
void openGit(BuildContext context, String daemonId) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => RepoPickerScreen(
      daemonId: daemonId,
      title: 'Git',
      subtitle: 'Pick a repository',
      icon: Icons.account_tree,
      onOpen: (ctx, repo) => Navigator.of(ctx).push(MaterialPageRoute(
        builder: (_) => GitRepoScreen(daemonId: daemonId, repo: repo),
      )),
    ),
  ));
}

class GitChange {
  GitChange(this.code, this.path);
  final String code; // 2-char XY porcelain status
  final String path;

  bool get staged => code[0] != ' ' && code[0] != '?';
  bool get untracked => code == '??';
  String get label => switch (code.trim()) {
        'M' || 'MM' || ' M' => 'modified',
        'A' || 'A ' => 'added',
        'D' || ' D' => 'deleted',
        'R' => 'renamed',
        '??' => 'untracked',
        _ => code.trim(),
      };
  Color get color => switch (code.trim()) {
        'A' || 'A ' || '??' => const Color(0xFF10B981),
        'D' || ' D' => const Color(0xFFEF4444),
        'R' => const Color(0xFFA855F7),
        _ => const Color(0xFFF59E0B),
      };
}

class GitCommit {
  GitCommit(this.hash, this.subject);
  final String hash;
  final String subject;
}

class GitRepoScreen extends StatefulWidget {
  const GitRepoScreen({super.key, required this.daemonId, required this.repo});
  final String daemonId;
  final String repo;

  @override
  State<GitRepoScreen> createState() => _GitRepoScreenState();
}

class _GitRepoScreenState extends State<GitRepoScreen> {
  bool _loading = true;
  String? _error;

  String _branch = '';
  int _ahead = 0, _behind = 0;
  bool _hasUpstream = false;
  final List<GitChange> _changes = [];
  final List<GitCommit> _commits = [];
  final List<String> _branches = [];

  final _commitCtrl = TextEditingController();

  String get _name => widget.repo.split('/').last;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commitCtrl.dispose();
    super.dispose();
  }

  AppState get _app => context.read<AppState>();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final app = _app;
    final statusF = app.runGit(widget.daemonId, widget.repo,
        '-c color.ui=false status --porcelain=v1 --branch');
    final logF =
        app.runGit(widget.daemonId, widget.repo, '-c color.ui=false log --oneline -20');
    final branchF =
        app.runGit(widget.daemonId, widget.repo, '-c color.ui=false branch');
    if (statusF == null || logF == null || branchF == null) {
      setState(() {
        _loading = false;
        _error = 'Not connected';
      });
      return;
    }
    final status = await statusF;
    final log = await logF;
    final branch = await branchF;
    if (!mounted) return;

    if (!status.ok && status.stdout.trim().isEmpty) {
      setState(() {
        _loading = false;
        _error = status.error.isEmpty ? 'git failed' : status.error;
      });
      return;
    }

    _parseStatus(status.stdout);
    _commits
      ..clear()
      ..addAll(_parseLog(log.stdout));
    _branches
      ..clear()
      ..addAll(branch.stdout
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty));
    setState(() => _loading = false);
  }

  void _parseStatus(String out) {
    _changes.clear();
    _ahead = _behind = 0;
    _hasUpstream = false;
    for (final raw in out.split('\n')) {
      if (raw.isEmpty) continue;
      if (raw.startsWith('##')) {
        final line = raw.substring(2).trim();
        final name = line.split('...').first.split(' ').first;
        _branch = name;
        _hasUpstream = line.contains('...');
        final ahead = RegExp(r'ahead (\d+)').firstMatch(line);
        final behind = RegExp(r'behind (\d+)').firstMatch(line);
        if (ahead != null) _ahead = int.parse(ahead.group(1)!);
        if (behind != null) _behind = int.parse(behind.group(1)!);
      } else if (raw.length > 3) {
        _changes.add(GitChange(raw.substring(0, 2), raw.substring(3)));
      }
    }
  }

  List<GitCommit> _parseLog(String out) => out
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .map((l) {
        final i = l.indexOf(' ');
        return i < 0
            ? GitCommit(l, '')
            : GitCommit(l.substring(0, i), l.substring(i + 1));
      })
      .toList();

  Future<void> _runGitTracked(List<String> args) async {
    final run = _app.dispatch(
      daemonId: widget.daemonId,
      action: 'git',
      args: {'workdir': widget.repo, 'args': args},
    );
    if (run == null) {
      _snack('Not connected');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CommandScreen(commandId: run.id),
    ));
    if (mounted) _load();
  }

  Future<void> _commit() async {
    final msg = _commitCtrl.text.trim();
    if (msg.isEmpty) return;
    final safe = msg.replaceAll('"', r'\"');
    final run = _app.dispatch(
      daemonId: widget.daemonId,
      action: 'deploy',
      args: {
        'workdir': widget.repo,
        'command': 'git add -A && git commit -m "$safe"',
        'shell': true,
      },
    );
    if (run == null) {
      _snack('Not connected');
      return;
    }
    _commitCtrl.clear();
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CommandScreen(commandId: run.id),
    ));
    if (mounted) _load();
  }

  void _openDiff(String title, String gitArgs) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GitDiffScreen(
        daemonId: widget.daemonId,
        repo: widget.repo,
        title: title,
        gitArgs: gitArgs,
      ),
    ));
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _customCommand() async {
    final ctrl = TextEditingController();
    final args = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('git'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(prefixText: 'git ', hintText: 'log --stat'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text), child: const Text('Run')),
        ],
      ),
    );
    if (args != null && args.trim().isNotEmpty) {
      _runGitTracked(args.trim().split(RegExp(r'\s+')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
              tooltip: 'Run git…', onPressed: _customCommand, icon: const Icon(Icons.terminal)),
          IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      _branchCard(),
                      const SizedBox(height: 10),
                      if (_changes.isNotEmpty) ...[
                        _commitBox(),
                        const SizedBox(height: 10),
                      ],
                      _changesCard(),
                      const SizedBox(height: 10),
                      _commitsCard(),
                      const SizedBox(height: 10),
                      _branchesCard(),
                    ],
                  ),
                ),
    );
  }

  Widget _branchCard() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.commit, size: 20, color: Color(0xFF10B981)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_branch.isEmpty ? '(detached)' : _branch,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                if (_changes.isEmpty)
                  const _Pill(text: 'clean', color: Color(0xFF10B981))
                else
                  _Pill(text: '${_changes.length} changed', color: const Color(0xFFF59E0B)),
              ],
            ),
            if (_hasUpstream) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  if (_ahead > 0) _Pill(text: '↑ $_ahead ahead', color: scheme.primary),
                  if (_ahead > 0) const SizedBox(width: 6),
                  if (_behind > 0) _Pill(text: '↓ $_behind behind', color: scheme.tertiary),
                  if (_ahead == 0 && _behind == 0)
                    Text('up to date with upstream',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                _op(Icons.download, 'Fetch', () => _runGitTracked(['fetch'])),
                const SizedBox(width: 8),
                _op(Icons.arrow_downward, 'Pull', () => _runGitTracked(['pull'])),
                const SizedBox(width: 8),
                _op(Icons.arrow_upward, 'Push', () => _runGitTracked(['push'])),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _op(IconData icon, String label, VoidCallback onTap) => Expanded(
        child: FilledButton.tonalIcon(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label),
          style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12)),
        ),
      );

  Widget _commitBox() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _commitCtrl,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Commit message (stages all)',
                  prefixIcon: Icon(Icons.edit_note),
                ),
                onSubmitted: (_) => _commit(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _commit, child: const Text('Commit')),
          ],
        ),
      ),
    );
  }

  Widget _changesCard() {
    return _SectionCard(
      title: 'Changes',
      trailing: '${_changes.length}',
      child: _changes.isEmpty
          ? const _Empty('Working tree clean')
          : Column(
              children: [
                for (final c in _changes)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: _CodeBadge(code: c.code.trim().isEmpty ? '·' : c.code.trim(),
                        color: c.color),
                    title: Text(c.path.split('/').last,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(c.label, style: TextStyle(color: c.color, fontSize: 11)),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: c.untracked
                        ? null
                        : () => _openDiff(c.path.split('/').last,
                            '-c color.ui=false diff HEAD -- "${c.path}"'),
                  ),
              ],
            ),
    );
  }

  Widget _commitsCard() {
    return _SectionCard(
      title: 'Recent commits',
      child: _commits.isEmpty
          ? const _Empty('No commits')
          : Column(
              children: [
                for (final c in _commits)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: Text(c.hash,
                        style: AppTheme.monoStyle.copyWith(
                            color: const Color(0xFFF59E0B), fontSize: 12)),
                    title: Text(c.subject,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => _openDiff(c.hash, '-c color.ui=false show ${c.hash}'),
                  ),
              ],
            ),
    );
  }

  Widget _branchesCard() {
    return _SectionCard(
      title: 'Branches',
      trailing: '${_branches.length}',
      child: Column(
        children: [
          for (final b in _branches)
            () {
              final current = b.startsWith('*');
              final name = b.replaceFirst('*', '').trim();
              return ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Icon(current ? Icons.radio_button_checked : Icons.call_split,
                    size: 18,
                    color: current ? const Color(0xFF10B981) : null),
                title: Text(name,
                    style: TextStyle(
                        fontWeight: current ? FontWeight.w700 : FontWeight.w400)),
                trailing: current
                    ? const _Pill(text: 'current', color: Color(0xFF10B981))
                    : TextButton(
                        onPressed: () => _runGitTracked(['checkout', name]),
                        child: const Text('Checkout')),
              );
            }(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Diff viewer
// ---------------------------------------------------------------------------

class GitDiffScreen extends StatefulWidget {
  const GitDiffScreen({
    super.key,
    required this.daemonId,
    required this.repo,
    required this.title,
    required this.gitArgs,
  });

  final String daemonId;
  final String repo;
  final String title;
  final String gitArgs;

  @override
  State<GitDiffScreen> createState() => _GitDiffScreenState();
}

class _GitDiffScreenState extends State<GitDiffScreen> {
  String? _text;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final f = context.read<AppState>().runGit(widget.daemonId, widget.repo, widget.gitArgs);
    if (f == null) {
      setState(() => _error = 'Not connected');
      return;
    }
    final out = await f;
    if (!mounted) return;
    setState(() {
      if (out.ok || out.stdout.isNotEmpty) {
        _text = out.stdout.isEmpty ? '(no changes)' : out.stdout;
      } else {
        _error = out.error;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, overflow: TextOverflow.ellipsis)),
      body: _error != null
          ? Center(child: Text(_error!))
          : _text == null
              ? const Center(child: CircularProgressIndicator())
              : Container(
                  color: AppTheme.terminalBg,
                  width: double.infinity,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(14),
                    child: SelectableText.rich(_colorize(_text!)),
                  ),
                ),
    );
  }

  TextSpan _colorize(String diff) {
    final spans = <TextSpan>[];
    for (final line in diff.split('\n')) {
      Color color = AppTheme.terminalFg;
      if (line.startsWith('+') && !line.startsWith('+++')) {
        color = const Color(0xFF7EE0A2);
      } else if (line.startsWith('-') && !line.startsWith('---')) {
        color = const Color(0xFFFF8080);
      } else if (line.startsWith('@@')) {
        color = const Color(0xFF8B93FF);
      } else if (line.startsWith('diff ') ||
          line.startsWith('index ') ||
          line.startsWith('commit ') ||
          line.startsWith('Author:') ||
          line.startsWith('Date:')) {
        color = const Color(0xFF7C89A6);
      }
      spans.add(TextSpan(text: '$line\n', style: AppTheme.monoStyle.copyWith(color: color)));
    }
    return TextSpan(children: spans);
  }
}

// ---------------------------------------------------------------------------
// Small shared widgets
// ---------------------------------------------------------------------------

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurfaceVariant)),
                const Spacer(),
                if (trailing != null)
                  Text(trailing!,
                      style: TextStyle(fontSize: 12, color: scheme.outline)),
              ],
            ),
            const SizedBox(height: 4),
            child,
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}

class _CodeBadge extends StatelessWidget {
  const _CodeBadge({required this.code, required this.color});
  final String code;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(code,
          style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 12,
              fontFamily: AppTheme.monoFamily)),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(text,
            style: TextStyle(color: Theme.of(context).colorScheme.outline)),
      ),
    );
  }
}
