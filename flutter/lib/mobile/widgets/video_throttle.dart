import 'dart:async';
import 'dart:math';

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

  /// Fallback when the peer has no explicit `custom-fps` (the protocol default).
  static const int defaultFps = 30;

  FFI? _ffi;
  Timer? _idleTimer;

  /// User's fps, captured on the way into a throttle so it can be restored.
  int _baseFps = defaultFps;

  bool _backgroundThrottled = false;
  bool _idleThrottled = false;

  bool get _throttled => _backgroundThrottled || _idleThrottled;

  bool get idleThrottleEnabled =>
      bind.mainGetLocalOption(key: kOptionIdleVideoThrottle) == 'Y';

  /// Frame rate the idle throttle drops to. 1 is the floor the controlled side
  /// accepts (`MIN_FPS` in video_qos.rs); the client-side clamp in io_loop.rs
  /// was lowered to match, since upstream snapped anything under 5 back to 30.
  int get idleThrottleFps => _readFpsOption(kOptionIdleThrottleFps);

  /// Frame rate used while the app is backgrounded. Setting this at or above
  /// the session's own frame rate effectively disables the background throttle.
  int get backgroundThrottleFps =>
      _readFpsOption(kOptionBackgroundThrottleFps);

  /// How long without input before the idle throttle engages. Read fresh each
  /// time the timer is armed, so a change takes effect on the next idle period
  /// rather than the next session.
  Duration get idleTimeout {
    final v = int.tryParse(
        bind.mainGetLocalOption(key: kOptionIdleThrottleTimeout));
    if (v == null ||
        v < kMinIdleThrottleTimeout ||
        v > kMaxIdleThrottleTimeout) {
      return const Duration(seconds: kDefaultIdleThrottleTimeout);
    }
    return Duration(seconds: v);
  }

  int _readFpsOption(String key) {
    final v = int.tryParse(bind.mainGetLocalOption(key: key));
    if (v == null || v < kMinThrottleFps || v > kMaxThrottleFps) {
      return kDefaultThrottleFps;
    }
    return v;
  }

  /// Frame rate the current throttle state calls for, or null when not
  /// throttled. Both can be set at once - the idle timer may fire and the app
  /// then be backgrounded - in which case the more aggressive one wins.
  int? get _activeThrottleFps {
    if (_backgroundThrottled && _idleThrottled) {
      return min(backgroundThrottleFps, idleThrottleFps);
    }
    if (_backgroundThrottled) return backgroundThrottleFps;
    if (_idleThrottled) return idleThrottleFps;
    return null;
  }

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
    final target = _activeThrottleFps;
    if (target != null) {
      _baseFps = await _readConfiguredFps(ffi);
      // Nothing to gain if the session already runs at or below the target.
      if (_baseFps <= target) return;
      await bind.sessionSetCustomFpsTemp(sessionId: sessionId, fps: target);
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
