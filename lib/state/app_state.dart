import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/command.dart';
import '../models/daemon.dart';
import '../models/envelope.dart';
import '../models/file_entry.dart';
import '../services/relay_client.dart';
import '../services/settings_store.dart';

/// Owns the relay connection, the set of known daemons, and the history of
/// dispatched commands. Routes every incoming frame by its `daemon` id (which
/// daemon) and `id` (which command).
class AppState extends ChangeNotifier {
  AppState({SettingsStore? settingsStore, RelayClient? client})
      : _settingsStore = settingsStore ?? SettingsStore(),
        _client = client ?? RelayClient() {
    _frameSub = _client.frames.listen(_onFrame);
    _stateSub = _client.connectionState.listen((s) {
      _connection = s;
      notifyListeners();
    });
  }

  final SettingsStore _settingsStore;
  final RelayClient _client;
  final _uuid = const Uuid();

  late StreamSubscription _frameSub;
  late StreamSubscription _stateSub;

  RelaySettings _settings = const RelaySettings(
    relayUrl: SettingsStore.defaultRelayUrl,
    controlToken: SettingsStore.defaultControlToken,
  );
  RelaySettings get settings => _settings;

  RelayConnectionState _connection = RelayConnectionState.disconnected;
  RelayConnectionState get connection => _connection;
  String? get lastError => _client.lastError;

  // Daemons keyed by routing id, insertion-ordered.
  final Map<String, Daemon> _daemons = {};
  List<Daemon> get daemons => _daemons.values.toList(growable: false);

  String? _selectedDaemonId;
  String? get selectedDaemonId => _selectedDaemonId;
  Daemon? get selectedDaemon =>
      _selectedDaemonId == null ? null : _daemons[_selectedDaemonId];

  // Remembered working directory per daemon (drives the terminal + action forms).
  final Map<String, String> _workdirs = {};
  String workdirFor(String daemonId) => _workdirs[daemonId] ?? '';
  void setWorkdir(String daemonId, String dir) {
    _workdirs[daemonId] = dir;
    notifyListeners();
  }

  // Completers for callers awaiting a specific command's terminal result.
  final Map<String, Completer<CommandResult>> _pending = {};

  // Untracked shell runs that capture streamed stdout/stderr (e.g. metrics).
  final Map<String, _ShellCollector> _shellRuns = {};

  // Commands keyed by correlation id, plus insertion order for the history list.
  final Map<String, CommandRun> _commands = {};
  final List<String> _commandOrder = [];
  List<CommandRun> get commands =>
      _commandOrder.reversed.map((id) => _commands[id]!).toList(growable: false);

  List<CommandRun> commandsFor(String daemonId) => _commandOrder.reversed
      .map((id) => _commands[id]!)
      .where((c) => c.daemonId == daemonId)
      .toList(growable: false);

  // Remote stream input mode, remembered across launches.
  bool _remoteTrackpad = false;
  bool get remoteTrackpad => _remoteTrackpad;

  void setRemoteTrackpad(bool on) {
    _remoteTrackpad = on;
    notifyListeners();
    _settingsStore.saveRemoteTrackpad(on);
  }

  Future<void> init() async {
    _settings = await _settingsStore.load();
    _remoteTrackpad = await _settingsStore.loadRemoteTrackpad();
    notifyListeners();
    if (_settings.isConfigured) connect();
  }

  Future<void> updateSettings(RelaySettings s) async {
    _settings = s;
    await _settingsStore.save(s);
    notifyListeners();
    connect();
  }

  void connect() {
    _client.connect(url: _settings.relayUrl, token: _settings.controlToken);
  }

  void disconnect() => _client.disconnect();

  bool get isConnected => _connection == RelayConnectionState.connected;

  void selectDaemon(String? id) {
    _selectedDaemonId = id;
    notifyListeners();
  }

  // ---- incoming frame routing -------------------------------------------

  void _onFrame(Envelope env) {
    switch (env.type) {
      case 'register':
        _onRegister(env);
        break;
      case 'daemon.offline':
        _onDaemonOffline(env);
        break;
      case 'ack':
        _markAlive(env.daemon);
        _withCommand(env.id, (c) => c.markRunning());
        break;
      case 'log':
        _markAlive(env.daemon);
        final p = env.payloadMap;
        if (p != null) {
          _withCommand(env.id, (c) => c.addLog(LogLine.fromPayload(p)));
          final col = env.id == null ? null : _shellRuns[env.id];
          if (col != null && p['stream'] == 'stdout') {
            col.stdout.writeln(p['data'] ?? '');
          }
        }
        break;
      case 'result':
        final p = env.payloadMap;
        if (p != null) {
          final result = CommandResult.fromPayload(p);
          _withCommand(env.id, (c) => c.finish(result));
          _pending.remove(env.id)?.complete(result);
          final col = _shellRuns.remove(env.id);
          col?.completer.complete(ShellOutput(
            ok: result.ok,
            stdout: col.stdout.toString(),
            error: result.error,
            exitCode: result.exitCode,
          ));
        }
        break;
      default:
        // Unknown frame types are ignored.
        break;
    }
  }

  void _onRegister(Envelope env) {
    final p = env.payloadMap;
    if (p == null) return;
    final daemon = Daemon.fromRegister(p, routingId: env.daemon);
    _daemons[daemon.id] = daemon;
    _selectedDaemonId ??= daemon.id;
    notifyListeners();
  }

  /// An `ack`/`log` can only come from a connected daemon, so it overrides a
  /// stale `daemon.offline`. When a daemon reconnects (e.g. after a network
  /// switch), the relay can deliver the old connection's `daemon.offline`
  /// after the new connection's `register`.
  void _markAlive(String? id) {
    final existing = id == null ? null : _daemons[id];
    if (existing == null || existing.online) return;
    _daemons[id!] = existing.copyWith(online: true, lastSeen: DateTime.now());
    notifyListeners();
  }

  void _onDaemonOffline(Envelope env) {
    final id = env.daemon;
    if (id == null) return;
    final existing = _daemons[id];
    if (existing != null) {
      _daemons[id] = existing.copyWith(online: false, lastSeen: DateTime.now());
      notifyListeners();
    }
  }

  void _withCommand(String? id, void Function(CommandRun) fn) {
    if (id == null) return;
    final cmd = _commands[id];
    if (cmd == null) return;
    fn(cmd);
    notifyListeners();
  }

  // ---- outgoing dispatch -------------------------------------------------

  /// Dispatch [action] to [daemonId] with [args]. Returns the tracked run, or
  /// null if the frame could not be sent (not connected).
  CommandRun? dispatch({
    required String daemonId,
    required String action,
    Map<String, dynamic> args = const {},
    bool track = true,
  }) {
    final id = 'c-${_uuid.v4()}';
    final run = CommandRun(
      id: id,
      daemonId: daemonId,
      action: action,
      args: args,
      createdAt: DateTime.now(),
    );

    final env = Envelope(
      type: 'command',
      id: id,
      daemon: daemonId,
      payload: {
        'id': id,
        'action': action,
        if (args.isNotEmpty) 'payload': args,
      },
      ts: DateTime.now().millisecondsSinceEpoch,
    );

    final sent = _client.send(env);
    if (!sent) return null;

    // Untracked commands (e.g. terminal `cd` validation, workspace probing)
    // still route their result via the completer but stay out of history.
    if (track) {
      _commands[id] = run;
      _commandOrder.add(id);
    }
    notifyListeners();
    return run;
  }

  /// Dispatch and await the terminal [CommandResult]. Returns null if the frame
  /// couldn't be sent (not connected).
  Future<CommandResult>? dispatchAwait({
    required String daemonId,
    required String action,
    Map<String, dynamic> args = const {},
  }) {
    final run = dispatch(daemonId: daemonId, action: action, args: args, track: false);
    if (run == null) return null;
    final completer = Completer<CommandResult>();
    _pending[run.id] = completer;
    return completer.future;
  }

  /// Dispatch untracked and await the result, failing with an error result
  /// instead of hanging if not connected or no reply arrives within [timeout].
  Future<CommandResult> request(
    String daemonId,
    String action, {
    Map<String, dynamic> args = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final run = dispatch(daemonId: daemonId, action: action, args: args, track: false);
    if (run == null) return CommandResult(ok: false, error: 'Not connected');
    final completer = Completer<CommandResult>();
    _pending[run.id] = completer;
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(run.id);
      return CommandResult(ok: false, error: 'No response from daemon ($action timed out)');
    });
  }

  // ---- remote app streams --------------------------------------------------

  // Live WebRTC sessions per daemon, for the "streaming" indicator.
  final Map<String, int> _liveStreams = {};
  int liveStreams(String daemonId) => _liveStreams[daemonId] ?? 0;

  void streamOpened(String daemonId) {
    _liveStreams[daemonId] = liveStreams(daemonId) + 1;
    notifyListeners();
  }

  void streamClosed(String daemonId) {
    final n = liveStreams(daemonId) - 1;
    if (n <= 0) {
      _liveStreams.remove(daemonId);
    } else {
      _liveStreams[daemonId] = n;
    }
    notifyListeners();
  }

  // ---- typed filesystem / repo helpers (all untracked) ------------------

  /// Fetch the daemon's allowed workspace roots via `system.info`.
  Future<List<String>> fetchWorkspaces(String daemonId) async {
    final f = dispatchAwait(daemonId: daemonId, action: 'system.info');
    if (f == null) return const [];
    final data = (await f).data;
    if (data is Map && data['workspaces'] is List) {
      return (data['workspaces'] as List).map((e) => e.toString()).toList();
    }
    return const [];
  }

  /// List a directory. Entries are sorted directories-first, then by name.
  Future<DirListing> listDir(String daemonId, String path) async {
    final f = dispatchAwait(daemonId: daemonId, action: 'file.list', args: {'path': path});
    if (f == null) return DirListing.failure(path, 'Not connected');
    final r = await f;
    if (!r.ok) return DirListing.failure(path, r.error);
    final data = r.data;
    final list = (data is Map && data['entries'] is List)
        ? (data['entries'] as List).map(FileEntry.fromJson).toList()
        : <FileEntry>[];
    list.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return DirListing(ok: true, path: path, entries: list);
  }

  /// Read a file's contents.
  Future<FileContent> readFile(String daemonId, String path) async {
    final f = dispatchAwait(daemonId: daemonId, action: 'file.read', args: {'path': path});
    if (f == null) return FileContent.failure(path, 'Not connected');
    final r = await f;
    if (!r.ok) return FileContent.failure(path, r.error);
    final data = r.data as Map?;
    return FileContent(
      ok: true,
      path: data?['path'] as String? ?? path,
      size: (data?['size'] as num?)?.toInt() ?? 0,
      content: data?['content'] as String? ?? '',
    );
  }

  /// Write a file's contents. Returns the terminal result (null if not sent).
  Future<CommandResult>? writeFile(String daemonId, String path, String content) {
    return dispatchAwait(
      daemonId: daemonId,
      action: 'file.write',
      args: {'path': path, 'content': content},
    );
  }

  /// Find git repositories under the given roots (directories containing .git).
  Future<List<String>> findRepos(String daemonId, List<String> roots) async {
    if (roots.isEmpty) return const [];
    final quoted = roots.map((r) => '"$r"').join(' ');
    final cmd =
        'for r in $quoted; do find "\$r" -maxdepth 3 -type d -name .git -prune 2>/dev/null; done';
    final f = runShell(daemonId: daemonId, command: cmd, workdir: roots.first);
    if (f == null) return const [];
    final out = await f;
    final repos = out.stdout
        .split('\n')
        .where((l) => l.trim().endsWith('/.git'))
        .map((l) => l.trim().substring(0, l.trim().length - '/.git'.length))
        .toList();
    repos.sort((a, b) => a.split('/').last.compareTo(b.split('/').last));
    return repos;
  }

  /// Run `git -C <repo> <args>` via shell and capture stdout (read-only queries).
  Future<ShellOutput>? runGit(String daemonId, String repo, String args) {
    return runShell(daemonId: daemonId, command: 'git -C "$repo" $args', workdir: repo);
  }

  /// Run a shell command via `deploy` and capture its streamed stdout, without
  /// recording it in the command history. Returns null if not connected.
  Future<ShellOutput>? runShell({
    required String daemonId,
    required String command,
    required String workdir,
  }) {
    final run = dispatch(
      daemonId: daemonId,
      action: 'deploy',
      args: {'workdir': workdir, 'command': command, 'shell': true},
      track: false,
    );
    if (run == null) return null;
    final collector = _ShellCollector();
    _shellRuns[run.id] = collector;
    return collector.completer.future;
  }

  /// Ask the daemon to cancel an in-flight command.
  void cancel(CommandRun run) {
    dispatch(
      daemonId: run.daemonId,
      action: 'command.cancel',
      args: {'id': run.id},
    );
  }

  @override
  void dispose() {
    _frameSub.cancel();
    _stateSub.cancel();
    _client.dispose();
    super.dispose();
  }
}

/// Captured output of a one-off shell run (see [AppState.runShell]).
class ShellOutput {
  ShellOutput({
    required this.ok,
    required this.stdout,
    required this.error,
    required this.exitCode,
  });

  final bool ok;
  final String stdout;
  final String error;
  final int? exitCode;
}

class _ShellCollector {
  final StringBuffer stdout = StringBuffer();
  final Completer<ShellOutput> completer = Completer<ShellOutput>();
}
