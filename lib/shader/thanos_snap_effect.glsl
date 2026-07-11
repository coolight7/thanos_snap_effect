#version 460 core

#include <flutter/runtime_effect.glsl>

#define movement_angles_count 10
#define min_upper_angle -2.2
#define max_upper_angle -0.76
#define min_lower_angle 0.76
#define max_lower_angle 2.2
#define upper_angle_step                                                       \
  (max_upper_angle - min_upper_angle) / movement_angles_count
#define lower_angle_step                                                       \
  (max_lower_angle - min_lower_angle) / movement_angles_count

uniform float animationValue;
uniform float particleLifetime;
uniform float fadeOutDuration;
uniform float particlesInRow;
uniform float particlesInColumn;
uniform float particleSpeed;
uniform vec2 uSize;
uniform sampler2D uImageTexture;

out vec4 fragColor;

float delayFromParticleCenterPos(float x) {
  return (1.0 - particleLifetime) * x;
}

float randomAngleWithRange(int i, float min_angle, float max_angle) {
  float randomValue = fract(sin(float(i) * 12.9898 + 78.233) * 43758.5453);
  float angle_step = (max_angle - min_angle) / movement_angles_count;
  return min_angle + floor(randomValue * movement_angles_count) * angle_step;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize.xy;

  float particleWidth = 1.0 / particlesInRow;
  float particleHeight = 1.0 / particlesInColumn;
  float particlesCount = particlesInRow * particlesInColumn;
  float halfPW = particleWidth * 0.5;
  float halfPH = particleHeight * 0.5;

  for (float searchMovementAngle = min_upper_angle;
       searchMovementAngle <= max_upper_angle;
       searchMovementAngle += upper_angle_step) {
    float cosA = cos(searchMovementAngle);
    float sinA = sin(searchMovementAngle);
    float speedFactor = (1.0 - particleLifetime) * cosA * particleSpeed;
    float x0 =
        (uv.x - animationValue * cosA * particleSpeed) / (1.0 - speedFactor);
    float delay = delayFromParticleCenterPos(x0);
    float y0 = uv.y - (animationValue - delay) * sinA * particleSpeed;

    int i;
    if (cosA < 0.0) {
      if (uv.x >= x0) {
        i = int(uv.x / particleWidth) +
            int(uv.y / particleHeight) * int(particlesInRow);
      } else {
        i = int(x0 / particleWidth) +
            int(y0 / particleHeight) * int(particlesInRow);
      }
    } else if (cosA > 0.0) {
      if (uv.x < x0) {
        i = int(uv.x / particleWidth) +
            int(uv.y / particleHeight) * int(particlesInRow);
      } else {
        i = int(x0 / particleWidth) +
            int(y0 / particleHeight) * int(particlesInRow);
      }
    } else {
      i = int(x0 / particleWidth) +
          int(y0 / particleHeight) * int(particlesInRow);
    }

    if (i < 0 || i >= int(particlesCount)) {
      continue;
    }

    float particleCenterX =
        mod(float(i), particlesInRow) * particleWidth + halfPW;
    float particleCenterY =
        float(int(float(i) / particlesInRow)) * particleHeight + halfPH;

    float min_angle =
        (particleCenterY < 0.5) ? min_upper_angle : min_lower_angle;
    float max_angle =
        (particleCenterY < 0.5) ? max_upper_angle : max_lower_angle;
    float angle = randomAngleWithRange(i, min_angle, max_angle);

    float pDelay = delayFromParticleCenterPos(particleCenterX);
    float adjustedTime = max(0.0, animationValue - pDelay);
    vec2 zeroPointPixelPos =
        vec2(uv.x - adjustedTime * cos(angle) * particleSpeed,
             uv.y - adjustedTime * sin(angle) * particleSpeed);

    if (zeroPointPixelPos.x >= particleCenterX - halfPW &&
        zeroPointPixelPos.x <= particleCenterX + halfPW &&
        zeroPointPixelPos.y >= particleCenterY - halfPH &&
        zeroPointPixelPos.y <= particleCenterY + halfPH) {
      vec4 zeroPointPixelColor = texture(uImageTexture, zeroPointPixelPos);
      float fadeOutLivetime =
          max(0.0, adjustedTime - (particleLifetime - fadeOutDuration));
      float opacity = max(0.0, 1.0 - fadeOutLivetime / fadeOutDuration);
      fragColor = zeroPointPixelColor * opacity;
      return;
    }
  }

  for (float searchMovementAngle = min_lower_angle;
       searchMovementAngle <= max_lower_angle;
       searchMovementAngle += lower_angle_step) {
    float cosA = cos(searchMovementAngle);
    float sinA = sin(searchMovementAngle);
    float speedFactor = (1.0 - particleLifetime) * cosA * particleSpeed;
    float x0 =
        (uv.x - animationValue * cosA * particleSpeed) / (1.0 - speedFactor);
    float delay = delayFromParticleCenterPos(x0);
    float y0 = uv.y - (animationValue - delay) * sinA * particleSpeed;

    int i;
    if (cosA < 0.0) {
      if (uv.x >= x0) {
        i = int(uv.x / particleWidth) +
            int(uv.y / particleHeight) * int(particlesInRow);
      } else {
        i = int(x0 / particleWidth) +
            int(y0 / particleHeight) * int(particlesInRow);
      }
    } else if (cosA > 0.0) {
      if (uv.x < x0) {
        i = int(uv.x / particleWidth) +
            int(uv.y / particleHeight) * int(particlesInRow);
      } else {
        i = int(x0 / particleWidth) +
            int(y0 / particleHeight) * int(particlesInRow);
      }
    } else {
      i = int(x0 / particleWidth) +
          int(y0 / particleHeight) * int(particlesInRow);
    }

    if (i < 0 || i >= int(particlesCount)) {
      continue;
    }

    float particleCenterX =
        mod(float(i), particlesInRow) * particleWidth + halfPW;
    float particleCenterY =
        float(int(float(i) / particlesInRow)) * particleHeight + halfPH;

    float min_angle =
        (particleCenterY < 0.5) ? min_upper_angle : min_lower_angle;
    float max_angle =
        (particleCenterY < 0.5) ? max_upper_angle : max_lower_angle;
    float angle = randomAngleWithRange(i, min_angle, max_angle);

    float pDelay = delayFromParticleCenterPos(particleCenterX);
    float adjustedTime = max(0.0, animationValue - pDelay);
    vec2 zeroPointPixelPos =
        vec2(uv.x - adjustedTime * cos(angle) * particleSpeed,
             uv.y - adjustedTime * sin(angle) * particleSpeed);

    if (zeroPointPixelPos.x >= particleCenterX - halfPW &&
        zeroPointPixelPos.x <= particleCenterX + halfPW &&
        zeroPointPixelPos.y >= particleCenterY - halfPH &&
        zeroPointPixelPos.y <= particleCenterY + halfPH) {
      vec4 zeroPointPixelColor = texture(uImageTexture, zeroPointPixelPos);
      float fadeOutLivetime =
          max(0.0, adjustedTime - (particleLifetime - fadeOutDuration));
      float opacity = max(0.0, 1.0 - fadeOutLivetime / fadeOutDuration);
      fragColor = zeroPointPixelColor * opacity;
      return;
    }
  }

  fragColor = vec4(0.0, 0.0, 0.0, 0.0);
}