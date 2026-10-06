import 'dart:async';
import 'dart:ui';

/// High-level touch gestures recognized from raw pointer events by
/// [TouchInterpreter]. Positions are in the surface's local coordinates.
sealed class TouchGesture {
  const TouchGesture();
}

/// A quick tap with [fingers] fingers; [count] is 2 for the second tap of a
/// double-tap (the first tap was already reported with count 1).
class TapGesture extends TouchGesture {
  const TapGesture(this.position, this.fingers, this.count);
  final Offset position;
  final int fingers;
  final int count;
}

/// One finger held still long enough to enter "hold" mode.
class LongPressGesture extends TouchGesture {
  const LongPressGesture(this.position);
  final Offset position;
}

/// The finger from a [LongPressGesture] lifted without moving.
class LongPressUpGesture extends TouchGesture {
  const LongPressUpGesture(this.position);
  final Offset position;
}

/// One finger started moving. [held] is true when it moved after a long press
/// (press-and-hold, then drag).
class DragStartGesture extends TouchGesture {
  const DragStartGesture(this.position, {required this.held});
  final Offset position;
  final bool held;
}

class DragUpdateGesture extends TouchGesture {
  const DragUpdateGesture(this.position, this.delta, {required this.held});
  final Offset position;
  final Offset delta;
  final bool held;
}

class DragEndGesture extends TouchGesture {
  const DragEndGesture(this.position, {required this.held});
  final Offset position;
  final bool held;
}

/// Two fingers moving together (scroll).
class PanGesture extends TouchGesture {
  const PanGesture(this.focal, this.delta);
  final Offset focal;
  final Offset delta;
}

/// Two fingers spreading or pinching. [scale] is relative to the previous
/// update; [delta] is the focal point's movement since then.
class PinchGesture extends TouchGesture {
  const PinchGesture(this.focal, this.scale, this.delta);
  final Offset focal;
  final double scale;
  final Offset delta;
}

enum SwipeDirection { left, right, up, down }

/// Three or more fingers swiped in [direction].
class SwipeGesture extends TouchGesture {
  const SwipeGesture(this.fingers, this.direction);
  final int fingers;
  final SwipeDirection direction;
}

/// All fingers lifted (sent after any final gesture event).
class GestureEndGesture extends TouchGesture {
  const GestureEndGesture();
}

enum _Phase { idle, pending, held, drag, heldDrag, pan, pinch, swipe, ignore }

/// Turns raw pointer down/move/up events into [TouchGesture]s.
///
/// Built on raw pointers instead of Flutter's gesture arena so that two-finger
/// taps, three- and four-finger swipes, and press-and-hold drags can be told
/// apart reliably, and so the logic is unit-testable.
class TouchInterpreter {
  TouchInterpreter(
    this.onGesture, {
    this.slop = 12,
    this.longPress = const Duration(milliseconds: 450),
    this.tapTimeout = const Duration(milliseconds: 300),
    this.doubleTapGap = const Duration(milliseconds: 300),
    this.doubleTapSlop = 40,
    this.swipeDistance = 60,
    this.pinchThreshold = 0.10,
    this.settle = const Duration(milliseconds: 50),
  });

  final void Function(TouchGesture) onGesture;

  /// Movement (px) before a touch stops being a tap.
  final double slop;
  final Duration longPress;
  final Duration tapTimeout;
  final Duration doubleTapGap;
  final double doubleTapSlop;

  /// Minimum travel (px) for a multi-finger swipe.
  final double swipeDistance;

  /// Relative change in finger spread that makes a two-finger gesture a pinch.
  final double pinchThreshold;

  /// How long after a finger lands to wait before committing to a one-finger
  /// drag or two-finger scroll/pinch, so the fingers of a three- or
  /// four-finger swipe, which land a few ms apart, don't trigger them first.
  final Duration settle;

  final Map<int, Offset> _points = {};
  _Phase _phase = _Phase.idle;
  int _maxFingers = 0;
  Duration _downAt = Duration.zero;
  Duration _lastDownAt = Duration.zero;
  Offset _firstDown = Offset.zero;
  bool _moved = false;

  // Baselines, re-taken whenever the finger count changes so the focal point
  // doesn't jump when a finger lands or lifts.
  Offset _lastFocal = Offset.zero;
  double _baseSpan = 0;
  double _lastSpan = 0;
  Offset _travel = Offset.zero;

  Timer? _holdTimer;
  Offset _holdAt = Offset.zero;

  // Previous tap, for double-tap detection.
  Duration? _lastTapAt;
  Offset _lastTapPos = Offset.zero;
  int _lastTapFingers = 0;
  int _lastTapCount = 0;

  int get fingers => _points.length;

  Offset get _focal {
    var sum = Offset.zero;
    for (final p in _points.values) {
      sum += p;
    }
    return _points.isEmpty ? Offset.zero : sum / _points.length.toDouble();
  }

  double get _span {
    if (_points.length < 2) return 0;
    final f = _focal;
    var total = 0.0;
    for (final p in _points.values) {
      total += (p - f).distance;
    }
    return total / _points.length;
  }

  void _rebase() {
    _lastFocal = _focal;
    _baseSpan = _span;
    _lastSpan = _baseSpan;
    _travel = Offset.zero;
  }

  void down(int pointer, Offset position, Duration time) {
    if (_points.isEmpty) {
      _phase = _Phase.pending;
      _maxFingers = 0;
      _downAt = time;
      _firstDown = position;
      _moved = false;
      _holdTimer?.cancel();
      _holdTimer = Timer(longPress, _onHold);
    }
    _points[pointer] = position;
    _lastDownAt = time;
    if (_points.length > _maxFingers) _maxFingers = _points.length;

    if (_points.length > 1) {
      _holdTimer?.cancel();
      switch (_phase) {
        case _Phase.drag:
          // A second finger joined a one-finger drag: end it and re-decide.
          onGesture(DragEndGesture(_lastFocal, held: false));
          _phase = _Phase.pending;
          _moved = true;
        case _Phase.held:
        case _Phase.heldDrag:
          if (_phase == _Phase.heldDrag) {
            onGesture(DragEndGesture(_lastFocal, held: true));
          }
          _phase = _Phase.ignore;
        case _Phase.pan:
        case _Phase.pinch:
          if (_points.length >= 3) {
            _phase = _Phase.pending;
            _moved = true;
          }
        default:
          break;
      }
    }
    _rebase();
  }

  void move(int pointer, Offset position, Duration time) {
    if (!_points.containsKey(pointer)) return;
    _points[pointer] = position;
    final focal = _focal;
    final span = _span;
    final delta = focal - _lastFocal;
    _travel += delta;

    switch (_phase) {
      case _Phase.pending:
        if (_travel.distance <= slop &&
            (_points.length < 2 ||
                _baseSpan <= 0 ||
                (span / _baseSpan - 1).abs() <= pinchThreshold)) {
          break;
        }
        _moved = true;
        _holdTimer?.cancel();
        if (_points.length < 3 && time - _lastDownAt < settle) break;
        if (_points.length == 1) {
          _phase = _Phase.drag;
          onGesture(DragStartGesture(focal - _travel, held: false));
          onGesture(DragUpdateGesture(focal, _travel, held: false));
        } else if (_points.length == 2) {
          if (_baseSpan > 0 && (span / _baseSpan - 1).abs() > pinchThreshold) {
            _phase = _Phase.pinch;
            onGesture(PinchGesture(focal, span / _baseSpan, _travel));
          } else {
            _phase = _Phase.pan;
            onGesture(PanGesture(focal, _travel));
          }
        } else {
          _phase = _Phase.swipe;
        }
      case _Phase.held:
        if ((focal - _holdAt).distance > slop) {
          _phase = _Phase.heldDrag;
          onGesture(DragStartGesture(_holdAt, held: true));
          onGesture(DragUpdateGesture(focal, focal - _holdAt, held: true));
        }
      case _Phase.drag:
        onGesture(DragUpdateGesture(focal, delta, held: false));
      case _Phase.heldDrag:
        onGesture(DragUpdateGesture(focal, delta, held: true));
      case _Phase.pan:
        onGesture(PanGesture(focal, delta));
      case _Phase.pinch:
        if (_lastSpan > 0) onGesture(PinchGesture(focal, span / _lastSpan, delta));
      case _Phase.swipe:
      case _Phase.idle:
      case _Phase.ignore:
        break;
    }
    _lastFocal = focal;
    _lastSpan = span;
  }

  void up(int pointer, Offset position, Duration time) {
    if (!_points.containsKey(pointer)) return;
    _points[pointer] = position;
    final travel = _travel + (_focal - _lastFocal);
    final lastFocal = _focal;
    _points.remove(pointer);

    if (_points.isNotEmpty) {
      // Fingers of a multi-finger tap or swipe lift one by one; keep going.
      if ((_phase == _Phase.pan || _phase == _Phase.pinch) && _points.length < 2) {
        _phase = _Phase.ignore;
      }
      if (_phase == _Phase.swipe) {
        // Keep the swipe's travel across finger lifts.
        final kept = travel;
        _rebase();
        _travel = kept;
      } else {
        _rebase();
      }
      return;
    }

    _holdTimer?.cancel();
    switch (_phase) {
      case _Phase.pending:
        if (!_moved && time - _downAt <= tapTimeout) {
          _emitTap(time);
        } else if (_moved && _maxFingers == 1) {
          // A flick that ended while settling: still deliver it as a drag.
          onGesture(DragStartGesture(_firstDown, held: false));
          onGesture(DragUpdateGesture(lastFocal, lastFocal - _firstDown, held: false));
          onGesture(DragEndGesture(lastFocal, held: false));
        }
      case _Phase.held:
        onGesture(LongPressUpGesture(_holdAt));
      case _Phase.drag:
        onGesture(DragEndGesture(lastFocal, held: false));
      case _Phase.heldDrag:
        onGesture(DragEndGesture(lastFocal, held: true));
      case _Phase.swipe:
        final dir = classifySwipe(travel, swipeDistance);
        if (dir != null) onGesture(SwipeGesture(_maxFingers, dir));
      default:
        break;
    }
    onGesture(const GestureEndGesture());
    _phase = _Phase.idle;
  }

  void cancel(int pointer) {
    if (!_points.containsKey(pointer)) return;
    if (_phase == _Phase.drag || _phase == _Phase.heldDrag) {
      onGesture(DragEndGesture(_lastFocal, held: _phase == _Phase.heldDrag));
    }
    _phase = _Phase.ignore;
    _points.remove(pointer);
    if (_points.isEmpty) {
      _holdTimer?.cancel();
      onGesture(const GestureEndGesture());
      _phase = _Phase.idle;
    } else {
      _rebase();
    }
  }

  void _emitTap(Duration time) {
    final last = _lastTapAt;
    final isDouble = last != null &&
        _lastTapCount == 1 &&
        _lastTapFingers == _maxFingers &&
        time - last <= doubleTapGap + tapTimeout &&
        (_firstDown - _lastTapPos).distance <= doubleTapSlop;
    final count = isDouble ? 2 : 1;
    _lastTapAt = time;
    _lastTapPos = _firstDown;
    _lastTapFingers = _maxFingers;
    _lastTapCount = count;
    onGesture(TapGesture(_firstDown, _maxFingers, count));
  }

  void _onHold() {
    if (_phase != _Phase.pending || _points.length != 1 || _moved) return;
    _phase = _Phase.held;
    _holdAt = _focal;
    onGesture(LongPressGesture(_holdAt));
  }

  void dispose() => _holdTimer?.cancel();
}

/// The dominant direction of [travel], or null if it's shorter than [minDistance].
SwipeDirection? classifySwipe(Offset travel, double minDistance) {
  if (travel.distance < minDistance) return null;
  if (travel.dx.abs() >= travel.dy.abs()) {
    return travel.dx < 0 ? SwipeDirection.left : SwipeDirection.right;
  }
  return travel.dy < 0 ? SwipeDirection.up : SwipeDirection.down;
}
