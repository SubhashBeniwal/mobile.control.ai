import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/remote.dart';
import '../models/touch_interpreter.dart';
import '../services/remote_session.dart';

/// Local view state of a [RemoteSurface] that the surrounding screen reads
/// (zoom, for the "fit" button) or drives (reset zoom).
class RemoteSurfaceController extends ChangeNotifier {
  double zoom = 1;
  Offset offset = Offset.zero;

  /// Trackpad cursor, normalized to the video frame.
  Offset cursor = const Offset(0.5, 0.5);

  void resetZoom() {
    zoom = 1;
    offset = Offset.zero;
    notifyListeners();
  }

  void changed() => notifyListeners();
}

/// Renders a stream's video and turns touch into `input` channel messages.
///
/// Touch mode: tap = click where you touch, double-tap = double-click,
/// long-press = right click, drag = mouse drag, two-finger drag = scroll,
/// pinch = local zoom.
///
/// Trackpad mode: one-finger drag moves a cursor (with acceleration), tap =
/// click at the cursor, two-finger tap or long-press = right click,
/// press-and-hold then drag = mouse drag, two-finger drag = scroll at the
/// cursor, pinch = local zoom.
///
/// In both modes, swipes with three or more fingers go to [onSwipe].
class RemoteSurface extends StatefulWidget {
  const RemoteSurface({
    super.key,
    required this.session,
    required this.controller,
    required this.trackpad,
    required this.onSwipe,
  });

  final RemoteSession session;
  final RemoteSurfaceController controller;
  final bool trackpad;
  final void Function(int fingers, SwipeDirection direction) onSwipe;

  @override
  State<RemoteSurface> createState() => _RemoteSurfaceState();
}

class _RemoteSurfaceState extends State<RemoteSurface> {
  late final TouchInterpreter _touch = TouchInterpreter(_onGesture);
  Size _box = Size.zero;
  Offset _scrollAcc = Offset.zero;
  bool _dragDown = false;

  RemoteSurfaceController get _c => widget.controller;
  RemoteSession get _s => widget.session;
  Size get _video => _s.videoSize;
  Rect get _rect => containRect(_box, _video);

  @override
  void initState() {
    super.initState();
    _c.addListener(_onController);
  }

  @override
  void didUpdateWidget(RemoteSurface old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onController);
    _touch.dispose();
    super.dispose();
  }

  void _onController() => setState(() {});

  // ---- mapping -----------------------------------------------------------

  /// A view point → 0–1 video coordinates (undoing zoom, excluding bars).
  Offset? _norm(Offset local, {bool clamp = false}) =>
      normalizeToVideo((local - _c.offset) / _c.zoom, _box, _video, clamp: clamp);

  void _send(Map<String, dynamic> msg) => _s.send(msg);

  // ---- gestures ----------------------------------------------------------

  void _onGesture(TouchGesture g) {
    if (widget.trackpad) {
      _trackpad(g);
    } else {
      _direct(g);
    }
    switch (g) {
      case PinchGesture(:final focal, :final scale, :final delta):
        _zoomBy(focal, scale, delta);
      case SwipeGesture(:final fingers, :final direction):
        HapticFeedback.mediumImpact();
        widget.onSwipe(fingers, direction);
      case LongPressGesture():
        HapticFeedback.selectionClick();
      case GestureEndGesture():
        _scrollAcc = Offset.zero;
      default:
        break;
    }
  }

  /// Touch mode: input lands where the finger is.
  void _direct(TouchGesture g) {
    switch (g) {
      case TapGesture(:final position, :final fingers, :final count):
        final p = _norm(position);
        if (p == null) return;
        if (fingers == 1) {
          _send(RemoteInput.click(p, n: count));
        } else if (fingers == 2) {
          _send(RemoteInput.click(p, b: MouseButton.right));
        }
      case LongPressUpGesture(:final position):
        final p = _norm(position);
        if (p != null) _send(RemoteInput.click(p, b: MouseButton.right));
      case DragStartGesture(:final position):
        final p = _norm(position);
        if (p == null) return; // started in a letterbox bar
        _dragDown = true;
        _send(RemoteInput.pointer('down', p));
      case DragUpdateGesture(:final position):
        if (!_dragDown) return;
        final p = _norm(position, clamp: true);
        if (p != null) _send(RemoteInput.pointer('move', p));
      case DragEndGesture(:final position):
        if (!_dragDown) return;
        _dragDown = false;
        final p = _norm(position, clamp: true);
        if (p != null) _send(RemoteInput.pointer('up', p));
      case PanGesture(:final focal, :final delta):
        final p = _norm(focal, clamp: true);
        if (p != null) _scroll(p, delta);
      default:
        break;
    }
  }

  /// Trackpad mode: fingers move a cursor; input lands at the cursor.
  void _trackpad(TouchGesture g) {
    final cursor = _c.cursor;
    switch (g) {
      case TapGesture(:final fingers, :final count):
        if (fingers == 1) {
          _send(RemoteInput.click(cursor, n: count));
        } else if (fingers == 2) {
          _send(RemoteInput.click(cursor, b: MouseButton.right));
        }
      case LongPressUpGesture():
        _send(RemoteInput.click(cursor, b: MouseButton.right));
      case DragStartGesture(:final held):
        if (held) {
          _dragDown = true;
          _send(RemoteInput.pointer('down', cursor));
        }
      case DragUpdateGesture(:final delta):
        _moveCursor(delta);
        _send(RemoteInput.pointer('move', _c.cursor));
      case DragEndGesture():
        if (_dragDown) {
          _dragDown = false;
          _send(RemoteInput.pointer('up', _c.cursor));
        }
      case PanGesture(:final delta):
        _scroll(cursor, delta);
      default:
        break;
    }
  }

  void _moveCursor(Offset delta) {
    setState(() {
      _c.cursor = moveCursor(_c.cursor, delta, _rect, _c.zoom);
      _keepCursorVisible();
    });
  }

  /// When zoomed in, pan the view so the trackpad cursor stays on screen.
  void _keepCursorVisible() {
    if (_c.zoom <= 1) return;
    const margin = 40.0;
    final p = videoToScreen(_c.cursor, _rect, _c.zoom, _c.offset);
    var shift = Offset.zero;
    if (p.dx < margin) shift += Offset(margin - p.dx, 0);
    if (p.dx > _box.width - margin) shift += Offset(_box.width - margin - p.dx, 0);
    if (p.dy < margin) shift += Offset(0, margin - p.dy);
    if (p.dy > _box.height - margin) shift += Offset(0, _box.height - margin - p.dy);
    if (shift != Offset.zero) _c.offset = _clampOffset(_c.offset + shift);
  }

  /// Two-finger drag → `scroll` at [at], in video pixels, natural direction
  /// (fingers moving up scroll the content down, like a trackpad).
  void _scroll(Offset at, Offset delta) {
    final rect = _rect;
    if (rect.width <= 0) return;
    final pxPerPoint = _video.width / (rect.width * _c.zoom);
    _scrollAcc += -delta * pxPerPoint;
    if (_scrollAcc.dx.abs() < 1 && _scrollAcc.dy.abs() < 1) return;
    _send(RemoteInput.scroll(at, _scrollAcc.dx, _scrollAcc.dy));
    _scrollAcc = Offset(_scrollAcc.dx % 1, _scrollAcc.dy % 1);
  }

  void _zoomBy(Offset focal, double scale, Offset panDelta) {
    final newZoom = (_c.zoom * scale).clamp(1.0, 5.0);
    final ratio = newZoom / _c.zoom;
    final offset = focal - (focal - _c.offset) * ratio + panDelta;
    _c.zoom = newZoom;
    _c.offset = _clampOffset(offset);
    _c.changed();
  }

  Offset _clampOffset(Offset o) {
    final minX = _box.width * (1 - _c.zoom);
    final minY = _box.height * (1 - _c.zoom);
    return Offset(o.dx.clamp(minX, 0.0), o.dy.clamp(minY, 0.0));
  }

  // ---- UI ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final box = constraints.biggest;
      if (box != _box) {
        _box = box;
        _c.offset = _clampOffset(_c.offset);
      }
      final showCursor = widget.trackpad && _video != Size.zero;
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _touch.down(e.pointer, e.localPosition, e.timeStamp),
        onPointerMove: (e) => _touch.move(e.pointer, e.localPosition, e.timeStamp),
        onPointerUp: (e) => _touch.up(e.pointer, e.localPosition, e.timeStamp),
        onPointerCancel: (e) => _touch.cancel(e.pointer),
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Transform.translate(
                offset: _c.offset,
                child: Transform.scale(
                  scale: _c.zoom,
                  alignment: Alignment.topLeft,
                  child: SizedBox.fromSize(
                    size: box,
                    child: RTCVideoView(
                      _s.renderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
              ),
              if (showCursor)
                Positioned(
                  left: videoToScreen(_c.cursor, _rect, _c.zoom, _c.offset).dx - 2,
                  top: videoToScreen(_c.cursor, _rect, _c.zoom, _c.offset).dy - 2,
                  child: const IgnorePointer(child: _Cursor()),
                ),
            ],
          ),
        ),
      );
    });
  }
}

/// The trackpad pointer: a classic arrow, tip at the top-left of the widget.
class _Cursor extends StatelessWidget {
  const _Cursor();

  @override
  Widget build(BuildContext context) =>
      const CustomPaint(size: Size(18, 26), painter: _ArrowPainter());
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(2, 2)
      ..lineTo(2, 21)
      ..lineTo(7, 16.5)
      ..lineTo(10.5, 24)
      ..lineTo(13.5, 22.5)
      ..lineTo(10, 15.5)
      ..lineTo(16, 15.5)
      ..close();
    canvas.drawShadow(path, Colors.black, 2, false);
    canvas.drawPath(path, Paint()..color = Colors.white);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter oldDelegate) => false;
}
