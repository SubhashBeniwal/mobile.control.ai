import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/daemon.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'command_screen.dart';
import 'repo_picker.dart';

/// Entry point: pick a repo, then open its Pull Requests.
void openPr(BuildContext context, String daemonId) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => RepoPickerScreen(
      daemonId: daemonId,
      title: 'Pull Requests',
      subtitle: 'Pick a repository',
      icon: Icons.merge,
      onOpen: (ctx, repo) => Navigator.of(ctx).push(MaterialPageRoute(
        builder: (_) => PrRepoScreen(daemonId: daemonId, repo: repo),
      )),
    ),
  ));
}

enum _GhState { checking, ok, noAuth, noGh, error }

class PullRequest {
  PullRequest(this.number, this.title, this.author, this.state, this.branch, this.draft);
  final int number;
  final String title;
  final String author;
  final String state;
  final String branch;
  final bool draft;

  factory PullRequest.fromJson(Map<String, dynamic> j) => PullRequest(
        (j['number'] as num?)?.toInt() ?? 0,
        j['title'] as String? ?? '',
        (j['author'] is Map ? j['author']['login'] : j['author'])?.toString() ?? '',
        j['state'] as String? ?? '',
        j['headRefName'] as String? ?? '',
        j['isDraft'] as bool? ?? false,
      );
}

class PrRepoScreen extends StatefulWidget {
  const PrRepoScreen({super.key, required this.daemonId, required this.repo});
  final String daemonId;
  final String repo;

  @override
  State<PrRepoScreen> createState() => _PrRepoScreenState();
}

class _PrRepoScreenState extends State<PrRepoScreen> {
  _GhState _gh = _GhState.checking;
  String _ghMessage = '';
  List<PullRequest>? _prs;
  String? _error;

  String get _name => widget.repo.split('/').last;
  AppState get _app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() => _gh = _GhState.checking);
    final f = _app.runShell(
      daemonId: widget.daemonId,
      workdir: widget.repo,
      command:
          'if ! command -v gh >/dev/null 2>&1; then echo NOGH; elif ! gh auth status >/dev/null 2>&1; then echo NOAUTH; else echo OK; fi',
    );
    if (f == null) {
      setState(() {
        _gh = _GhState.error;
        _ghMessage = 'Not connected';
      });
      return;
    }
    final out = (await f).stdout.trim();
    if (!mounted) return;
    if (out.contains('NOGH')) {
      setState(() => _gh = _GhState.noGh);
    } else if (out.contains('NOAUTH')) {
      setState(() => _gh = _GhState.noAuth);
    } else if (out.contains('OK')) {
      setState(() => _gh = _GhState.ok);
      _loadPrs();
    } else {
      setState(() {
        _gh = _GhState.error;
        _ghMessage = out;
      });
    }
  }

  Future<void> _loadPrs() async {
    setState(() {
      _prs = null;
      _error = null;
    });
    final f = _app.runShell(
      daemonId: widget.daemonId,
      workdir: widget.repo,
      command:
          'gh pr list --state open --limit 30 --json number,title,author,state,headRefName,isDraft',
    );
    if (f == null) return;
    final out = await f;
    if (!mounted) return;
    if (!out.ok && out.stdout.trim().isEmpty) {
      setState(() => _error = out.error);
      return;
    }
    try {
      final list = jsonDecode(out.stdout.trim().isEmpty ? '[]' : out.stdout) as List;
      setState(() =>
          _prs = list.map((e) => PullRequest.fromJson(e as Map<String, dynamic>)).toList());
    } catch (e) {
      setState(() => _error = 'Could not parse PR list: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('$_name · PRs', overflow: TextOverflow.ellipsis),
        actions: [
          if (_gh == _GhState.ok)
            IconButton(onPressed: _loadPrs, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: switch (_gh) {
        _GhState.checking => const Center(child: CircularProgressIndicator()),
        _GhState.noGh => _GhGuidance(
            icon: Icons.download_for_offline_outlined,
            title: 'GitHub CLI not installed',
            message:
                'The daemon host needs the GitHub CLI (`gh`) to manage pull requests.\n\nInstall it on the host, e.g. `brew install gh`, then authenticate with `gh auth login`.',
            onRetry: _init,
          ),
        _GhState.noAuth => _GhGuidance(
            icon: Icons.key_off,
            title: 'GitHub CLI not authenticated',
            message: 'Run `gh auth login` on the daemon host, then retry.',
            onRetry: _init,
          ),
        _GhState.error => _GhGuidance(
            icon: Icons.error_outline,
            title: 'Could not check GitHub CLI',
            message: _ghMessage,
            onRetry: _init,
          ),
        _GhState.ok => _prList(),
      },
    );
  }

  Widget _prList() {
    if (_error != null) {
      return _GhGuidance(
          icon: Icons.error_outline, title: 'Error', message: _error!, onRetry: _loadPrs);
    }
    if (_prs == null) return const Center(child: CircularProgressIndicator());
    if (_prs!.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadPrs,
        child: ListView(children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.7,
            child: const Center(child: Text('No open pull requests')),
          ),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadPrs,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: _prs!.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _prCard(_prs![i]),
      ),
    );
  }

  Widget _prCard(PullRequest pr) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: Icon(pr.draft ? Icons.edit_note : Icons.merge,
            color: pr.draft ? scheme.outline : const Color(0xFF10B981)),
        title: Text(pr.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('#${pr.number} · ${pr.author} · ${pr.branch}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
        trailing: const Icon(Icons.chevron_right),
        isThreeLine: true,
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PrDetailScreen(
              daemonId: widget.daemonId, repo: widget.repo, pr: pr),
        )),
      ),
    );
  }
}

class PrDetailScreen extends StatefulWidget {
  const PrDetailScreen({
    super.key,
    required this.daemonId,
    required this.repo,
    required this.pr,
  });
  final String daemonId;
  final String repo;
  final PullRequest pr;

  @override
  State<PrDetailScreen> createState() => _PrDetailScreenState();
}

class _PrDetailScreenState extends State<PrDetailScreen> {
  String? _diff;
  AppState get _app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _loadDiff();
  }

  Future<void> _loadDiff() async {
    final f = _app.runShell(
      daemonId: widget.daemonId,
      workdir: widget.repo,
      command: 'gh pr diff ${widget.pr.number}',
    );
    if (f == null) return;
    final out = await f;
    if (!mounted) return;
    setState(() => _diff = out.stdout.isEmpty ? '(no diff)' : out.stdout);
  }

  Future<void> _shellTracked(String command, String label) async {
    final run = _app.dispatch(
      daemonId: widget.daemonId,
      action: 'deploy',
      args: {'workdir': widget.repo, 'command': command, 'shell': true},
    );
    if (run == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CommandScreen(commandId: run.id),
    ));
  }

  Future<void> _review() async {
    final daemon = _app.daemons.where((d) => d.id == widget.daemonId).firstOrNull;
    final provider = _pickProvider(daemon);
    final run = _app.dispatch(
      daemonId: widget.daemonId,
      action: 'pr.review',
      args: {
        'workdir': widget.repo,
        'number': widget.pr.number,
        'provider': ?provider,
      },
    );
    if (run == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CommandScreen(commandId: run.id),
    ));
  }

  String? _pickProvider(Daemon? d) =>
      (d != null && d.providers.isNotEmpty) ? d.providers.first : null;

  Future<void> _merge() async {
    final method = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Merge pull request', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            ListTile(
                leading: const Icon(Icons.merge_type),
                title: const Text('Squash and merge'),
                onTap: () => Navigator.of(ctx).pop('--squash')),
            ListTile(
                leading: const Icon(Icons.call_merge),
                title: const Text('Create a merge commit'),
                onTap: () => Navigator.of(ctx).pop('--merge')),
            ListTile(
                leading: const Icon(Icons.linear_scale),
                title: const Text('Rebase and merge'),
                onTap: () => Navigator.of(ctx).pop('--rebase')),
          ],
        ),
      ),
    );
    if (method == null) return;
    _shellTracked('gh pr merge ${widget.pr.number} $method', 'merge');
  }

  @override
  Widget build(BuildContext context) {
    final pr = widget.pr;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('#${pr.number}')),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: scheme.surfaceContainerHigh,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(pr.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 6),
                Text('${pr.author} wants to merge ${pr.branch}',
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                        onPressed: _review,
                        icon: const Icon(Icons.rate_review, size: 18),
                        label: const Text('AI review')),
                    FilledButton.tonalIcon(
                        onPressed: () => _shellTracked(
                            'gh pr checkout ${pr.number}', 'checkout'),
                        icon: const Icon(Icons.download, size: 18),
                        label: const Text('Checkout')),
                    FilledButton.icon(
                        onPressed: _merge,
                        icon: const Icon(Icons.merge, size: 18),
                        label: const Text('Merge')),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _diff == null
                ? const Center(child: CircularProgressIndicator())
                : Container(
                    color: AppTheme.terminalBg,
                    width: double.infinity,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(14),
                      child: SelectableText.rich(_colorizeDiff(_diff!)),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Colorize a unified diff into a rich [TextSpan].
TextSpan _colorizeDiff(String diff) {
  final spans = <TextSpan>[];
  for (final line in diff.split('\n')) {
    var color = AppTheme.terminalFg;
    if (line.startsWith('+') && !line.startsWith('+++')) {
      color = const Color(0xFF7EE0A2);
    } else if (line.startsWith('-') && !line.startsWith('---')) {
      color = const Color(0xFFFF8080);
    } else if (line.startsWith('@@')) {
      color = const Color(0xFF8B93FF);
    } else if (line.startsWith('diff ') || line.startsWith('index ')) {
      color = const Color(0xFF7C89A6);
    }
    spans.add(TextSpan(text: '$line\n', style: AppTheme.monoStyle.copyWith(color: color)));
  }
  return TextSpan(children: spans);
}

class _GhGuidance extends StatelessWidget {
  const _GhGuidance({
    required this.icon,
    required this.title,
    required this.message,
    required this.onRetry,
  });
  final IconData icon;
  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 54, color: scheme.outline),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
                onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
