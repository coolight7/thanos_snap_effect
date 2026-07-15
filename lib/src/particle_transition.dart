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
  _ParticlePainter? _painter;

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
    // Keep the old (outgoing) child off-stage so it can be snapshotted.
    _outgoingChild = _currentChild;
    _animating = true;
    _oldSnapshot?.image.dispose();
    _newSnapshot?.image.dispose();
    _oldSnapshot = null;
    _newSnapshot = null;
    _controller.value = 0;
    _currentChild = widget.child;
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
    // Promote current new -> old. No disposal: the image object is reused.
    _oldSnapshot?.image.dispose();
    _oldSnapshot = _newSnapshot;
    _newSnapshot = null;
    _outgoingChild = null;
    _controller.stop();
    _shader!.updateOldSnapshot(_oldSnapshot!);
    setState(() {});
    _scheduleCapture();
  }

  void _scheduleCapture() {
    if (_captureInProgress) return;
    final delay = widget.delayCapture ?? const Duration(milliseconds: 120);
    _captureInProgress = true;
    Future.delayed(delay, _performCapture);
  }

  Future<void> _performCapture() async {
    _captureInProgress = false;
    if (!mounted || !_animating) return;
    await _nextFrame();
    if (!mounted || !_animating) return;

    // Capture old (if an outgoing child is staged) and new snapshots.
    SnapshotInfo? oldInfo;
    if (_outgoingChild != null) {
      oldInfo = await _captureBoundary(_oldCaptureKey);
    }
    final newInfo = await _captureBoundary(_newCaptureKey);
    if (!mounted || !_animating) {
      oldInfo?.image.dispose();
      newInfo?.image.dispose();
      return;
    }
    if (newInfo == null || _shader == null) {
      _finishAnimation();
      return;
    }
    // For the first transition there is no old snapshot; use the new one as
    // both so the shader renders a stable image (no visible dissolve).
    final effectiveOld = oldInfo ?? newInfo;
    if (oldInfo != null && !identical(oldInfo, effectiveOld)) {
      oldInfo.image.dispose();
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

    // Off-stage capture target for the incoming child, always mounted so it can
    // be snapshotted at any time. Offstage keeps it fully off-screen (no flash).
    final newCapture = Offstage(
      child: RepaintBoundary(
        key: _newCaptureKey,
        child: widget.child,
      ),
    );

    // Off-stage capture target for the outgoing child, only mounted during the
    // capture phase of a fresh transition.
    final oldCapture = (_outgoingChild != null)
        ? Offstage(
            child: RepaintBoundary(
              key: _oldCaptureKey,
              child: _outgoingChild!,
            ),
          )
        : const SizedBox.shrink();

    if (!_animating || shader == null || snap == null) {
      // Idle (or waiting for first capture): show the live child directly.
      return Stack(
        clipBehavior: Clip.none,
        children: [
          RepaintBoundary(child: _currentChild),
          newCapture,
          oldCapture,
        ],
      );
    }

    // Particle phase: only the overlay is visible. Both capture targets stay
    // off-stage so neither the old nor the new live child can flash.
    _painter ??= _ParticlePainter(
      shader: shader.fragmentShader,
      outerPadding: widget.outerPadding,
    );

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
                _painter!._animationValue = v;
                return CustomPaint(painter: _painter!);
              },
            ),
          ),
        ),
        newCapture,
        oldCapture,
      ],
    );
  }
}

/// A [CustomPainter] that paints the particle transition shader. Mutable so a
/// single instance can be reused across frames without reallocation.
class _ParticlePainter extends CustomPainter {
  final FragmentShader shader;
  final EdgeInsets outerPadding;
  double _animationValue;

  _ParticlePainter({
    required this.shader,
    required this.outerPadding,
    double animationValue = 0,
  }) : _animationValue = animationValue;

  @override
  void paint(Canvas canvas, Size size) {
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
    return _animationValue != oldDelegate._animationValue;
  }
}
