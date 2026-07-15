#version 460 core

#include <flutter/runtime_effect.glsl>

// Upper-half particles spread DOWNWARD (towards the lower half), lower-half
// particles spread UPWARD (towards the upper half), sweeping left-to-right.
// Each particle then returns to its own origin. While travelling, the particle
// color blends from the old texture (at the origin) to the new texture (at the
// same origin), so the final assembled image is the new image.
#define movement_angles_count 10
#define min_upper_angle -2.7
#define max_upper_angle -1.8
#define min_lower_angle 1.8
#define max_lower_angle 2.7

uniform float animationValue;
uniform float waveDelay;
uniform float particlesInRow;
uniform float particlesInColumn;
uniform float spreadSpeed;
uniform vec2 uSize;
uniform sampler2D uOldTexture;
uniform sampler2D uNewTexture;

out vec4 fragColor;

float randomAngleWithRange(int i, float min_angle, float max_angle) {
  float randomValue = fract(sin(float(i) * 12.9898 + 78.233) * 43758.5453);
  float astep = (max_angle - min_angle) / float(movement_angles_count);
  return min_angle + floor(randomValue * float(movement_angles_count)) * astep;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize.xy;

  float particleWidth = 1.0 / particlesInRow;
  float particleHeight = 1.0 / particlesInColumn;
  float halfPW = particleWidth * 0.5;
  float halfPH = particleHeight * 0.5;
  int pIR = int(particlesInRow);
  int pIC = int(particlesInColumn);

  float upperStep = (max_upper_angle - min_upper_angle) / float(movement_angles_count);
  float lowerStep = (max_lower_angle - min_lower_angle) / float(movement_angles_count);

  // Search upper-half-origin angles.
  // Upper-half origins spread DOWNWARD: they use the lower-angle range.
  for (int s = 0; s < movement_angles_count; s++) {
    float ang = min_lower_angle + float(s) * lowerStep;
    float cosA = cos(ang);
    float sinA = sin(ang);

    // --- Phase A: outward spread, t in [0, 0.5] ---
    float denomA = 1.0 - 2.0 * waveDelay * spreadSpeed * cosA;
    if (abs(denomA) > 0.0001) {
      float cxA = (uv.x - 2.0 * animationValue * spreadSpeed * cosA) / denomA;
      if (cxA >= 0.0 && cxA <= 1.0) {
        int colA = int(cxA / particleWidth);
        if (colA >= 0 && colA < pIR) {
          float pcxA = float(colA) * particleWidth + halfPW;
          float tA = animationValue - waveDelay * pcxA;
          if (tA >= 0.0 && tA <= 0.5) {
            float cyA = uv.y - 2.0 * tA * spreadSpeed * sinA;
            if (cyA >= 0.0 && cyA <= 1.0) {
              int rowA = int(cyA / particleHeight);
              if (rowA >= 0 && rowA < pIC) {
                float pcyA = float(rowA) * particleHeight + halfPH;
                if (pcyA < 0.5) {
                  int iA = colA + rowA * pIR;
                  float pAng = randomAngleWithRange(iA, min_lower_angle, max_lower_angle);
                  if (abs(pAng - ang) < 0.001) {
                    float curX = pcxA + 2.0 * tA * spreadSpeed * cosA;
                    float curY = pcyA + 2.0 * tA * spreadSpeed * sinA;
                    if (uv.x >= curX - halfPW && uv.x <= curX + halfPW &&
                        uv.y >= curY - halfPH && uv.y <= curY + halfPH) {
                      vec2 originUV = vec2(pcxA, pcyA);
                      vec4 oldC = texture(uOldTexture, originUV);
                      vec4 newC = texture(uNewTexture, originUV);
                      fragColor = mix(oldC, newC, clamp(tA, 0.0, 1.0));
                      return;
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    // --- Phase B: return to origin, t in [0.5, 1] ---
    float denomB = 1.0 + 2.0 * waveDelay * spreadSpeed * cosA;
    if (abs(denomB) > 0.0001) {
      float cxB = (uv.x - 2.0 * spreadSpeed * cosA * (1.0 - animationValue)) / denomB;
      if (cxB >= 0.0 && cxB <= 1.0) {
        int colB = int(cxB / particleWidth);
        if (colB >= 0 && colB < pIR) {
          float pcxB = float(colB) * particleWidth + halfPW;
          float tB = animationValue - waveDelay * pcxB;
          if (tB >= 0.5 && tB <= 1.0) {
            float cyB = uv.y - (2.0 - 2.0 * tB) * spreadSpeed * sinA;
            if (cyB >= 0.0 && cyB <= 1.0) {
              int rowB = int(cyB / particleHeight);
              if (rowB >= 0 && rowB < pIC) {
                float pcyB = float(rowB) * particleHeight + halfPH;
                if (pcyB < 0.5) {
                  int iB = colB + rowB * pIR;
                  float pAng = randomAngleWithRange(iB, min_lower_angle, max_lower_angle);
                  if (abs(pAng - ang) < 0.001) {
                    float curX = pcxB + (2.0 - 2.0 * tB) * spreadSpeed * cosA;
                    float curY = pcyB + (2.0 - 2.0 * tB) * spreadSpeed * sinA;
                    if (uv.x >= curX - halfPW && uv.x <= curX + halfPW &&
                        uv.y >= curY - halfPH && uv.y <= curY + halfPH) {
                      vec2 originUV = vec2(pcxB, pcyB);
                      vec4 oldC = texture(uOldTexture, originUV);
                      vec4 newC = texture(uNewTexture, originUV);
                      fragColor = mix(oldC, newC, clamp(tB, 0.0, 1.0));
                      return;
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // Search lower-half-origin angles.
  // Lower-half origins spread UPWARD: they use the upper-angle range.
  for (int s = 0; s < movement_angles_count; s++) {
    float ang = min_upper_angle + float(s) * upperStep;
    float cosA = cos(ang);
    float sinA = sin(ang);

    // --- Phase A: outward spread, t in [0, 0.5] ---
    float denomA = 1.0 - 2.0 * waveDelay * spreadSpeed * cosA;
    if (abs(denomA) > 0.0001) {
      float cxA = (uv.x - 2.0 * animationValue * spreadSpeed * cosA) / denomA;
      if (cxA >= 0.0 && cxA <= 1.0) {
        int colA = int(cxA / particleWidth);
        if (colA >= 0 && colA < pIR) {
          float pcxA = float(colA) * particleWidth + halfPW;
          float tA = animationValue - waveDelay * pcxA;
          if (tA >= 0.0 && tA <= 0.5) {
            float cyA = uv.y - 2.0 * tA * spreadSpeed * sinA;
            if (cyA >= 0.0 && cyA <= 1.0) {
              int rowA = int(cyA / particleHeight);
              if (rowA >= 0 && rowA < pIC) {
                float pcyA = float(rowA) * particleHeight + halfPH;
                if (pcyA >= 0.5) {
                  int iA = colA + rowA * pIR;
                  float pAng = randomAngleWithRange(iA, min_upper_angle, max_upper_angle);
                  if (abs(pAng - ang) < 0.001) {
                    float curX = pcxA + 2.0 * tA * spreadSpeed * cosA;
                    float curY = pcyA + 2.0 * tA * spreadSpeed * sinA;
                    if (uv.x >= curX - halfPW && uv.x <= curX + halfPW &&
                        uv.y >= curY - halfPH && uv.y <= curY + halfPH) {
                      vec2 originUV = vec2(pcxA, pcyA);
                      vec4 oldC = texture(uOldTexture, originUV);
                      vec4 newC = texture(uNewTexture, originUV);
                      fragColor = mix(oldC, newC, clamp(tA, 0.0, 1.0));
                      return;
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    // --- Phase B: return to origin, t in [0.5, 1] ---
    float denomB = 1.0 + 2.0 * waveDelay * spreadSpeed * cosA;
    if (abs(denomB) > 0.0001) {
      float cxB = (uv.x - 2.0 * spreadSpeed * cosA * (1.0 - animationValue)) / denomB;
      if (cxB >= 0.0 && cxB <= 1.0) {
        int colB = int(cxB / particleWidth);
        if (colB >= 0 && colB < pIR) {
          float pcxB = float(colB) * particleWidth + halfPW;
          float tB = animationValue - waveDelay * pcxB;
          if (tB >= 0.5 && tB <= 1.0) {
            float cyB = uv.y - (2.0 - 2.0 * tB) * spreadSpeed * sinA;
            if (cyB >= 0.0 && cyB <= 1.0) {
              int rowB = int(cyB / particleHeight);
              if (rowB >= 0 && rowB < pIC) {
                float pcyB = float(rowB) * particleHeight + halfPH;
                if (pcyB >= 0.5) {
                  int iB = colB + rowB * pIR;
                  float pAng = randomAngleWithRange(iB, min_upper_angle, max_upper_angle);
                  if (abs(pAng - ang) < 0.001) {
                    float curX = pcxB + (2.0 - 2.0 * tB) * spreadSpeed * cosA;
                    float curY = pcyB + (2.0 - 2.0 * tB) * spreadSpeed * sinA;
                    if (uv.x >= curX - halfPW && uv.x <= curX + halfPW &&
                        uv.y >= curY - halfPH && uv.y <= curY + halfPH) {
                      vec2 originUV = vec2(pcxB, pcyB);
                      vec4 oldC = texture(uOldTexture, originUV);
                      vec4 newC = texture(uNewTexture, originUV);
                      fragColor = mix(oldC, newC, clamp(tB, 0.0, 1.0));
                      return;
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // Fallback: no moving particle covers uv.
  int colR = int(uv.x / particleWidth);
  int rowR = int(uv.y / particleHeight);
  if (colR >= 0 && colR < pIR && rowR >= 0 && rowR < pIC) {
    float pcxR = float(colR) * particleWidth + halfPW;
    float tR = animationValue - waveDelay * pcxR;
    if (tR <= 0.0) {
      fragColor = texture(uOldTexture, uv);
      return;
    }
    if (tR >= 1.0) {
      fragColor = texture(uNewTexture, uv);
      return;
    }
  }

  fragColor = vec4(0.0, 0.0, 0.0, 0.0);
}
