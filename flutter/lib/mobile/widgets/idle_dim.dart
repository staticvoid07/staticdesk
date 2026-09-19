import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// StaticDesk: dim the screen after a quiet spell during a session.
///
/// The screen is the largest single drain on the phone, and the wakelock
/// keeps it on for the whole session by design. This lowers the *window*
/// brightness after [timeout] without input and restores it on the next
/// touch or keystroke. Window brightness needs no permission, applies only
/// while this activity is in front, and a negative value returns control to
/// the system setting - so nothing leaks past the session.
///
/// Driven by the same activity signals as the idle frame-rate throttle (see
/// VideoThrottle, which forwards to this).
class IdleDim {
  IdleDim._();
  static final IdleDim instance = IdleDim._();

  FFI? _ffi;
  Timer? _timer;
  bool _dimmed = false;

  bool get enabled =>
      isAndroid && bind.mainGetLocalOption(key: kOptionIdleDim) != 'N';

  Duration get timeout {
    final v = int.tryParse(bind.mainGetLocalOption(key: kOptionIdleDimTimeout));
    if (v == null || v < kMinIdleDimTimeout || v > kMaxIdleDimTimeout) {
      return const Duration(seconds: kDefaultIdleDimTimeout);
    }
    return Duration(seconds: v);
  }

  /// Brightness while dimmed as a fraction of the *current* brightness, 0..1.
  /// Relative on purpose: with adaptive brightness the user may already be at
  /// a few percent of full, and an absolute level would brighten the screen.
  double get level {
    final v = int.tryParse(bind.mainGetLocalOption(key: kOptionIdleDimLevel));
    final pct = (v == null || v < kMinIdleDimLevel || v > kMaxIdleDimLevel)
        ? kDefaultIdleDimLevel
        : v;
    return pct / 100.0;
  }

  void attach(FFI ffi) {
    _ffi = ffi;
    _dimmed = false;
    _arm();
  }

  Future<void> detach() async {
    _timer?.cancel();
    _timer = null;
    await _restore();
    _ffi = null;
  }

  Future<void> onAppBackground() async {
    // The window is not visible; do not come back to a dark screen.
    _timer?.cancel();
    _timer = null;
    await _restore();
  }

  void onAppForeground() => _arm();

  void notifyUserActivity() {
    if (_dimmed) unawaited(_restore());
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (_ffi == null || !enabled) return;
    _timer = Timer(timeout, () async {
      if (_dimmed || _ffi == null) return;
      _dimmed = true;
      await _set(level);
    });
  }

  Future<void> _restore() async {
    if (!_dimmed) return;
    _dimmed = false;
    await _set(-1);
  }

  Future<void> _set(double v) async {
    final ffi = _ffi;
    if (ffi == null) return;
    try {
      await ffi.invokeMethod("set_window_brightness", v);
    } catch (e) {
      debugPrint('IdleDim: set_window_brightness failed: $e');
    }
  }
}
