import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aio_control/models/remote.dart';
import 'package:aio_control/models/touch_interpreter.dart';

/// Drives a [TouchInterpreter] with a fake clock and records its gestures.
class _Harness {
  _Harness(this.async) {
    touch = TouchInterpreter(events.add);
  }

  final FakeAsync async;
  late final TouchInterpreter touch;
  final events = <TouchGesture>[];
  Duration t = Duration.zero;

  void wait(int ms) {
    async.elapse(Duration(milliseconds: ms));
    t += Duration(milliseconds: ms);
  }

  void down(int id, double x, double y) => touch.down(id, Offset(x, y), t);
  void move(int id, double x, double y) => touch.move(id, Offset(x, y), t);
  void up(int id, double x, double y) => touch.up(id, Offset(x, y), t);

  /// Move [ids] together by (dx, dy) in [steps] steps from their start points.
  void moveAll(Map<int, Offset> from, double dx, double dy, {int steps = 5}) {
    for (var i = 1; i <= steps; i++) {
      wait(10);
      from.forEach((id, p) => move(id, p.dx + dx * i / steps, p.dy + dy * i / steps));
    }
  }

  List<Type> get types => events.map((e) => e.runtimeType).toList();
}

void _run(void Function(_Harness h) body) => fakeAsync((async) => body(_Harness(async)));

void main() {
  test('quick tap → one-finger tap', () => _run((h) {
        h.down(1, 100, 100);
        h.wait(80);
        h.up(1, 101, 100);
        final tap = h.events.first as TapGesture;
        expect(tap.fingers, 1);
        expect(tap.count, 1);
        expect(tap.position, const Offset(100, 100));
      }));

  test('second tap within the gap → count 2, third starts over', () => _run((h) {
        for (var i = 0; i < 3; i++) {
          h.down(1, 100, 100);
          h.wait(60);
          h.up(1, 100, 100);
          h.wait(120);
        }
        final taps = h.events.whereType<TapGesture>().map((e) => e.count).toList();
        expect(taps, [1, 2, 1]);
      }));

  test('two-finger tap → tap with 2 fingers (fingers lift separately)', () => _run((h) {
        h.down(1, 100, 100);
        h.down(2, 160, 100);
        h.wait(90);
        h.up(1, 100, 100);
        h.wait(20);
        h.up(2, 160, 100);
        final tap = h.events.whereType<TapGesture>().single;
        expect(tap.fingers, 2);
      }));

  test('hold still → long press, release → long-press up', () => _run((h) {
        h.down(1, 50, 50);
        h.wait(500);
        expect(h.events.single, isA<LongPressGesture>());
        h.up(1, 50, 50);
        expect(h.types, [LongPressGesture, LongPressUpGesture, GestureEndGesture]);
      }));

  test('hold then move → held drag', () => _run((h) {
        h.down(1, 50, 50);
        h.wait(500);
        h.moveAll({1: const Offset(50, 50)}, 60, 0);
        h.up(1, 110, 50);
        final start = h.events.whereType<DragStartGesture>().single;
        expect(start.held, isTrue);
        expect(h.events.whereType<DragEndGesture>().single.held, isTrue);
        expect(h.events.whereType<TapGesture>(), isEmpty);
      }));

  test('one-finger move → drag start at the touch point, updates, end', () => _run((h) {
        h.down(1, 10, 10);
        h.moveAll({1: const Offset(10, 10)}, 100, 0);
        h.up(1, 110, 10);
        final start = h.events.whereType<DragStartGesture>().single;
        expect(start.position, const Offset(10, 10));
        expect(start.held, isFalse);
        final total = h.events
            .whereType<DragUpdateGesture>()
            .fold(Offset.zero, (a, e) => a + e.delta);
        expect(total.dx, closeTo(100, 0.001));
        expect(h.events.whereType<LongPressGesture>(), isEmpty);
      }));

  test('two fingers moving together → pan (scroll), not pinch', () => _run((h) {
        h.down(1, 100, 100);
        h.down(2, 200, 100);
        h.moveAll({1: const Offset(100, 100), 2: const Offset(200, 100)}, 0, -80);
        h.up(1, 100, 20);
        h.up(2, 200, 20);
        expect(h.events.whereType<PanGesture>(), isNotEmpty);
        expect(h.events.whereType<PinchGesture>(), isEmpty);
        final dy = h.events.whereType<PanGesture>().fold(0.0, (a, e) => a + e.delta.dy);
        expect(dy, closeTo(-80, 0.001));
      }));

  test('two fingers spreading → pinch with scale > 1', () => _run((h) {
        h.down(1, 100, 100);
        h.down(2, 140, 100);
        for (var i = 1; i <= 5; i++) {
          h.wait(10);
          h.move(1, 100.0 - 10 * i, 100);
          h.move(2, 140.0 + 10 * i, 100);
        }
        final scale = h.events
            .whereType<PinchGesture>()
            .fold(1.0, (a, e) => a * e.scale);
        expect(scale, greaterThan(2));
      }));

  test('three-finger swipe left → swipe with 3 fingers', () => _run((h) {
        final pts = {1: const Offset(200, 100), 2: const Offset(240, 100), 3: const Offset(280, 100)};
        pts.forEach((id, p) => h.down(id, p.dx, p.dy));
        h.moveAll(pts, -120, 5);
        pts.forEach((id, p) => h.up(id, p.dx - 120, p.dy + 5));
        final swipe = h.events.whereType<SwipeGesture>().single;
        expect(swipe.fingers, 3);
        expect(swipe.direction, SwipeDirection.left);
        expect(h.events.whereType<TapGesture>(), isEmpty);
        expect(h.events.whereType<DragStartGesture>(), isEmpty);
      }));

  test('four-finger swipe up → swipe with 4 fingers', () => _run((h) {
        final pts = {
          for (var i = 1; i <= 4; i++) i: Offset(100.0 + 30 * i, 300),
        };
        pts.forEach((id, p) => h.down(id, p.dx, p.dy));
        h.moveAll(pts, 0, -150);
        pts.forEach((id, p) => h.up(id, p.dx, p.dy - 150));
        final swipe = h.events.whereType<SwipeGesture>().single;
        expect(swipe.fingers, 4);
        expect(swipe.direction, SwipeDirection.up);
      }));

  test('staggered three-finger swipe sends no drag, scroll or pinch first', () => _run((h) {
        // Fingers land 20 ms apart while the hand is already moving.
        final pts = {1: const Offset(200, 300), 2: const Offset(240, 310), 3: const Offset(280, 300)};
        final cur = <int, Offset>{};
        for (final id in pts.keys) {
          h.down(id, pts[id]!.dx, pts[id]!.dy);
          cur[id] = pts[id]!;
          h.wait(10);
          cur.updateAll((id, p) => p + const Offset(-8, 0));
          cur.forEach((id, p) => h.move(id, p.dx, p.dy));
          h.wait(10);
          cur.updateAll((id, p) => p + const Offset(-8, 0));
          cur.forEach((id, p) => h.move(id, p.dx, p.dy));
        }
        h.moveAll(cur, -120, 0);
        cur.forEach((id, p) => h.up(id, p.dx - 120, p.dy));
        expect(h.events.whereType<SwipeGesture>().single.fingers, 3);
        expect(h.types, isNot(contains(DragStartGesture)));
        expect(h.types, isNot(contains(PanGesture)));
        expect(h.types, isNot(contains(PinchGesture)));
      }));

  test('a quick one-finger flick is still a drag, not a tap', () => _run((h) {
        h.down(1, 100, 100);
        h.wait(10);
        h.move(1, 130, 100);
        h.wait(10);
        h.up(1, 160, 100);
        expect(h.types, [DragStartGesture, DragUpdateGesture, DragEndGesture, GestureEndGesture]);
        expect((h.events[2] as DragEndGesture).position, const Offset(160, 100));
      }));

  test('a short three-finger wiggle is not a swipe', () => _run((h) {
        final pts = {1: const Offset(0, 0), 2: const Offset(40, 0), 3: const Offset(80, 0)};
        pts.forEach((id, p) => h.down(id, p.dx, p.dy));
        h.moveAll(pts, 30, 0);
        pts.forEach((id, p) => h.up(id, p.dx + 30, p.dy));
        expect(h.events.whereType<SwipeGesture>(), isEmpty);
      }));

  test('classifySwipe picks the dominant axis', () {
    expect(classifySwipe(const Offset(-80, 20), 60), SwipeDirection.left);
    expect(classifySwipe(const Offset(10, 90), 60), SwipeDirection.down);
    expect(classifySwipe(const Offset(30, 30), 60), isNull);
  });

  group('trackpad cursor', () {
    const rect = Rect.fromLTWH(0, 100, 400, 250);

    test('slow moves are 1:1 with the displayed video', () {
      final c = moveCursor(const Offset(0.5, 0.5), const Offset(4, 0), rect, 1);
      expect(c.dx, closeTo(0.5 + 4 * 1.24 / 400, 1e-9));
    });

    test('fast moves accelerate', () {
      final slow = moveCursor(const Offset(0, 0), const Offset(2, 0), rect, 1).dx / 2;
      final fast = moveCursor(const Offset(0, 0), const Offset(30, 0), rect, 1).dx / 30;
      expect(fast, greaterThan(slow * 2));
    });

    test('zooming in makes the cursor finer', () {
      final z1 = moveCursor(const Offset(0.5, 0.5), const Offset(10, 0), rect, 1).dx;
      final z2 = moveCursor(const Offset(0.5, 0.5), const Offset(10, 0), rect, 2).dx;
      expect(z2 - 0.5, closeTo((z1 - 0.5) / 2, 1e-9));
    });

    test('the cursor stays inside the frame', () {
      final c = moveCursor(const Offset(0.99, 0.01), const Offset(500, -500), rect, 1);
      expect(c, const Offset(1, 0));
    });

    test('videoToScreen undoes the zoom and pan', () {
      expect(videoToScreen(const Offset(0.5, 0.5), rect, 1, Offset.zero), const Offset(200, 225));
      expect(videoToScreen(const Offset(0, 0), rect, 2, const Offset(-50, -100)),
          const Offset(-50, 100));
    });
  });

  test('adjacentWindow wraps and skips minimized windows', () {
    RemoteWindow w(int id, {bool on = true}) =>
        RemoteWindow(id: id, app: 'A$id', title: '', width: 1, height: 1, onScreen: on);
    final list = [w(1), w(2, on: false), w(3)];
    expect(adjacentWindow(list, 1, next: true)?.id, 3);
    expect(adjacentWindow(list, 3, next: true)?.id, 1);
    expect(adjacentWindow(list, 1, next: false)?.id, 3);
    expect(adjacentWindow([w(1)], 1, next: true), isNull);
  });
}
