import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/remote.dart';
import '../models/touch_interpreter.dart';
import '../services/remote_session.dart';
import '../state/app_state.dart';
import '../widgets/remote_surface.dart';
import '../widgets/window_switcher.dart';

/// Live view of one remote window or display. Touch handling lives in
/// [RemoteSurface] (Touch or Trackpad mode); this screen owns the session,
/// app switching (swipes + switcher sheet), the soft keyboard and toolbar.
class RemoteViewScreen extends StatefulWidget {
  const RemoteViewScreen({
    super.key,
    required this.daemonId,
    required this.config,
    required this.target,
  });

  final String daemonId;
  final StreamConfig config;
  final StreamTarget target;

  @override
  State<RemoteViewScreen> createState() => _RemoteViewScreenState();
}

class _RemoteViewScreenState extends State<RemoteViewScreen> {
  late final AppState _app;
  late RemoteSession _session;
  late StreamTarget _target;
  final _surface = RemoteSurfaceController();

  // Cached window list for swiping between apps.
  List<RemoteWindow> _windows = const [];

  // Transient hint shown after a swipe ("→ Code — main.go").
  String? _hint;
  Timer? _hintTimer;

  // One-shot modifiers applied to the next key.
  final Set<KeyMod> _mods = {};

  // Hidden text field that drives the soft keyboard. It always holds a single
  // sentinel char so Backspace on "empty" input is still observable.
  static const _sentinel = '​';
  final _kbFocus = FocusNode();
  final _kb = TextEditingController();

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _target = widget.target;
    _resetKb();
    _daemonOnline =
        _app.daemons.where((d) => d.id == widget.daemonId).firstOrNull?.online ?? false;
    _app.addListener(_onApp);
    _surface.addListener(_onSurface);
    _kbFocus.addListener(() {
      if (mounted) setState(() {});
    });
    _startSession();
    _refreshWindows();
  }

  @override
  void dispose() {
    _app.removeListener(_onApp);
    _surface.removeListener(_onSurface);
    _session.removeListener(_onSession);
    _session.dispose();
    _hintTimer?.cancel();
    _surface.dispose();
    _kbFocus.dispose();
    _kb.dispose();
    super.dispose();
  }

  void _startSession() {
    _session = RemoteSession(
      request: (action, args) => _app.request(
        widget.daemonId,
        action,
        args: args,
        timeout: Duration(seconds: action == 'stream.start' ? 30 : 15),
      ),
      config: widget.config,
      target: _target.args,
      onOpened: () => _app.streamOpened(widget.daemonId),
      onClosed: () => _app.streamClosed(widget.daemonId),
    );
    _session.addListener(_onSession);
    _session.start();
  }

  /// Move the stream to another window or display: stop this session and
  /// start a new one in place.
  void _switchTo(StreamTarget t) {
    if (t.sameAs(_target)) return;
    final old = _session;
    old.removeListener(_onSession);
    old.dispose();
    setState(() {
      _target = t;
      _surface.resetZoom();
      _startSession();
    });
    _showHint(t.title);
  }

  Future<void> _refreshWindows() async {
    final res = await _app.request(widget.daemonId, 'screen.windows');
    if (!mounted || !res.ok) return;
    _windows = ScreenWindows.fromJson(res.data as Map<String, dynamic>? ?? const {}).windows;
  }

  // End only on an online → offline transition, so a stale offline flag
  // can't kill a session the daemon is actually serving.
  bool _daemonOnline = true;

  void _onApp() {
    final daemon = _app.daemons.where((d) => d.id == widget.daemonId).firstOrNull;
    final online = daemon?.online ?? false;
    if (_daemonOnline && !online && daemon != null) {
      _session.end('The daemon went offline');
    }
    _daemonOnline = online;
  }

  bool _leaving = false;

  void _onSession() {
    if (!mounted || _leaving) return;
    // The daemon ended the session: go back to the picker.
    if (_session.phase == RemoteSessionPhase.ended && _session.endReason != null) {
      _leaving = true;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text('Stream ended: ${_session.endReason}')));
      return;
    }
    setState(() {});
  }

  void _onSurface() => setState(() {});

  void _send(Map<String, dynamic> msg) => _session.send(msg);

  void _showHint(String text) {
    _hintTimer?.cancel();
    setState(() => _hint = text);
    _hintTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  // ---- app switching -------------------------------------------------------

  /// Three-finger swipes switch apps; four-finger swipes drive Spaces.
  ///
  /// Streaming a window: left/right jump the stream to the next/previous
  /// window, up opens the switcher. Streaming a display: left/right send
  /// ⌘Tab / ⌘⇧Tab, up/down open Mission Control / App Exposé.
  void _onSwipe(int fingers, SwipeDirection dir) {
    void chord(String code, Set<KeyMod> mods, String hint) {
      _send(RemoteInput.key(code, mods: mods));
      _showHint(hint);
    }

    if (fingers >= 4) {
      switch (dir) {
        case SwipeDirection.left:
          chord('ArrowRight', {KeyMod.ctrl}, 'Next Space');
        case SwipeDirection.right:
          chord('ArrowLeft', {KeyMod.ctrl}, 'Previous Space');
        case SwipeDirection.up:
          chord('ArrowUp', {KeyMod.ctrl}, 'Mission Control');
        case SwipeDirection.down:
          chord('ArrowDown', {KeyMod.ctrl}, 'App Exposé');
      }
      return;
    }

    if (_target.isDisplay) {
      switch (dir) {
        case SwipeDirection.left:
          chord('Tab', {KeyMod.meta}, 'Next app  ⌘⇥');
        case SwipeDirection.right:
          chord('Tab', {KeyMod.meta, KeyMod.shift}, 'Previous app  ⌘⇧⇥');
        case SwipeDirection.up:
          chord('ArrowUp', {KeyMod.ctrl}, 'Mission Control');
        case SwipeDirection.down:
          chord('ArrowDown', {KeyMod.ctrl}, 'App Exposé');
      }
      return;
    }

    switch (dir) {
      case SwipeDirection.left:
      case SwipeDirection.right:
        _swipeWindow(next: dir == SwipeDirection.left);
      case SwipeDirection.up:
        _openSwitcher();
      case SwipeDirection.down:
        break;
    }
  }

  Future<void> _swipeWindow({required bool next}) async {
    final id = _target.args['window_id'] as int? ?? -1;
    var w = adjacentWindow(_windows, id, next: next);
    if (w == null) {
      await _refreshWindows();
      if (!mounted) return;
      w = adjacentWindow(_windows, id, next: next);
    }
    if (w == null) {
      _showHint('No other windows');
      return;
    }
    _switchTo(StreamTarget.window(w));
  }

  Future<void> _openSwitcher() async {
    final t = await showWindowSwitcher(context, daemonId: widget.daemonId, current: _target);
    if (t != null && mounted) _switchTo(t);
    _refreshWindows();
  }

  void _toggleTrackpad() {
    final on = !_app.remoteTrackpad;
    _app.setRemoteTrackpad(on);
    _showHint(on ? 'Trackpad mode' : 'Touch mode');
  }

  void _showGestures() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF16181F),
      builder: (_) => _GestureHelp(trackpad: _app.remoteTrackpad, display: _target.isDisplay),
    );
  }

  // ---- keyboard ----------------------------------------------------------

  void _resetKb() {
    _kb.value = const TextEditingValue(
      text: _sentinel,
      selection: TextSelection.collapsed(offset: _sentinel.length),
    );
  }

  void _toggleKeyboard() {
    if (_kbFocus.hasFocus) {
      _kbFocus.unfocus();
    } else {
      _resetKb();
      _kbFocus.requestFocus();
    }
    setState(() {});
  }

  void _onKbChanged(TextEditingValue v) {
    // Let the IME finish composing (CJK, dead keys) before sending.
    if (v.composing.isValid && !v.composing.isCollapsed) return;
    if (v.text == _sentinel) return;

    if (!v.text.startsWith(_sentinel)) {
      // Backspace over the sentinel (or the IME rewrote it).
      if (v.text.isEmpty) _key('Backspace');
      _resetKb();
      return;
    }
    final typed = v.text.substring(_sentinel.length);
    _resetKb();
    _typeText(typed);
  }

  /// Send typed text: newlines/tabs as keys, a single char with an active
  /// modifier as a key chord (⌘ + s → ⌘S), everything else as `text`.
  void _typeText(String typed) {
    if (typed.isEmpty) return;
    if (_mods.isNotEmpty && typed.length == 1) {
      final code = RemoteInput.codeForChar(typed);
      if (code != null) {
        _key(code);
        return;
      }
    }
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) _send(RemoteInput.text(buf.toString()));
      buf.clear();
    }

    for (final ch in typed.split('')) {
      if (ch == '\n') {
        flush();
        _key('Enter');
      } else if (ch == '\t') {
        flush();
        _key('Tab');
      } else {
        buf.write(ch);
      }
    }
    flush();
  }

  /// Press a key with the active one-shot modifiers, then clear them.
  void _key(String code, {Set<KeyMod> mods = const {}}) {
    _send(RemoteInput.key(code, mods: {..._mods, ...mods}));
    if (_mods.isNotEmpty) setState(_mods.clear);
  }

  void _toggleMod(KeyMod m) => setState(() => _mods.contains(m) ? _mods.remove(m) : _mods.add(m));

  // ---- UI ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final s = _session;
    final trackpad = context.select<AppState, bool>((a) => a.remoteTrackpad);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF111318),
        foregroundColor: Colors.white,
        titleSpacing: 0,
        titleTextStyle: const TextStyle(
            color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
        title: Text(_target.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (s.phase == RemoteSessionPhase.live) const _LivePill(),
          IconButton(
            tooltip: trackpad ? 'Switch to touch' : 'Switch to trackpad',
            icon: Icon(trackpad ? Icons.mouse : Icons.touch_app),
            onPressed: _toggleTrackpad,
          ),
          IconButton(
            tooltip: 'Switch app',
            icon: const Icon(Icons.view_carousel_outlined),
            onPressed: _openSwitcher,
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) {
              switch (v) {
                case 'fit':
                  _surface.resetZoom();
                case 'keyframe':
                  _send(RemoteInput.keyframe);
                case 'help':
                  _showGestures();
                case 'stop':
                  Navigator.of(context).pop();
              }
            },
            itemBuilder: (_) => [
              if (_surface.zoom > 1)
                const PopupMenuItem(value: 'fit', child: Text('Fit to screen')),
              const PopupMenuItem(value: 'keyframe', child: Text('Refresh video')),
              const PopupMenuItem(value: 'help', child: Text('Gestures')),
              const PopupMenuItem(value: 'stop', child: Text('Stop streaming')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // `hello.input` is authoritative once it arrives.
            if (s.inputEnabled == false ||
                (s.inputEnabled == null && !widget.config.accessibility))
              const _Banner(
                icon: Icons.touch_app_outlined,
                text: 'Input is ignored: Accessibility isn\'t granted on the Mac. '
                    'Approve AIO Agent under System Settings → Privacy & Security → '
                    'Accessibility.',
              ),
            Expanded(child: _buildVideo(s, trackpad)),
            _buildToolbar(),
            // Hidden field that owns the soft keyboard.
            SizedBox(
              height: 1,
              child: Opacity(
                opacity: 0,
                child: TextField(
                  focusNode: _kbFocus,
                  controller: _kb,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  smartDashesType: SmartDashesType.disabled,
                  smartQuotesType: SmartQuotesType.disabled,
                  keyboardType: TextInputType.multiline,
                  maxLines: null,
                  onChanged: (_) => _onKbChanged(_kb.value),
                  onTapOutside: (_) {},
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideo(RemoteSession s, bool trackpad) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RemoteSurface(
          session: s,
          controller: _surface,
          trackpad: trackpad,
          onSwipe: _onSwipe,
        ),
        if (_hint != null)
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(_hint!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 13.5)),
                ),
              ),
            ),
          ),
        if (s.phase == RemoteSessionPhase.starting ||
            s.phase == RemoteSessionPhase.connecting)
          _Overlay(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 16),
                Text(
                  s.phase == RemoteSessionPhase.starting
                      ? 'Starting stream…'
                      : 'Connecting to the Mac…',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        if (s.phase == RemoteSessionPhase.failed)
          _Overlay(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 44),
                const SizedBox(height: 12),
                Text(
                  s.error?.friendly ?? 'The stream failed.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14.5),
                ),
                const SizedBox(height: 18),
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).pop(s.error),
                  child: const Text('Back to windows'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildToolbar() {
    final kbOpen = _kbFocus.hasFocus;
    Widget key(String label, String code, {IconData? icon}) => _ToolButton(
          label: label,
          icon: icon,
          onTap: () => _key(code),
        );

    return Container(
      color: const Color(0xFF111318),
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        children: [
          _ToolButton(
            icon: kbOpen ? Icons.keyboard_hide : Icons.keyboard,
            active: kbOpen,
            onTap: _toggleKeyboard,
          ),
          for (final m in KeyMod.values)
            _ToolButton(
              label: m.symbol,
              active: _mods.contains(m),
              onTap: () => _toggleMod(m),
            ),
          const _ToolDivider(),
          key('esc', 'Escape'),
          key('tab', 'Tab'),
          key('', 'ArrowLeft', icon: Icons.arrow_back),
          key('', 'ArrowUp', icon: Icons.arrow_upward),
          key('', 'ArrowDown', icon: Icons.arrow_downward),
          key('', 'ArrowRight', icon: Icons.arrow_forward),
          key('', 'Backspace', icon: Icons.backspace_outlined),
          key('', 'Enter', icon: Icons.keyboard_return),
          const _ToolDivider(),
          _ShortcutMenu(onPick: (code, mods) => _key(code, mods: mods)),
        ],
      ),
    );
  }
}

/// Cheat sheet for the current input mode and target.
class _GestureHelp extends StatelessWidget {
  const _GestureHelp({required this.trackpad, required this.display});
  final bool trackpad;
  final bool display;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      if (trackpad) ...[
        ('Drag', 'Move the cursor'),
        ('Tap', 'Click at the cursor'),
        ('Double-tap', 'Double-click'),
        ('Two-finger tap / long-press', 'Right-click'),
        ('Press and hold, then drag', 'Drag (select, move)'),
      ] else ...[
        ('Tap', 'Click where you touch'),
        ('Double-tap', 'Double-click'),
        ('Two-finger tap / long-press', 'Right-click'),
        ('Drag', 'Drag (select, move)'),
      ],
      ('Two-finger drag', 'Scroll'),
      ('Pinch', 'Zoom this view'),
      if (display) ...[
        ('3 fingers ← / →', 'Next / previous app (⌘⇥)'),
        ('3 fingers ↑ / ↓', 'Mission Control / App Exposé'),
      ] else ...[
        ('3 fingers ← / →', 'Stream the next / previous window'),
        ('3 fingers ↑', 'Window switcher'),
      ],
      ('4 fingers ← / →', 'Switch Spaces'),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(trackpad ? 'Trackpad mode' : 'Touch mode',
                style: const TextStyle(
                    color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            for (final (gesture, action) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: Text(gesture,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w600)),
                    ),
                    Expanded(
                      flex: 6,
                      child: Text(action, style: const TextStyle(color: Colors.white70)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Common shortcuts, each a key code + modifiers.
const _shortcuts = <(String, String, Set<KeyMod>)>[
  ('Save  ⌘S', 'KeyS', {KeyMod.meta}),
  ('Quick open  ⌘P', 'KeyP', {KeyMod.meta}),
  ('Command palette  ⌘⇧P', 'KeyP', {KeyMod.meta, KeyMod.shift}),
  ('Find  ⌘F', 'KeyF', {KeyMod.meta}),
  ('Undo  ⌘Z', 'KeyZ', {KeyMod.meta}),
  ('Redo  ⌘⇧Z', 'KeyZ', {KeyMod.meta, KeyMod.shift}),
  ('Copy  ⌘C', 'KeyC', {KeyMod.meta}),
  ('Paste  ⌘V', 'KeyV', {KeyMod.meta}),
  ('Select all  ⌘A', 'KeyA', {KeyMod.meta}),
  ('Close tab  ⌘W', 'KeyW', {KeyMod.meta}),
  ('New tab  ⌘T', 'KeyT', {KeyMod.meta}),
  ('Reload  ⌘R', 'KeyR', {KeyMod.meta}),
  ('Toggle terminal  ⌃`', 'Backquote', {KeyMod.ctrl}),
  ('Delete forward', 'Delete', <KeyMod>{}),
  ('F5', 'F5', <KeyMod>{}),
];

class _ShortcutMenu extends StatelessWidget {
  const _ShortcutMenu({required this.onPick});
  final void Function(String code, Set<KeyMod> mods) onPick;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Shortcuts',
      onSelected: (i) => onPick(_shortcuts[i].$2, _shortcuts[i].$3),
      itemBuilder: (_) => [
        for (var i = 0; i < _shortcuts.length; i++)
          PopupMenuItem(value: i, height: 40, child: Text(_shortcuts[i].$1)),
      ],
      child: const _ToolButton(label: 'shortcuts', icon: Icons.bolt),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({this.label = '', this.icon, this.active = false, this.onTap});
  final String label;
  final IconData? icon;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = active ? Colors.black : Colors.white;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: active ? Colors.white : const Color(0xFF242833),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 40),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) Icon(icon, size: 18, color: fg),
                if (icon != null && label.isNotEmpty) const SizedBox(width: 4),
                if (label.isNotEmpty)
                  Text(label,
                      style: TextStyle(
                          color: fg, fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolDivider extends StatelessWidget {
  const _ToolDivider();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        color: Colors.white24,
      );
}

class _LivePill extends StatelessWidget {
  const _LivePill();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: Colors.white),
          SizedBox(width: 5),
          Text('LIVE',
              style: TextStyle(
                  color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF5A4300),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.amberAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: const TextStyle(color: Colors.white, fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}

class _Overlay extends StatelessWidget {
  const _Overlay({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Padding(padding: const EdgeInsets.all(28), child: child),
      ),
    );
  }
}
