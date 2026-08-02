import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// StaticDesk: battery saver for the mobile *controller* side.
///
/// Video decoding is the dominant CPU cost of an open session, and it scales
/// with frame rate. Two situations produce frames nobody is looking at:
///
///  * the app is backgrounded - the peer keeps streaming at full rate and the
///    Rust side keeps decoding, even though nothing is rendered;
///  * the session is open but untouched for a while (reading, watching).
///
/// Both are handled by temporarily dropping `custom-fps`. Audio is a separate
/// stream and is never touched, so sound keeps playing while video is throttled.
///
/// The fps change goes through `sessionSetCustomFpsTemp`, which does *not*
/// write to the peer config - if the app is killed while throttled, the user's
/// own fps setting is still intact next time.
class VideoThrottle {
  VideoThrottle._();
  static final VideoThrottle instance = VideoThrottle._();

  /// Frame rate used while throttled. 1 is the floor the controlled side
  /// accepts (`MIN_FPS` in video_qos.rs); the client-side clamp in io_loop.rs
  /// was lowered to match, since upstream snapped anything under 5 back to 30.
  static const int throttledFps = 1;

  /// Fallback when the peer has no explicit `custom-fps` (the protocol default).
  static const int defaultFps = 30;

  /// How long without input before the idle throttle kicks in.
  static const Duration idleTimeout = Duration(seconds: 20);

  FFI? _ffi;
  Timer? _idleTimer;

  /// User's fps, captured on the way into a throttle so it can be restored.
  int _baseFps = defaultFps;

  bool _backgroundThrottled = false;
  bool _idleThrottled = false;

  bool get _throttled => _backgroundThrottled || _idleThrottled;

  bool get idleThrottleEnabled =>
      bind.mainGetLocalOption(key: kOptionIdleVideoThrottle) == 'Y';

  Future<void> setIdleThrottleEnabled(bool enabled) async {
    await bind.mainSetLocalOption(
        key: kOptionIdleVideoThrottle, value: enabled ? 'Y' : 'N');
    if (enabled) {
      _restartIdleTimer();
    } else {
      _idleTimer?.cancel();
      _idleTimer = null;
      if (_idleThrottled) {
        _idleThrottled = false;
        await _applyFps();
      }
    }
  }

  void attach(FFI ffi) {
    _ffi = ffi;
    _backgroundThrottled = false;
    _idleThrottled = false;
    _restartIdleTimer();
  }

  /// Restores the user's frame rate and drops all state. Safe to call when the
  /// session is already gone - the fps write just no-ops.
  Future<void> detach() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final wasThrottled = _throttled;
    _backgroundThrottled = false;
    _idleThrottled = false;
    if (wasThrottled) {
      await _applyFps();
    }
    _ffi = null;
  }

  Future<void> onAppBackground() async {
    // Backgrounding is also "no input", so stop the idle timer - it would
    // otherwise fire while hidden and fight with the background throttle.
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_backgroundThrottled) return;
    _backgroundThrottled = true;
    await _applyFps();
  }

  Future<void> onAppForeground() async {
    if (!_backgroundThrottled) {
      _restartIdleTimer();
      return;
    }
    _backgroundThrottled = false;
    // Coming back to the app is input in itself - clear any idle throttle too.
    _idleThrottled = false;
    await _applyFps();
    _restartIdleTimer();
  }

  /// Called on any pointer/key activity in the remote session.
  void notifyUserActivity() {
    if (_idleThrottled) {
      _idleThrottled = false;
      unawaited(_applyFps());
    }
    _restartIdleTimer();
  }

  void _restartIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_ffi == null) return;
    if (!idleThrottleEnabled) return;
    // No point arming it while hidden; `onAppForeground` re-arms.
    if (_backgroundThrottled) return;
    _idleTimer = Timer(idleTimeout, () async {
      if (_idleThrottled) return;
      _idleThrottled = true;
      await _applyFps();
    });
  }

  /// Pushes the frame rate that matches current state. Re-reads the user's own
  /// fps on the way in so a change made mid-session is picked up.
  Future<void> _applyFps() async {
    final ffi = _ffi;
    if (ffi == null) return;
    final sessionId = ffi.sessionId;
    if (_throttled) {
      _baseFps = await _readConfiguredFps(ffi);
      if (_baseFps <= throttledFps) return; // already at or below the floor
      await bind.sessionSetCustomFpsTemp(
          sessionId: sessionId, fps: throttledFps);
    } else {
      await bind.sessionSetCustomFpsTemp(sessionId: sessionId, fps: _baseFps);
    }
  }

  Future<int> _readConfiguredFps(FFI ffi) async {
    try {
      final v = await bind.sessionGetOption(
          sessionId: ffi.sessionId, arg: 'custom-fps');
      final parsed = int.tryParse(v ?? '');
      if (parsed == null || parsed < 1 || parsed > 120) return defaultFps;
      return parsed;
    } catch (e) {
      debugPrint('VideoThrottle: failed to read custom-fps: $e');
      return defaultFps;
    }
  }
}
