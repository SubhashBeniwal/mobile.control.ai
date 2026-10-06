/// One line of streamed output from a running command.
class LogLine {
  LogLine(this.stream, this.data, this.at);

  /// "stdout" | "stderr" | "system"
  final String stream;
  final String data;
  final DateTime at;

  factory LogLine.fromPayload(Map<String, dynamic> payload) => LogLine(
        payload['stream'] as String? ?? 'stdout',
        payload['data'] as String? ?? '',
        DateTime.now(),
      );
}

enum CommandStatus { pending, running, done, error }

/// The terminal `result` payload for a command.
class CommandResult {
  CommandResult({
    required this.ok,
    this.data,
    this.error = '',
    this.exitCode,
  });

  final bool ok;
  final dynamic data;
  final String error;
  final int? exitCode;

  factory CommandResult.fromPayload(Map<String, dynamic> payload) => CommandResult(
        ok: payload['ok'] as bool? ?? false,
        data: payload['data'],
        error: payload['error'] as String? ?? '',
        exitCode: (payload['exit_code'] as num?)?.toInt(),
      );
}

/// A command the app dispatched, tracked by its correlation `id` through the
/// ack → log* → result lifecycle.
class CommandRun {
  CommandRun({
    required this.id,
    required this.daemonId,
    required this.action,
    required this.args,
    required this.createdAt,
  });

  final String id;
  final String daemonId;
  final String action;
  final Map<String, dynamic> args;
  final DateTime createdAt;

  CommandStatus status = CommandStatus.pending;
  final List<LogLine> logs = [];
  CommandResult? result;
  DateTime? finishedAt;

  String get title => action;

  /// Wall-clock duration once finished, else elapsed so far.
  Duration get elapsed => (finishedAt ?? DateTime.now()).difference(createdAt);

  bool get isActive =>
      status == CommandStatus.pending || status == CommandStatus.running;

  void markRunning() {
    if (status == CommandStatus.pending) status = CommandStatus.running;
  }

  void addLog(LogLine line) {
    markRunning();
    logs.add(line);
  }

  void finish(CommandResult r) {
    result = r;
    finishedAt = DateTime.now();
    status = r.ok ? CommandStatus.done : CommandStatus.error;
  }
}
