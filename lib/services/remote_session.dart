import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/command.dart';
import '../models/remote.dart';

enum RemoteSessionPhase { starting, connecting, live, ended, failed }

/// Sends a command to the daemon and awaits its result (see AppState.request).
typedef RemoteRequest = Future<CommandResult> Function(
    String action, Map<String, dynamic> args);

/// One WebRTC stream of a window or display on the daemon's Mac.
///
/// The phone is the offerer: it adds a recv-only video transceiver and the
/// `input` data channel, gathers ICE fully (no trickle, 3 s cap), and sends the
/// offer via `stream.start`; the result carries the answer. Video and input
/// then flow peer-to-peer, never over the relay.
class RemoteSession extends ChangeNotifier {
  RemoteSession({
    required this.request,
    required this.config,
    required this.target,
    this.onOpened,
    this.onClosed,
  });

  final RemoteRequest request;
  final StreamConfig config;

  /// `{ "window_id": n }` or `{ "display_id": n }`.
  final Map<String, dynamic> target;

  /// Called once the daemon accepted the session, and once when it ends.
  final VoidCallback? onOpened;
  final VoidCallback? onClosed;

  final RTCVideoRenderer renderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  RTCDataChannel? _input;

  RemoteSessionPhase phase = RemoteSessionPhase.starting;
  String? sessionId;

  /// Set when [phase] is failed or ended.
  StreamError? error;
  String? endReason;

  /// Latest video pixel size (from the result, then `hello`/`size`).
  Size videoSize = Size.zero;

  /// From `hello`: false means Accessibility isn't granted and input is ignored.
  bool? inputEnabled;
  bool get inputOpen => _input?.state == RTCDataChannelState.RTCDataChannelOpen;

  bool _stopped = false;
  bool _opened = false;
  bool _disposed = false;

  bool get isActive =>
      phase != RemoteSessionPhase.ended && phase != RemoteSessionPhase.failed;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _set(VoidCallback fn) {
    fn();
    _notify();
  }

  Future<void> start() async {
    try {
      await renderer.initialize();
      renderer.onResize = () {
        if (videoSize == Size.zero && renderer.videoWidth > 0) {
          _set(() => videoSize =
              Size(renderer.videoWidth.toDouble(), renderer.videoHeight.toDouble()));
        }
      };

      final pc = await createPeerConnection({
        'iceServers': config.iceServers,
        'sdpSemantics': 'unified-plan',
      });
      _pc = pc;

      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      final input = await pc.createDataChannel('input', RTCDataChannelInit()..ordered = true);
      _input = input;
      input.onMessage = _onInputMessage;
      input.onDataChannelState = (_) => _notify();

      pc.onTrack = (e) {
        if (e.track.kind == 'video' && e.streams.isNotEmpty) {
          renderer.srcObject = e.streams.first;
          _set(() => phase = RemoteSessionPhase.live);
        }
      };
      pc.onConnectionState = (s) {
        switch (s) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _set(() => phase = RemoteSessionPhase.live);
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _fail(StreamError(
              StreamErrorCode.other,
              config.hasTurn
                  ? 'Lost the connection to the Mac.'
                  : 'Couldn\'t connect directly to the Mac. Join the phone and Mac to '
                      'the same Wi-Fi (one without a sign-in page or client '
                      'isolation). Other networks need a TURN server, which isn\'t '
                      'configured yet.',
            ));
          default:
            break;
        }
      };

      final gathered = Completer<void>();
      pc.onIceGatheringState = (s) {
        if (s == RTCIceGatheringState.RTCIceGatheringStateComplete && !gathered.isCompleted) {
          gathered.complete();
        }
      };
      await pc.setLocalDescription(await pc.createOffer());
      await gathered.future.timeout(const Duration(seconds: 3), onTimeout: () {});
      final offer = await pc.getLocalDescription();
      if (offer == null || offer.sdp == null) {
        throw StateError('No local description');
      }
      if (_stopped) return;

      final res = await request('stream.start', {
        'target': target,
        'offer': {'type': offer.type, 'sdp': offer.sdp},
        'max_fps': config.maxFps,
        'max_size': config.maxSize,
        'bitrate_kbps': config.bitrateKbps,
      });

      if (!res.ok) {
        _fail(StreamError.parse(res.error));
        return;
      }
      final data = res.data as Map? ?? const {};
      sessionId = data['session_id'] as String?;

      // The user may have left while we waited for the answer.
      if (_stopped) {
        _sendStop();
        return;
      }
      _opened = true;
      onOpened?.call();

      final w = (data['width'] as num?)?.toDouble() ?? 0;
      final h = (data['height'] as num?)?.toDouble() ?? 0;
      if (w > 0 && h > 0) videoSize = Size(w, h);

      final answer = data['answer'] as Map? ?? const {};
      await pc.setRemoteDescription(
        RTCSessionDescription(answer['sdp'] as String?, answer['type'] as String? ?? 'answer'),
      );
      if (phase == RemoteSessionPhase.starting) {
        _set(() => phase = RemoteSessionPhase.connecting);
      }
    } catch (e) {
      _fail(StreamError(StreamErrorCode.other, 'Couldn\'t start the stream: $e'));
    }
  }

  void _onInputMessage(RTCDataChannelMessage m) {
    if (m.isBinary) return;
    final Map<String, dynamic> ev;
    try {
      ev = jsonDecode(m.text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (ev['t']) {
      case 'hello':
        _set(() {
          inputEnabled = ev['input'] as bool? ?? true;
          _applySize(ev);
        });
      case 'size':
        _set(() => _applySize(ev));
      case 'end':
        end(ev['reason'] as String? ?? 'The Mac ended the session');
      default:
        // Unknown message types are ignored.
        break;
    }
  }

  void _applySize(Map<String, dynamic> ev) {
    final w = (ev['w'] as num?)?.toDouble() ?? 0;
    final h = (ev['h'] as num?)?.toDouble() ?? 0;
    if (w > 0 && h > 0) videoSize = Size(w, h);
  }

  /// Send one input message (see [RemoteInput]). Dropped if the channel isn't open.
  void send(Map<String, dynamic> msg) {
    final ch = _input;
    if (ch == null || !inputOpen) return;
    ch.send(RTCDataChannelMessage(jsonEncode(msg)));
  }

  void _fail(StreamError e) {
    if (!isActive) return;
    error = e;
    phase = RemoteSessionPhase.failed;
    _notify();
    _teardown(sendStop: true);
  }

  /// The session ended on its own (daemon `end`, daemon offline).
  void end(String reason) {
    if (!isActive) return;
    endReason = reason;
    phase = RemoteSessionPhase.ended;
    _notify();
    _teardown(sendStop: false);
  }

  /// The user is leaving: tell the daemon and close the peer connection.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    if (isActive) phase = RemoteSessionPhase.ended;
    await _teardown(sendStop: true);
  }

  void _sendStop() {
    final id = sessionId;
    if (id != null) request('stream.stop', {'session_id': id});
  }

  bool _tornDown = false;
  Future<void> _teardown({required bool sendStop}) async {
    if (_tornDown) return;
    _tornDown = true;
    if (sendStop) _sendStop();
    try {
      await _input?.close();
    } catch (_) {}
    try {
      await _pc?.close();
    } catch (_) {}
    _input = null;
    _pc = null;
    renderer.srcObject = null;
    // Runs after an await, so it's safe even when stop() came from dispose().
    if (_opened) onClosed?.call();
  }

  @override
  void dispose() {
    _disposed = true;
    stop().whenComplete(renderer.dispose);
    super.dispose();
  }
}
