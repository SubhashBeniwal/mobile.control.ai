/// A daemon known to the app, built from a `register` frame and updated by
/// `daemon.offline` / re-`register`.
class Daemon {
  Daemon({
    required this.id,
    required this.name,
    required this.version,
    required this.os,
    required this.arch,
    required this.providers,
    required this.actions,
    this.online = true,
    this.lastSeen,
  });

  /// Relay routing id (top-level `daemon` field). Falls back to `daemon_id`
  /// from the register payload in Mode A where there is no routing field.
  final String id;
  final String name;
  final String version;
  final String os;
  final String arch;
  final List<String> providers;
  final List<String> actions;
  final bool online;
  final DateTime? lastSeen;

  /// Build from a `register` frame's payload. [routingId] is the top-level
  /// `daemon` field (Mode B); when absent we key by the payload's `daemon_id`.
  factory Daemon.fromRegister(Map<String, dynamic> payload, {String? routingId}) {
    List<String> strList(dynamic v) =>
        (v as List?)?.map((e) => e.toString()).toList() ?? const [];
    return Daemon(
      id: routingId ?? payload['daemon_id'] as String,
      name: payload['name'] as String? ?? payload['daemon_id'] as String? ?? 'unknown',
      version: payload['version'] as String? ?? '',
      os: payload['os'] as String? ?? '',
      arch: payload['arch'] as String? ?? '',
      providers: strList(payload['providers']),
      actions: strList(payload['actions']),
      online: true,
      lastSeen: DateTime.now(),
    );
  }

  bool supports(String action) => actions.isEmpty || actions.contains(action);

  /// Remote apps are gated on an explicit `stream.start` in `actions` (macOS
  /// desktop/cgo builds in v1), never on an empty action list.
  bool get supportsStreaming => actions.contains('stream.start');

  Daemon copyWith({bool? online, DateTime? lastSeen}) => Daemon(
        id: id,
        name: name,
        version: version,
        os: os,
        arch: arch,
        providers: providers,
        actions: actions,
        online: online ?? this.online,
        lastSeen: lastSeen ?? this.lastSeen,
      );
}
