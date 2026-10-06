// Typed models for the Remote apps (phase 2) actions: stream.config,
// screen.windows, app.list, stream.start, and the `input` data channel
// protocol. Mirrors the handoff "Remote apps" section.
import 'dart:ui';

int _int(dynamic v, [int fallback = 0]) => (v as num?)?.toInt() ?? fallback;

/// `stream.config` result: whether streaming works, ICE servers, permissions.
class StreamConfig {
  const StreamConfig({
    required this.supported,
    required this.iceServers,
    required this.screenRecording,
    required this.accessibility,
    this.maxFps = 30,
    this.maxSize = 1600,
    this.bitrateKbps = 4000,
    this.maxSessions = 2,
  });

  final bool supported;

  /// Passed straight into the RTCPeerConnection configuration; owned by the
  /// daemon (never hardcode TURN credentials in the app).
  final List<Map<String, dynamic>> iceServers;
  final bool screenRecording;
  final bool accessibility;
  final int maxFps;
  final int maxSize;
  final int bitrateKbps;
  final int maxSessions;

  bool get hasTurn => iceServers.any((s) {
        final urls = s['urls'];
        final list = urls is List ? urls : [urls];
        return list.any((u) => u.toString().startsWith('turn'));
      });

  factory StreamConfig.fromJson(Map<String, dynamic> json) {
    final perms = json['permissions'] as Map? ?? const {};
    final defaults = json['defaults'] as Map? ?? const {};
    return StreamConfig(
      supported: json['supported'] as bool? ?? false,
      iceServers: (json['ice_servers'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
      screenRecording: perms['screen_recording'] as bool? ?? false,
      accessibility: perms['accessibility'] as bool? ?? false,
      maxFps: _int(defaults['max_fps'], 30),
      maxSize: _int(defaults['max_size'], 1600),
      bitrateKbps: _int(defaults['bitrate_kbps'], 4000),
      maxSessions: _int(json['max_sessions'], 2),
    );
  }
}

/// A streamable app window from `screen.windows`.
class RemoteWindow {
  const RemoteWindow({
    required this.id,
    required this.app,
    required this.title,
    required this.width,
    required this.height,
    this.bundleId = '',
    this.pid = 0,
    this.onScreen = true,
  });

  /// macOS CGWindowID; passed back unchanged as `target.window_id`.
  final int id;
  final String app;
  final String bundleId;
  final int pid;
  final String title;
  final int width;
  final int height;

  /// False for minimized windows, which can't be streamed until restored.
  final bool onScreen;

  factory RemoteWindow.fromJson(Map<String, dynamic> json) => RemoteWindow(
        id: _int(json['id']),
        app: json['app'] as String? ?? '',
        bundleId: json['bundle_id'] as String? ?? '',
        pid: _int(json['pid']),
        title: json['title'] as String? ?? '',
        width: _int(json['width']),
        height: _int(json['height']),
        onScreen: json['on_screen'] as bool? ?? true,
      );
}

/// A whole display from `screen.windows`.
class RemoteDisplay {
  const RemoteDisplay({required this.id, required this.width, required this.height});

  final int id;
  final int width;
  final int height;

  factory RemoteDisplay.fromJson(Map<String, dynamic> json) => RemoteDisplay(
        id: _int(json['id']),
        width: _int(json['width']),
        height: _int(json['height']),
      );
}

class ScreenWindows {
  const ScreenWindows({required this.windows, required this.displays});

  final List<RemoteWindow> windows;
  final List<RemoteDisplay> displays;

  factory ScreenWindows.fromJson(Map<String, dynamic> json) => ScreenWindows(
        windows: (json['windows'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RemoteWindow.fromJson)
            .toList(),
        displays: (json['displays'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RemoteDisplay.fromJson)
            .toList(),
      );
}

/// An installed app from `app.list`.
class RemoteApp {
  const RemoteApp({required this.name, required this.path});

  final String name;
  final String path;

  // IDEs and browsers are pinned to the top of the launch picker.
  static const _pinnedKeywords = [
    'code', 'studio', 'intellij', 'xcode', 'cursor', 'zed', 'sublime',
    'webstorm', 'pycharm', 'goland', 'rider', 'fleet', 'terminal', 'iterm',
    'warp', 'brave', 'chrome', 'safari', 'firefox', 'arc', 'edge',
  ];

  bool get isPinned {
    final n = name.toLowerCase();
    return _pinnedKeywords.any(n.contains);
  }

  factory RemoteApp.fromJson(Map<String, dynamic> json) => RemoteApp(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
      );

  /// Parse an `app.list` result, pinned apps first, then alphabetical.
  static List<RemoteApp> listFrom(dynamic data) {
    final raw = data is Map ? data['apps'] as List? ?? const [] : const [];
    final apps = raw.whereType<Map<String, dynamic>>().map(RemoteApp.fromJson).toList();
    apps.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return apps;
  }
}

/// Error codes the daemon prefixes onto `result.error` for remote actions.
/// [unsupported] has no code: a daemon without streaming rejects the action
/// itself with `unknown action "<name>"`.
enum StreamErrorCode {
  unsupported('unknown action'),
  permissionScreen('E_PERMISSION_SCREEN'),
  windowNotFound('E_WINDOW_NOT_FOUND'),
  badOffer('E_BAD_OFFER'),
  limit('E_LIMIT'),
  notFound('E_NOT_FOUND'),
  other('');

  const StreamErrorCode(this.prefix);
  final String prefix;
}

class StreamError {
  const StreamError(this.code, this.message);

  final StreamErrorCode code;

  /// The error text with the code prefix stripped.
  final String message;

  static StreamError parse(String error) {
    if (error.startsWith('${StreamErrorCode.unsupported.prefix} ')) {
      return StreamError(StreamErrorCode.unsupported, error);
    }
    for (final c in StreamErrorCode.values) {
      if (c == StreamErrorCode.other || c == StreamErrorCode.unsupported) continue;
      if (error.startsWith('${c.prefix}:')) {
        return StreamError(c, error.substring(c.prefix.length + 1).trim());
      }
    }
    return StreamError(StreamErrorCode.other, error);
  }

  /// A user-facing explanation for the code.
  String get friendly => switch (code) {
        StreamErrorCode.unsupported => 'This daemon can\'t stream apps.',
        StreamErrorCode.permissionScreen =>
          'Screen Recording isn\'t granted on the Mac. Approve AIO Agent under '
              'System Settings → Privacy & Security → Screen Recording, then '
              'restart the app there.',
        StreamErrorCode.windowNotFound =>
          'That window was closed or minimized. Refresh the list and try again.',
        StreamErrorCode.badOffer =>
          'The Mac rejected this device\'s video offer (no H.264 support?). $message',
        StreamErrorCode.limit =>
          'Too many streams are open on this Mac. Close another stream first.',
        StreamErrorCode.notFound => message.isEmpty ? 'App not found.' : message,
        StreamErrorCode.other => message,
      };
}

/// Pointer buttons on the input channel.
enum MouseButton { left, right, middle }

/// Modifier keys on the input channel.
enum KeyMod {
  meta('⌘'),
  ctrl('⌃'),
  alt('⌥'),
  shift('⇧');

  const KeyMod(this.symbol);
  final String symbol;
}

/// Builders for `input` data channel messages (phone → daemon).
/// Coordinates are normalized 0–1 against the video frame.
class RemoteInput {
  RemoteInput._();

  static double _r(double v) => (v.clamp(0.0, 1.0) * 10000).roundToDouble() / 10000;

  static Map<String, dynamic> pointer(String a, Offset p, {MouseButton b = MouseButton.left}) => {
        't': 'pointer',
        'a': a,
        'x': _r(p.dx),
        'y': _r(p.dy),
        if (a != 'move') 'b': b.name,
      };

  static Map<String, dynamic> click(Offset p, {MouseButton b = MouseButton.left, int n = 1}) => {
        't': 'click',
        'x': _r(p.dx),
        'y': _r(p.dy),
        'b': b.name,
        'n': n,
      };

  static Map<String, dynamic> scroll(Offset p, double dx, double dy) => {
        't': 'scroll',
        'x': _r(p.dx),
        'y': _r(p.dy),
        'dx': dx.round(),
        'dy': dy.round(),
      };

  static Map<String, dynamic> key(String code, {Set<KeyMod> mods = const {}, String a = 'press'}) => {
        't': 'key',
        'a': a,
        'code': code,
        if (mods.isNotEmpty) 'mods': KeyMod.values.where(mods.contains).map((m) => m.name).toList(),
      };

  static Map<String, dynamic> text(String s) => {'t': 'text', 's': s};

  static const keyframe = {'t': 'keyframe'};

  /// The W3C `KeyboardEvent.code` for a typed character, used when a modifier
  /// is held (e.g. ⌘ + "s" → `KeyS`). Null when there's no simple mapping.
  static String? codeForChar(String ch) {
    if (ch.length != 1) return null;
    final c = ch.codeUnitAt(0);
    if (c >= 0x61 && c <= 0x7A) return 'Key${ch.toUpperCase()}';
    if (c >= 0x41 && c <= 0x5A) return 'Key$ch';
    if (c >= 0x30 && c <= 0x39) return 'Digit$ch';
    return const {
      ' ': 'Space', '-': 'Minus', '=': 'Equal', '[': 'BracketLeft',
      ']': 'BracketRight', '\\': 'Backslash', ';': 'Semicolon', "'": 'Quote',
      ',': 'Comma', '.': 'Period', '/': 'Slash', '`': 'Backquote',
    }[ch];
  }
}

/// The rect a [video]-sized frame occupies inside [box] with "contain" fit
/// (centered, letterboxed).
Rect containRect(Size box, Size video) {
  if (video.width <= 0 || video.height <= 0 || box.isEmpty) {
    return Offset.zero & box;
  }
  final scale = (box.width / video.width) < (box.height / video.height)
      ? box.width / video.width
      : box.height / video.height;
  final w = video.width * scale;
  final h = video.height * scale;
  return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
}

/// Normalize a point in [box] coordinates to 0–1 video coordinates, excluding
/// letterbox bars. Returns null if the point falls in a letterbox bar, unless
/// [clamp] is set (used mid-drag), which pins it to the nearest edge instead.
Offset? normalizeToVideo(Offset local, Size box, Size video, {bool clamp = false}) {
  final r = containRect(box, video);
  if (r.isEmpty) return null;
  final inside = local.dx >= r.left &&
      local.dx <= r.right &&
      local.dy >= r.top &&
      local.dy <= r.bottom;
  if (!inside && !clamp) return null;
  return Offset(
    ((local.dx - r.left) / r.width).clamp(0.0, 1.0),
    ((local.dy - r.top) / r.height).clamp(0.0, 1.0),
  );
}

/// Trackpad mode: move a normalized (0–1) [cursor] by a finger [delta] in
/// screen px. [videoRect] is the displayed video rect at zoom 1 and [zoom] the
/// local view zoom. Faster swipes move further (pointer acceleration), and
/// the result is clamped to the frame.
Offset moveCursor(Offset cursor, Offset delta, Rect videoRect, double zoom) {
  if (videoRect.width <= 0 || videoRect.height <= 0) return cursor;
  final speed = delta.distance;
  final accel = (1 + 0.06 * speed).clamp(1.0, 3.0);
  final next = cursor +
      Offset(
        delta.dx * accel / (videoRect.width * zoom),
        delta.dy * accel / (videoRect.height * zoom),
      );
  return Offset(next.dx.clamp(0.0, 1.0), next.dy.clamp(0.0, 1.0));
}

/// Where a normalized video point appears on screen, given the displayed video
/// rect at zoom 1 and the local zoom/pan (screen = content × zoom + offset).
Offset videoToScreen(Offset norm, Rect videoRect, double zoom, Offset offset) {
  final content = videoRect.topLeft +
      Offset(norm.dx * videoRect.width, norm.dy * videoRect.height);
  return content * zoom + offset;
}

/// What a stream shows: one window or a whole display, plus a display title.
class StreamTarget {
  const StreamTarget._(this.args, this.title, this.isDisplay);

  factory StreamTarget.window(RemoteWindow w) => StreamTarget._(
        {'window_id': w.id},
        w.title.isEmpty ? w.app : '${w.app} — ${w.title}',
        false,
      );

  factory StreamTarget.display(RemoteDisplay d) =>
      StreamTarget._({'display_id': d.id}, 'Display ${d.id}', true);

  /// The `stream.start` `target` payload.
  final Map<String, dynamic> args;
  final String title;
  final bool isDisplay;

  bool sameAs(StreamTarget other) =>
      isDisplay == other.isDisplay &&
      (args['window_id'] ?? args['display_id']) ==
          (other.args['window_id'] ?? other.args['display_id']);
}

/// The window after/before [current] in [windows] (on-screen only, wrapping),
/// for swiping between apps. Null if there's nowhere else to go.
RemoteWindow? adjacentWindow(List<RemoteWindow> windows, int currentId, {required bool next}) {
  final list = windows.where((w) => w.onScreen).toList();
  if (list.isEmpty) return null;
  final i = list.indexWhere((w) => w.id == currentId);
  if (i < 0) return list.first;
  if (list.length == 1) return null;
  return list[(i + (next ? 1 : -1)) % list.length];
}
