import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:aio_control/models/daemon.dart';
import 'package:aio_control/models/remote.dart';

void main() {
  test('StreamConfig parses the handoff example', () {
    final cfg = StreamConfig.fromJson({
      'supported': true,
      'ice_servers': [
        {'urls': ['stun:stun.l.google.com:19302']},
        {'urls': ['turn:relay:3478'], 'username': 'u', 'credential': 'p'},
      ],
      'permissions': {'screen_recording': true, 'accessibility': false},
      'defaults': {'max_fps': 30, 'max_size': 1600, 'bitrate_kbps': 4000},
      'max_sessions': 2,
    });
    expect(cfg.supported, isTrue);
    expect(cfg.iceServers, hasLength(2));
    expect(cfg.screenRecording, isTrue);
    expect(cfg.accessibility, isFalse);
    expect(cfg.hasTurn, isTrue);
    expect(cfg.maxSize, 1600);
  });

  test('StreamConfig with STUN only has no TURN', () {
    final cfg = StreamConfig.fromJson({
      'supported': true,
      'ice_servers': [
        {'urls': ['stun:stun.l.google.com:19302']},
      ],
    });
    expect(cfg.hasTurn, isFalse);
  });

  test('ScreenWindows keeps numeric window ids and on_screen', () {
    final w = ScreenWindows.fromJson({
      'windows': [
        {'id': 4721, 'app': 'Code', 'bundle_id': 'com.microsoft.VSCode', 'pid': 812,
         'title': 'main.go', 'width': 1512, 'height': 945, 'on_screen': true},
        {'id': 9, 'app': 'Brave Browser', 'title': '', 'width': 800, 'height': 600,
         'on_screen': false},
      ],
      'displays': [
        {'id': 1, 'width': 1512, 'height': 982},
      ],
    });
    expect(w.windows.first.id, 4721);
    expect(w.windows.last.onScreen, isFalse);
    expect(w.displays.single.height, 982);
  });

  test('app.list pins IDEs and browsers first', () {
    final apps = RemoteApp.listFrom({
      'apps': [
        {'name': 'Notes', 'path': '/Applications/Notes.app'},
        {'name': 'Brave Browser', 'path': '/Applications/Brave Browser.app'},
        {'name': 'Visual Studio Code', 'path': '/Applications/Visual Studio Code.app'},
      ],
    });
    expect(apps.map((a) => a.name),
        ['Brave Browser', 'Visual Studio Code', 'Notes']);
  });

  test('StreamError branches on the code prefix', () {
    final e = StreamError.parse('E_WINDOW_NOT_FOUND: window 1 not found');
    expect(e.code, StreamErrorCode.windowNotFound);
    expect(e.message, 'window 1 not found');
    expect(StreamError.parse('E_LIMIT: 2 sessions').code, StreamErrorCode.limit);
    expect(StreamError.parse('unknown action "stream.start"').code,
        StreamErrorCode.unsupported);
    final other = StreamError.parse('path outside workspaces');
    expect(other.code, StreamErrorCode.other);
    expect(other.friendly, 'path outside workspaces');
  });

  test('streaming is gated on an explicit stream.start', () {
    Daemon d(List<String> actions) => Daemon.fromRegister(
        {'daemon_id': 'm', 'actions': actions}, routingId: 'm');
    expect(d(['system.info', 'stream.start']).supportsStreaming, isTrue);
    expect(d(['system.info']).supportsStreaming, isFalse);
    expect(d([]).supportsStreaming, isFalse);
  });

  test('input messages match the data channel protocol', () {
    expect(RemoteInput.click(const Offset(0.42, 0.31)),
        {'t': 'click', 'x': 0.42, 'y': 0.31, 'b': 'left', 'n': 1});
    expect(RemoteInput.pointer('move', const Offset(0.5, 0.5)),
        {'t': 'pointer', 'a': 'move', 'x': 0.5, 'y': 0.5});
    expect(RemoteInput.pointer('down', const Offset(0.5, 0.5), b: MouseButton.right)['b'],
        'right');
    expect(RemoteInput.scroll(const Offset(0.1, 0.2), 0, 119.6)['dy'], 120);
    expect(RemoteInput.key('KeyP', mods: {KeyMod.shift, KeyMod.meta}),
        {'t': 'key', 'a': 'press', 'code': 'KeyP', 'mods': ['meta', 'shift']});
    expect(RemoteInput.key('Enter').containsKey('mods'), isFalse);
    expect(RemoteInput.text('hello wörld'), {'t': 'text', 's': 'hello wörld'});
  });

  test('codeForChar maps letters, digits and punctuation', () {
    expect(RemoteInput.codeForChar('s'), 'KeyS');
    expect(RemoteInput.codeForChar('S'), 'KeyS');
    expect(RemoteInput.codeForChar('7'), 'Digit7');
    expect(RemoteInput.codeForChar('`'), 'Backquote');
    expect(RemoteInput.codeForChar('ö'), isNull);
  });

  group('letterboxed coordinates', () {
    // A 1600×1000 video in a 400×800 portrait box: width-bound, scale 0.25,
    // so the frame is 400×250 centered with 275px bars top and bottom.
    const box = Size(400, 800);
    const video = Size(1600, 1000);

    test('containRect centers the frame', () {
      expect(containRect(box, video), const Rect.fromLTWH(0, 275, 400, 250));
    });

    test('points inside map to 0–1', () {
      expect(normalizeToVideo(const Offset(0, 275), box, video), Offset.zero);
      expect(normalizeToVideo(const Offset(200, 400), box, video), const Offset(0.5, 0.5));
      expect(normalizeToVideo(const Offset(400, 525), box, video), const Offset(1, 1));
    });

    test('letterbox bars are excluded unless clamped', () {
      expect(normalizeToVideo(const Offset(200, 100), box, video), isNull);
      expect(normalizeToVideo(const Offset(200, 100), box, video, clamp: true),
          const Offset(0.5, 0));
    });
  });
}
