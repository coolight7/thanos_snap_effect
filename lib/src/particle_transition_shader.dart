import 'dart:ui';

import 'package:thanos_snap_effect/src/snapshot/snapshot_info.dart';

/// Shader for the particle transition effect (old image spreads into
/// particles and returns while blending into the new image).
class ParticleTransitionShader {
  /// The path to the fragment shader code
  static const path =
      'packages/thanos_snap_effect/shader/particle_transition.glsl';

  final FragmentShader _fragmentShader;

  FragmentShader get fragmentShader => _fragmentShader;

  ParticleTransitionShader(this._fragmentShader);

  void setAnimationValue(double value) {
    _fragmentShader.setFloat(0, value);
  }

  void updateStyleProperties(ParticleTransitionStyleProps props) {
    _fragmentShader.setFloat(1, props.waveDelay);
    _fragmentShader.setFloat(2, props.particlesInRow.toDouble());
    _fragmentShader.setFloat(3, props.particlesInColumn.toDouble());
    _fragmentShader.setFloat(4, props.spreadSpeed);
  }

  /// Sets the old (source) snapshot texture and the shared size uniform.
  void updateOldSnapshot(SnapshotInfo snapshotInfo) {
    _fragmentShader.setFloat(5, snapshotInfo.width);
    _fragmentShader.setFloat(6, snapshotInfo.height);
    _fragmentShader.setImageSampler(0, snapshotInfo.image);
  }

  /// Sets the new (target) snapshot texture.
  void updateNewSnapshot(SnapshotInfo snapshotInfo) {
    _fragmentShader.setImageSampler(1, snapshotInfo.image);
  }
}

/// Style properties for the particle transition shader.
class ParticleTransitionStyleProps {
  /// Left-to-right wave delay factor (0.0 - 1.0). Larger => longer wave sweep.
  final double waveDelay;

  /// How far particles spread from their origin (in uv units).
  final double spreadSpeed;

  final int particlesInRow;
  final int particlesInColumn;

  ParticleTransitionStyleProps({
    required this.waveDelay,
    required this.spreadSpeed,
    required this.particlesInRow,
    required this.particlesInColumn,
  });
}
