import 'dart:async';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../models/envelope.dart';

enum RelayConnectionState { disconnected, connecting, connected }

/// Mode B relay client: a plain WebSocket client that dials OUT to the relay's
/// `/control` endpoint with a bearer token, streams decoded [Envelope]s, and
/// reconnects with exponential backoff. Heartbeat PINGs are auto-ponged by the
/// underlying socket, so nothing to do here.
class RelayClient {
  RelayClient();

  IOWebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  bool _wantConnected = false;
  int _backoffMs = _minBackoffMs;

  String _url = '';
  String _token = '';

  static const _minBackoffMs = 1000;
  static const _maxBackoffMs = 30000;

  final _frames = StreamController<Envelope>.broadcast();
  final _state = StreamController<RelayConnectionState>.broadcast();

  /// Decoded frames from the relay.
  Stream<Envelope> get frames => _frames.stream;

  /// Connection lifecycle updates.
  Stream<RelayConnectionState> get connectionState => _state.stream;

  RelayConnectionState _current = RelayConnectionState.disconnected;
  RelayConnectionState get current => _current;

  String? lastError;

  void _setState(RelayConnectionState s) {
    _current = s;
    if (!_state.isClosed) _state.add(s);
  }

  /// Connect (or reconnect) to [url] with [token]. Idempotent for the same
  /// target; changing target reconnects.
  void connect({required String url, required String token}) {
    _url = url;
    _token = token;
    _wantConnected = true;
    _backoffMs = _minBackoffMs;
    _openSocket();
  }

  Future<void> _openSocket() async {
    _reconnectTimer?.cancel();
    _cleanupSocket();

    if (_url.trim().isEmpty) {
      lastError = 'Relay URL is not set';
      _setState(RelayConnectionState.disconnected);
      return;
    }

    _setState(RelayConnectionState.connecting);

    final Uri uri;
    try {
      uri = Uri.parse(_url);
    } catch (e) {
      lastError = 'Invalid relay URL: $e';
      _scheduleReconnect();
      return;
    }

    final headers = <String, dynamic>{};
    if (_token.isNotEmpty) headers['Authorization'] = 'Bearer $_token';

    final channel = IOWebSocketChannel.connect(
      uri,
      headers: headers,
      pingInterval: const Duration(seconds: 20),
    );
    _channel = channel;

    // Swallow a sink-side error so a failed handshake doesn't escape as an
    // unhandled exception; the same failure is handled via `ready` below.
    channel.sink.done.catchError((_) {});

    try {
      // Resolves when the socket is actually open; throws on connection
      // refused / DNS failure / 401 handshake rejection.
      await channel.ready;
    } catch (e) {
      lastError = _describe(e);
      // A newer connect attempt may have superseded this one.
      if (identical(_channel, channel)) _scheduleReconnect();
      return;
    }

    // Guard against a race where a newer attempt replaced this channel while
    // we were awaiting `ready`.
    if (!identical(_channel, channel)) {
      try {
        channel.sink.close(ws_status.normalClosure);
      } catch (_) {}
      return;
    }

    _sub = channel.stream.listen(
      _onFrame,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    );

    _setState(RelayConnectionState.connected);
    lastError = null;
    _backoffMs = _minBackoffMs;
  }

  String _describe(Object e) {
    final s = e.toString();
    if (s.contains('Connection refused')) {
      return 'Connection refused — is the relay running at $_url?';
    }
    return s;
  }

  void _onFrame(dynamic frame) {
    if (frame is! String) return;
    try {
      final env = Envelope.decode(frame);
      if (!_frames.isClosed) _frames.add(env);
    } catch (_) {
      // Ignore malformed frames rather than tearing down the connection.
    }
  }

  void _onError(Object error) {
    lastError = error.toString();
    _scheduleReconnect();
  }

  void _onDone() {
    // Surface the close code if the handshake was rejected (e.g. 401 auth).
    final code = _channel?.closeCode;
    if (code != null && lastError == null) {
      lastError = 'Connection closed (code $code)';
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _cleanupSocket();
    _setState(RelayConnectionState.disconnected);
    if (!_wantConnected) return;

    _reconnectTimer?.cancel();
    final delay = Duration(milliseconds: _backoffMs);
    _reconnectTimer = Timer(delay, _openSocket);
    _backoffMs = (_backoffMs * 2).clamp(_minBackoffMs, _maxBackoffMs);
  }

  /// Send a frame to the relay. Returns false if not connected.
  bool send(Envelope env) {
    final ch = _channel;
    if (ch == null || _current != RelayConnectionState.connected) return false;
    ch.sink.add(env.encode());
    return true;
  }

  void _cleanupSocket() {
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close(ws_status.normalClosure);
    } catch (_) {}
    _channel = null;
  }

  /// Stop and do not reconnect.
  void disconnect() {
    _wantConnected = false;
    _reconnectTimer?.cancel();
    _cleanupSocket();
    _setState(RelayConnectionState.disconnected);
  }

  void dispose() {
    disconnect();
    _frames.close();
    _state.close();
  }
}
