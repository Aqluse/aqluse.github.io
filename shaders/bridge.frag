#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// Capacity, not a selection: every spot near the bridge is passed (uSpotCount of them);
// spots beyond the capacity are drawn by the caller the old way.
const int kMaxSpots = 64;

// Float indices are listed for setFloat() in painter.dart. Colors use straight alpha.
uniform vec2 uStart;            // 0-1, bubble1 center
uniform vec2 uEnd;              // 2-3, bubble2 center
uniform vec4 uColor1;           // 4-7
uniform vec4 uColor2;           // 8-11
uniform vec2 uStops;            // 12-13, s1, s2 of the [c1, c1, c2, c2] gradient
uniform vec4 uMaskColor1;       // 14-17
uniform vec4 uMaskColor2;       // 18-21
uniform float uSpotCount;       // 22
uniform vec4 uSpots[kMaxSpots]; // 23-278, xyz = center x, center y, radius; w = mask color mix

out vec4 fragColor;

// Source-over for premultiplied colors.
vec4 over(vec4 src, vec4 dst) {
  return src + dst * (1.0 - src.a);
}

void main() {
  vec2 p = FlutterFragCoord().xy;

  // Base: linear gradient from uStart to uEnd, colors [c1, c1, c2, c2], stops [0, s1, s2, 1].
  vec2 axis = uEnd - uStart;
  float u = clamp(dot(p - uStart, axis) / dot(axis, axis), 0.0, 1.0);
  vec4 base;
  if (u <= uStops.x) {
    base = uColor1;
  } else if (u >= uStops.y) {
    base = uColor2;
  } else {
    base = mix(uColor1, uColor2, (u - uStops.x) / (uStops.y - uStops.x));
  }
  vec4 c = vec4(base.rgb * base.a, base.a);

  // Mask spots: radial gradient [color, transparent] with stops [0.05, 1.0], clamped.
  int n = int(uSpotCount);
  for (int i = 0; i < kMaxSpots; i++) {
    if (i >= n) break;
    vec4 s = uSpots[i];
    vec4 m = mix(uMaskColor1, uMaskColor2, s.w);
    float t = clamp((distance(p, s.xy) / s.z - 0.05) / 0.95, 0.0, 1.0);
    float a = m.a * (1.0 - t);
    c = over(vec4(m.rgb * a, a), c);
  }

  fragColor = c;
}
