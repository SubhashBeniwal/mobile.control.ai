import 'dart:convert';

/// The wire envelope every frame shares in both directions.
///
/// See the handoff contract: `{ type, id, payload, daemon, ts }`.
/// In Mode B (relay) the [daemon] field routes each frame to/from a daemon.
class Envelope {
  Envelope({
    required this.type,
    this.id,
    this.payload,
    this.daemon,
    this.ts,
  });

  final String type;
  final String? id;
  final dynamic payload;
  final String? daemon;
  final int? ts;

  factory Envelope.fromJson(Map<String, dynamic> json) => Envelope(
        type: json['type'] as String,
        id: json['id'] as String?,
        payload: json['payload'],
        daemon: json['daemon'] as String?,
        ts: (json['ts'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'type': type,
        if (id != null) 'id': id,
        if (payload != null) 'payload': payload,
        if (daemon != null) 'daemon': daemon,
        if (ts != null) 'ts': ts,
      };

  static Envelope decode(String frame) =>
      Envelope.fromJson(jsonDecode(frame) as Map<String, dynamic>);

  String encode() => jsonEncode(toJson());

  Map<String, dynamic>? get payloadMap =>
      payload is Map<String, dynamic> ? payload as Map<String, dynamic> : null;
}
