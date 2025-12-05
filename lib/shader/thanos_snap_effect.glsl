#version 460 core

#include <flutter/runtime_effect.glsl>

#define movement_angles_count 10
// 上半部分
#define min_upper_angle -2.2  // ~-126°
#define max_upper_angle -0.76 // ~-43°
#define upper_angle_step                                                       \
  (max_upper_angle - min_upper_angle) / movement_angles_count
// 下半部分
#define min_lower_angle 0.76 // ~43°
#define max_lower_angle 2.2  // ~126°
#define lower_angle_step                                                       \
  (max_lower_angle - min_lower_angle) / movement_angles_count
#define pi 3.14159265359

// Current animation value, from 0.0 to 1.0.
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
  return (1. - particleLifetime) * x;
}

float randomAngleWithRange(int i, float min_angle, float max_angle) {
  float randomValue = fract(sin(float(i) * 12.9898 + 78.233) * 43758.5453);
  float angle_step = (max_angle - min_angle) / movement_angles_count;
  return min_angle + floor(randomValue * movement_angles_count) * angle_step;
}

int calculateInitialParticleIndex(vec2 point, float angle, float animationValue,
                                  float particleWidth, float particleHeight) {
  float x0 = (point.x - animationValue * cos(angle) * particleSpeed) /
             (1. - (1. - particleLifetime) * cos(angle) * particleSpeed);
  float delay = delayFromParticleCenterPos(x0);
  float y0 = point.y - (animationValue - delay) * sin(angle) * particleSpeed;

  //  If particle is not yet moved, animationValue is less than delay, and
  //  particle moves to an opposite direction so we should calculate a particle
  //  index from the original point.

  // 根据 cos(angle) 符号判断运动方向
  float cosAngle = cos(angle);
  if (cosAngle < 0.0) {
    // 向左运动
    if (point.x >= x0) {
      return (int(point.x / particleWidth) +
              int(point.y / particleHeight) * int(1.0 / particleWidth));
    }
  } else if (cosAngle > 0.0) {
    // 向右运动
    if (point.x < x0) {
      return (int(point.x / particleWidth) +
              int(point.y / particleHeight) * int(1.0 / particleWidth));
    }
  }

  // 返回初始位置对应的粒子索引
  return int(x0 / particleWidth) +
         int(y0 / particleHeight) * int(1.0 / particleWidth);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize.xy;

  float particleWidth = 1.0 / particlesInRow;
  float particleHeight = 1.0 / particlesInColumn;
  float particlesCount = (1.0 / particleWidth) * (1.0 / particleHeight);

  // 上半向上
  for (float searchMovementAngle = min_upper_angle;
       searchMovementAngle <= max_upper_angle;
       searchMovementAngle += upper_angle_step) {
    int i = calculateInitialParticleIndex(
        uv, searchMovementAngle, animationValue, particleWidth, particleHeight);
    if (i < 0 || i >= particlesCount) {
      continue;
    }

    // 粒子初始位置，决定角度范围
    vec2 particleCenterPos =
        vec2(mod(float(i), 1.0 / particleWidth) * particleWidth +
                 particleWidth / 2.0,
             int(float(i) / (1.0 / particleWidth)) * particleHeight +
                 particleHeight / 2.0);
    // 根据粒子 Y 坐标选择角度范围
    float min_angle =
        (particleCenterPos.y < 0.5) ? min_upper_angle : min_lower_angle;
    float max_angle =
        (particleCenterPos.y < 0.5) ? max_upper_angle : max_lower_angle;
    float angle = randomAngleWithRange(i, min_angle, max_angle);

    float delay = delayFromParticleCenterPos(particleCenterPos.x);
    float adjustedTime = max(0.0, animationValue - delay);
    vec2 zeroPointPixelPos =
        vec2(uv.x - adjustedTime * cos(angle) * particleSpeed,
             uv.y - adjustedTime * sin(angle) * particleSpeed);

    // 检查是否在粒子初始范围内
    if (zeroPointPixelPos.x >= particleCenterPos.x - particleWidth / 2.0 &&
        zeroPointPixelPos.x <= particleCenterPos.x + particleWidth / 2.0 &&
        zeroPointPixelPos.y >= particleCenterPos.y - particleHeight / 2.0 &&
        zeroPointPixelPos.y <= particleCenterPos.y + particleHeight / 2.0) {
      vec4 zeroPointPixelColor = texture(uImageTexture, zeroPointPixelPos);
      float fadeOutLivetime =
          max(0.0, adjustedTime - (particleLifetime - fadeOutDuration));
      float opacity = max(0.0, 1.0 - fadeOutLivetime / fadeOutDuration);
      fragColor = zeroPointPixelColor * opacity;
      return;
    }
  }

  // 下半部分向下
  for (float searchMovementAngle = min_lower_angle;
       searchMovementAngle <= max_lower_angle;
       searchMovementAngle += lower_angle_step) {
    int i = calculateInitialParticleIndex(
        uv, searchMovementAngle, animationValue, particleWidth, particleHeight);
    if (i < 0 || i >= particlesCount) {
      continue;
    }

    vec2 particleCenterPos =
        vec2(mod(float(i), 1.0 / particleWidth) * particleWidth +
                 particleWidth / 2.0,
             int(float(i) / (1.0 / particleWidth)) * particleHeight +
                 particleHeight / 2.0);
    float min_angle =
        (particleCenterPos.y < 0.5) ? min_upper_angle : min_lower_angle;
    float max_angle =
        (particleCenterPos.y < 0.5) ? max_upper_angle : max_lower_angle;
    float angle = randomAngleWithRange(i, min_angle, max_angle);

    float delay = delayFromParticleCenterPos(particleCenterPos.x);
    float adjustedTime = max(0.0, animationValue - delay);
    vec2 zeroPointPixelPos =
        vec2(uv.x - adjustedTime * cos(angle) * particleSpeed,
             uv.y - adjustedTime * sin(angle) * particleSpeed);

    if (zeroPointPixelPos.x >= particleCenterPos.x - particleWidth / 2.0 &&
        zeroPointPixelPos.x <= particleCenterPos.x + particleWidth / 2.0 &&
        zeroPointPixelPos.y >= particleCenterPos.y - particleHeight / 2.0 &&
        zeroPointPixelPos.y <= particleCenterPos.y + particleHeight / 2.0) {
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