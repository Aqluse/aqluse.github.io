#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// Capacity, not a selection: every spot touching the bubble is passed (uSpotCount of them);
// spots beyond the capacity are drawn by the caller the old way.
const int kMaxSpots = 32;

// Float indices are listed for setFloat() in painter.dart.
uniform vec2 uCenter;           // 0-1
uniform float uRadius;          // 2
uniform vec4 uColor;            // 3-6, straight alpha (alpha = opacity)
uniform vec4 uMaskColor;        // 7-10, straight alpha (alpha = opacity)
uniform float uGlowAlpha;       // 11, 0 = no glow
uniform float uSpotCount;       // 12
uniform vec4 uSpots[kMaxSpots]; // 13-140, xyz = center x, center y, radius

out vec4 fragColor;

// Source-over for premultiplied colors.
vec4 over(vec4 src, vec4 dst) {
  return src + dst * (1.0 - src.a);
}

void main() {
  vec2 p = FlutterFragCoord().xy;

  // Surface.
  vec4 c = vec4(uColor.rgb * uColor.a, uColor.a);

  // Mask spots: radial gradient [maskColor, transparent] with stops [0.05, 1.0], clamped.
  int n = int(uSpotCount);
  for (int i = 0; i < kMaxSpots; i++) {
    if (i >= n) break;
    vec4 s = uSpots[i];
    float t = clamp((distance(p, s.xy) / s.z - 0.05) / 0.95, 0.0, 1.0);
    float a = uMaskColor.a * (1.0 - t);
    c = over(vec4(uMaskColor.rgb * a, a), c);
  }

  // Inner glow: white radial gradient centered at center - 0.2r with radius 0.8r.
  if (uGlowAlpha > 0.0) {
    vec2 glowCenter = uCenter - vec2(uRadius * 0.2);
    float t = clamp(distance(p, glowCenter) / (uRadius * 0.8), 0.0, 1.0);
    float a = uGlowAlpha * (1.0 - t);
    c = over(vec4(a, a, a, a), c);
  }

  fragColor = c;
}
