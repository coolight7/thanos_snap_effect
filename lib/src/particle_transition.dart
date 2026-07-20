import 'dart:async';
import 'dart:ui' as ui;
import 'dart:ui' show FragmentShader;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:thanos_snap_effect/src/particle_transition_shader.dart';
import 'package:thanos_snap_effect/src/snappable_style.dart';
import 'package:thanos_snap_effect/src/snapshot/snapshot_info.dart';

/// Style of the [ParticleImageTransition] effect.
class ParticleTransitionStyle {
  /// Left-to-right wave delay factor (0.0 - 1.0).
  final double waveDelay;

  /// How far particles travel from their origin while spreading, in uv units.
  final double spreadSpeed;

  /// Size of the particles.
  final SnappableParticleSize particleSize;

  const ParticleTransitionStyle({
    this.waveDelay = 0.5,
    this.spreadSpeed = 1.2,
    this.particleSize =
        const SnappableParticleSize.squareFromRelativeWidth(0.025),
  }) : assert(waveDelay >= 0.0 && waveDelay <= 1.0,
            'waveDelay must be in [0, 1]');
}

/// A widget that transitions between two successive [child] widgets by
/// dissolving the old child into particles (upper half downwards, lower half
/// upwards, sweeping left to right), then collapsing the particles back into
/// place while their color blends into the new child.
///
/// Re-triggering a transition while one is already running is supported: the
/// currently-assembling image becomes the new source and the animation
/// restarts, dissolving into the latest image without flicker.
class ParticleImageTransition extends StatefulWidget {
  final Widget child;

  final Duration duration;

  /// Space around the child used to paint particles that fly outside bounds.
  final EdgeInsets outerPadding;

  final ParticleTransitionStyle style;

  /// Delay before capturing snapshots (lets async image content decode).
  final Duration? delayCapture;

  const ParticleImageTransition({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 1400),
    this.outerPadding = const EdgeInsets.all(20),
    this.style = const ParticleTransitionStyle(),
    this.delayCapture,
  });

  @override
  State<ParticleImageTransition> createState() =>
      _ParticleImageTransitionState();
}

class _ParticleImageTransitionState extends State<ParticleImageTransition>
    with SingleTickerProviderStateMixin {
  static final _shaderCache = <String, ui.FragmentProgram>{};

  late final AnimationController _controller;
  ParticleTransitionShader? _shader;

  /// The child currently visible / being assembled (for key-change detection).
  Widget _currentChild;

  /// The outgoing child kept off-stage for snapshotting during a transition.
  Widget? _outgoingChild;

  /// Snapshots driving the current animation.
  SnapshotInfo? _oldSnapshot;
  SnapshotInfo? _newSnapshot;

  /// Off-stage boundary for the outgoing (old) child.
  final _oldCaptureKey = GlobalKey();

  /// Off-stage boundary for the incoming (new) child.
  final _newCaptureKey = GlobalKey();

  bool _animating = false;
  bool _captureInProgress = false;

  /// Monotonic token used to invalidate in-flight captures. Every capture
  /// attempt reads this once at the start; if it changed by the time the
  /// Future returns, the result is discarded. This prevents a stale capture
  /// from a previous transition from overwriting the snapshots of a newer
  /// one (which would otherwise dispose an image that's still in use and
  /// crash the shader with "Image has been disposed").
  int _captureGeneration = 0;

  _ParticleImageTransitionState() : _currentChild = const SizedBox.shrink();

  @override
  void initState() {
    super.initState();
    _currentChild = widget.child;
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _finishAnimation();
      }
    });
    _loadShader();
  }

  @override
  void didUpdateWidget(covariant ParticleImageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
    final newKey = _keyOf(widget.child);
    final curKey = _keyOf(_currentChild);
    if (newKey != curKey) {
      if (_animating) {
        _restartMidAnimation();
      } else {
        _startTransition();
      }
    } else {
      _currentChild = widget.child;
    }
  }

  @override
  void dispose() {
    // Invalidate any in-flight capture so it no-ops when it resumes after
    // dispose (the generation check in _performCapture will fail and bail).
    _captureGeneration++;
    _captureInProgress = false;
    _controller.dispose();
    _oldSnapshot?.image.dispose();
    _newSnapshot?.image.dispose();
    super.dispose();
  }

  Key? _keyOf(Widget w) => w.key;

  Future<void> _loadShader() async {
    final program = _shaderCache[ParticleTransitionShader.path] ??
        await ui.FragmentProgram.fromAsset(ParticleTransitionShader.path);
    _shaderCache[ParticleTransitionShader.path] = program;
    if (!mounted) return;
    _shader = ParticleTransitionShader(program.fragmentShader());
    if (mounted) setState(() {});
  }

  /// Starts a transition from the currently-shown child to [widget.child].
  void _startTransition() {
    if (_shader == null) {
      _currentChild = widget.child;
      setState(() {});
      return;
    }
    // Keep the old (outgoing) child staged so it can be snapshotted.
    _outgoingChild = _currentChild;
    _animating = true;
    _oldSnapshot?.image.dispose();
    _newSnapshot?.image.dispose();
    _oldSnapshot = null;
    _newSnapshot = null;
    _controller.value = 0;
    _currentChild = widget.child;
    // Invalidate any stray in-flight capture (defensive: _startTransition is
    // only called when !_animating, so there normally isn't one, but the
    // generation bump keeps the invariant simple to reason about).
    _captureGeneration++;
    _captureInProgress = false;
    setState(() {});
    _scheduleCapture();
  }

  /// Re-triggers a transition while one is running.
  ///
  /// The currently-assembling image (the running transition's "new" snapshot)
  /// is promoted to be the new "old" snapshot immediately — no re-capture
  /// needed. The incoming child is captured off-stage as the new "new"
  /// snapshot. The animation restarts from 0, so the current image dissolves
  /// into particles and re-assembles into the latest image. Because the new
  /// child is only ever mounted off-stage, it can never flash on screen.
  void _restartMidAnimation() {
    if (_shader == null) {
      _currentChild = widget.child;
      setState(() {});
      return;
    }
    _currentChild = widget.child;
    if (_newSnapshot == null) {
      // First capture hasn't finished yet. The in-flight capture will pick up
      // the latest child as the new image.
      return;
    }
    // Promote current new -> old. The previous _oldSnapshot is no longer used
    // by the shader (it's about to be replaced below) so it can be disposed.
    // _newSnapshot becomes _oldSnapshot; both must NOT alias the same
    // SnapshotInfo after this point, otherwise disposing one would invalidate
    // the other. The capture path below guarantees they are distinct objects
    // (see _performCapture), so a plain rebind is safe here.
    final previousOld = _oldSnapshot;
    _oldSnapshot = _newSnapshot;
    _newSnapshot = null;
    _outgoingChild = null;
    _controller.stop();
    // Update the shader's old-texture sampler BEFORE disposing previousOld:
    // setImageSampler just stores a reference, so the swap must happen while
    // previousOld.image is still alive. Disposing first would feed a dead
    // image to the shader and crash with "Image has been disposed".
    _shader!.updateOldSnapshot(_oldSnapshot!);
    // Reset the shader's animation value to 0 so that during the restart
    // capture phase (static CustomPaint), the shader renders the old texture
    // fully instead of a stale mid-transition blend that flashes the new image.
    _shader!.setAnimationValue(0);
    previousOld?.image.dispose();
    // Invalidate any in-flight capture from the previous transition: its
    // result would reference an outdated child and could clobber these
    // snapshots mid-animation.
    _captureGeneration++;
    _captureInProgress = false;
    setState(() {});
    _scheduleCapture();
  }

  void _scheduleCapture() {
    if (_captureInProgress) return;
    final delay = widget.delayCapture ?? const Duration(milliseconds: 120);
    _captureInProgress = true;
    final gen = _captureGeneration;
    Future.delayed(delay, () {
      // Drop captures scheduled before a more recent restart.
      if (gen != _captureGeneration) {
        _captureInProgress = false;
        return;
      }
      _performCapture();
    });
  }

  Future<void> _performCapture() async {
    _captureInProgress = false;
    final gen = _captureGeneration;
    if (!mounted || !_animating) return;
    await _nextFrame();
    // Bail out if a restart (or dispose) happened while we were waiting for
    // the next frame. Otherwise the boundary we capture might be unmounted,
    // or the result might overwrite a newer transition's snapshots.
    if (!mounted || !_animating || gen != _captureGeneration) return;

    final isFreshStart = _outgoingChild != null;

    // For a fresh start we capture BOTH old and new. For a restart we only
    // capture the new snapshot — the old one was already promoted + uploaded
    // to the shader by _restartMidAnimation, and re-capturing/overwriting it
    // would replace it with the wrong image (the new child).
    SnapshotInfo? oldInfo;
    if (isFreshStart) {
      oldInfo = await _captureBoundary(_oldCaptureKey);
    }
    final newInfo = await _captureBoundary(_newCaptureKey);
    if (!mounted || !_animating || gen != _captureGeneration) {
      oldInfo?.image.dispose();
      newInfo?.image.dispose();
      return;
    }
    if (newInfo == null || _shader == null) {
      oldInfo?.image.dispose();
      _finishAnimation();
      return;
    }

    if (isFreshStart) {
      // Fresh transition: upload the captured old snapshot. If the old capture
      // failed (edge case), fall back to the new image as the old texture so
      // the shader still renders something coherent. We must NOT alias
      // _oldSnapshot and _newSnapshot to the same SnapshotInfo here — a later
      // restart would dispose _oldSnapshot.image and feed the now-dead
      // _newSnapshot.image to the shader, crashing it.
      SnapshotInfo effectiveOld;
      if (oldInfo != null) {
        effectiveOld = oldInfo;
      } else {
        final clonedImage = await newInfo.image.clone();
        if (!mounted || !_animating || gen != _captureGeneration) {
          clonedImage.dispose();
          newInfo.image.dispose();
          return;
        }
        effectiveOld = SnapshotInfo(
          clonedImage,
          newInfo.width,
          newInfo.height,
          newInfo.position,
        );
      }
      _oldSnapshot?.image.dispose();
      _shader!.updateOldSnapshot(effectiveOld);
      _shader!.updateNewSnapshot(newInfo);
      _shader!.updateStyleProperties(_styleProps(newInfo));
      setState(() {
        _oldSnapshot = effectiveOld;
        _newSnapshot = newInfo;
        _outgoingChild = null;
      });
    } else {
      // Restart: keep the existing _oldSnapshot (already set + uploaded by
      // _restartMidAnimation). Only capture + upload the new snapshot.
      _shader!.updateNewSnapshot(newInfo);
      _shader!.updateStyleProperties(_styleProps(newInfo));
      setState(() {
        _newSnapshot = newInfo;
      });
    }
    _controller.forward(from: 0);
  }

  Future<void> _nextFrame() {
    final completer = Completer<void>();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future;
  }

  Future<SnapshotInfo?> _captureBoundary(GlobalKey key) async {
    final completer = Completer<SnapshotInfo?>();
    SchedulerBinding.instance.addPostFrameCallback((_) async {
      final boundary =
          key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null || (kDebugMode && boundary.debugNeedsPaint)) {
        completer.complete(null);
        return;
      }
      try {
        final image = await boundary.toImage();
        completer.complete(
          SnapshotInfo(
            image,
            boundary.size.width,
            boundary.size.height,
            boundary.localToGlobal(Offset.zero),
          ),
        );
      } catch (_) {
        completer.complete(null);
      }
    });
    return completer.future;
  }

  ParticleTransitionStyleProps _styleProps(SnapshotInfo info) {
    final (pInRow, pInCol) = widget.style.particleSize.getParticlesAmount(info);
    return ParticleTransitionStyleProps(
      waveDelay: widget.style.waveDelay,
      spreadSpeed: widget.style.spreadSpeed,
      particlesInRow: pInRow,
      particlesInColumn: pInCol,
    );
  }

  void _finishAnimation() {
    if (!mounted) return;
    setState(() {
      _animating = false;
      _outgoingChild = null;
      _oldSnapshot?.image.dispose();
      _newSnapshot?.image.dispose();
      _oldSnapshot = null;
      _newSnapshot = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    final snap = _newSnapshot;

    // --- Animation phase: only the particle overlay is visible ---
    // Both snapshots are already captured and baked into the shader textures,
    // so neither the old nor the new live child is mounted here.
    if (_animating && shader != null && snap != null) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          SizedBox(
            width: snap.width,
            height: snap.height,
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final v = (1.0 + widget.style.waveDelay) * _controller.value;
                  shader.setAnimationValue(v);
                  // A fresh painter instance per frame is REQUIRED.
                  // RenderCustomPaint.painter setter short-circuits on identity
                  // (`if (_painter == value) return;`) and never calls
                  // shouldRepaint, so reusing one instance freezes the painting
                  // at the first frame and the particle animation never plays.
                  return CustomPaint(
                    painter: _ParticlePainter(
                      shader: shader.fragmentShader,
                      outerPadding: widget.outerPadding,
                      animationValue: v,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      );
    }

    // --- Capture phase (fresh transition): old child on top, new child underneath ---
    // Offstage / Visibility(opacity: 0) do NOT paint their children, so
    // RepaintBoundary.toImage() silently fails on them (returns null in debug
    // via debugNeedsPaint, throws a null-layer cast in release that is caught
    // and also yields null). A null snapshot makes _performCapture bail out
    // via _finishAnimation(), so the effect never plays and the child is hard-
    // cut instead.
    //
    // Fix: stack the new child BENEATH the old child. Both are regular
    // (painted) children so both RepaintBoundaries can be snapshotted. The old
    // child on top is what the user sees, hiding the new child underneath
    // (they share the same size/shape, so the cover is exact).
    if (_animating && _outgoingChild != null) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          // New child at bottom: painted + capturable, visually covered.
          RepaintBoundary(
            key: _newCaptureKey,
            child: widget.child,
          ),
          // Old child on top: visible + capturable.
          RepaintBoundary(
            key: _oldCaptureKey,
            child: _outgoingChild!,
          ),
        ],
      );
    }

    // --- Restart capture phase: keep showing the old snapshot via the shader ---
    // _restartMidAnimation promoted _newSnapshot to _oldSnapshot, cleared
    // _outgoingChild, and stopped the controller at value 0. At value 0 the
    // shader renders the old texture unchanged, so showing the overlay here
    // avoids a flash of the raw new child while its snapshot is being captured.
    // _newCaptureKey must still be mounted (beneath the overlay) so the capture
    // can proceed.
    if (_animating && _oldSnapshot != null) {
      final oldSnap = _oldSnapshot!;
      // Ensure the shader renders at value 0 (fully old texture). This is a
      // defensive guard: _restartMidAnimation already resets the value, but if
      // any intermediate frame callback touched it, this keeps the display stable.
      shader!.setAnimationValue(0);
      return Stack(
        clipBehavior: Clip.none,
        children: [
          // New child at bottom: painted + capturable, visually covered by the
          // overlay above.
          RepaintBoundary(
            key: _newCaptureKey,
            child: widget.child,
          ),
          SizedBox(
            width: oldSnap.width,
            height: oldSnap.height,
            child: IgnorePointer(
              child: CustomPaint(
                painter: _ParticlePainter(
                  shader: shader.fragmentShader,
                  outerPadding: widget.outerPadding,
                  animationValue: 0,
                ),
              ),
            ),
          ),
        ],
      );
    }

    // --- Idle ---
    return RepaintBoundary(child: _currentChild);
  }
}

/// A [CustomPainter] that paints the particle transition shader.
///
/// A fresh instance must be created for each animation frame (see the
/// AnimatedBuilder in [ParticleImageTransition.build]); reusing a single
/// instance causes RenderCustomPaint to skip repaints entirely.
class _ParticlePainter extends CustomPainter {
  final FragmentShader shader;
  final EdgeInsets outerPadding;
  final double animationValue;

  _ParticlePainter({
    required this.shader,
    required this.outerPadding,
    required this.animationValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Set the shader's animation value here so the painter is self-contained.
    // This guarantees the correct frame is rendered even when used in a static
    // CustomPaint (e.g. the restart capture phase) where no AnimatedBuilder
    // drives the value externally.
    shader.setFloat(0, animationValue);
    final paint = Paint()..shader = shader;
    canvas.drawRect(
      Rect.fromLTWH(
        -outerPadding.left,
        -outerPadding.top,
        size.width + outerPadding.horizontal,
        size.height + outerPadding.vertical,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) {
    return animationValue != oldDelegate.animationValue;
  }
}
