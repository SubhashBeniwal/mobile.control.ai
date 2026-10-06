import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// Lists git repositories found under the daemon's workspaces and opens the
/// chosen one with [onOpen] (used by both the Git and PR flows).
class RepoPickerScreen extends StatefulWidget {
  const RepoPickerScreen({
    super.key,
    required this.daemonId,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onOpen,
  });

  final String daemonId;
  final String title;
  final String subtitle;
  final IconData icon;
  final void Function(BuildContext context, String repo) onOpen;

  @override
  State<RepoPickerScreen> createState() => _RepoPickerScreenState();
}

class _RepoPickerScreenState extends State<RepoPickerScreen> {
  List<String>? _repos;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _repos = null;
      _error = null;
    });
    final app = context.read<AppState>();
    final roots = await app.fetchWorkspaces(widget.daemonId);
    if (!mounted) return;
    if (roots.isEmpty) {
      setState(() => _error = 'No workspaces available on this daemon');
      return;
    }
    final repos = await app.findRepos(widget.daemonId, roots);
    if (!mounted) return;
    setState(() => _repos = repos);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _error != null
            ? _center(Text(_error!))
            : _repos == null
                ? _center(const CircularProgressIndicator())
                : _repos!.isEmpty
                    ? _center(const Text('No git repositories found'))
                    : ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: _repos!.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final repo = _repos![i];
                          final name = repo.split('/').last;
                          final parent =
                              repo.substring(0, repo.length - name.length);
                          return Card(
                            child: ListTile(
                              leading: Container(
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(
                                  color: scheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: Icon(widget.icon,
                                    color: scheme.onPrimaryContainer, size: 22),
                              ),
                              title: Text(name,
                                  style: const TextStyle(fontWeight: FontWeight.w700)),
                              subtitle: Text(parent,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11.5, color: scheme.outline)),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => widget.onOpen(context, repo),
                            ),
                          );
                        },
                      ),
      ),
    );
  }

  Widget _center(Widget child) => ListView(
        children: [
          SizedBox(
              height: MediaQuery.of(context).size.height * 0.7,
              child: Center(child: child)),
        ],
      );
}
