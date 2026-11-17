#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// Capacities; must match _kSdfMaxBubbles / _kSdfMaxSpots in metaballs.dart.
const int kMaxBubbles = 32;
const int kMaxSpots = 64;

// Float indices are listed for setFloat() in metaballs.dart.
uniform float uK;                     // 0, smooth-min distance (logical px)
uniform float uPx;                    // 1, size of one physical pixel in logical px
uniform float uSharpness;             // 2, color weight falloff: exp(-d * uSharpness)
uniform float uBubbleCount;           // 3
uniform float uSpotCount;             // 4
uniform vec4 uBubbles[kMaxBubbles];   // 5-132, xyzw = center x, center y, radius, opacity
uniform vec4 uColors[kMaxBubbles];    // 133-260, rgb = surface color (straight), w unused
uniform vec4 uMaskColors[kMaxBubbles];// 261-388, rgb = mask color (straight), w unused
uniform vec4 uSpots[kMaxSpots];       // 389-644, xyz = center x, center y, radius, w unused

out vec4 fragColor;

// Source-over for premultiplied colors.
vec4 over(vec4 src, vec4 dst) {
  return src + dst * (1.0 - src.a);
}

void main() {
  vec2 p = FlutterFragCoord().xy;

  // Union distance (polynomial smooth min) and proximity-weighted sums of per-bubble values.
  float d = 100000.0;
  float wSum = 0.0;
  vec4 surface = vec4(0.0); // premultiplied
  vec4 mask = vec4(0.0);    // premultiplied
  float glow = 0.0;         // white, premultiplied alpha

  int n = int(uBubbleCount);
  for (int i = 0; i < kMaxBubbles; i++) {
    if (i >= n) break;
    vec4 b = uBubbles[i];
    float di = distance(p, b.xy) - b.z;

    float h = max(uK - abs(d - di), 0.0) / uK;
    d = min(d, di) - h * h * uK * 0.25;

    // Weight: grows towards the bubble's inside, fades to exactly 0 at the influence distance
    // uK, so bubbles culled by the tile (farther than uK) would contribute nothing anyway.
    float w = exp(-max(di, -3.0 * uK) * uSharpness) *
        (1.0 - smoothstep(0.5 * uK, uK, di));
    if (w > 0.0) {
      float o = b.w;
      wSum += w;
      surface += w * vec4(uColors[i].rgb * o, o);
      mask += w * vec4(uMaskColors[i].rgb * o, o);

      // Inner glow: white radial gradient centered at center - 0.2r with radius 0.8r.
      vec2 glowCenter = b.xy - vec2(b.z * 0.2);
      float gt = clamp(distance(p, glowCenter) / max(b.z * 0.8, 0.001), 0.0, 1.0);
      glow += w * 0.3 * o * (1.0 - gt);
    }
  }

  // Anti-aliased coverage over ~1 physical pixel.
  float coverage = clamp(0.5 - d / uPx, 0.0, 1.0);

  vec4 c = vec4(0.0);
  if (coverage > 0.0 && wSum > 0.0) {
    float invW = 1.0 / wSum;
    surface *= invW;
    mask *= invW;
    glow *= invW;

    // Mask spots: radial gradient [maskColor, transparent] with stops [0.05, 1.0], clamped.
    // Spots share one color here, so stacking them is order-independent: 1 - prod(1 - a).
    float keep = 1.0;
    int m = int(uSpotCount);
    for (int j = 0; j < kMaxSpots; j++) {
      if (j >= m) break;
      vec4 s = uSpots[j];
      float t = clamp((distance(p, s.xy) / s.z - 0.05) / 0.95, 0.0, 1.0);
      keep *= 1.0 - mask.a * (1.0 - t);
    }
    float maskAlpha = 1.0 - keep;
    vec3 maskRgb = mask.rgb / max(mask.a, 0.00001);

    c = surface;
    c = over(vec4(maskRgb * maskAlpha, maskAlpha), c);
    c = over(vec4(glow), c);
    c *= coverage;
  }

  fragColor = c;
}
