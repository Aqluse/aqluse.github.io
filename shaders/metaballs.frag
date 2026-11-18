#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// Capacities: kMaxEvents events and 4 * kMaxSpotGroups spots per draw.
// Must match _kSdfMaxEvents / _kSdfMaxSpots in metaballs.dart.
// Uniform budget: 4 + 40 * 3 + 32 * 3 = 220 vec4.
const int kMaxEvents = 40;
const int kMaxSpotGroups = 32;

// Float indices are listed for setFloat() in metaballs.dart. Every array is indexed by the
// loop counter only; spots go in groups of 4 (unused slots are padded with dummies that
// contribute nothing).
//
// Events are listed bottom to top (layer order). Each event holds two bubbles: first the neck
// between `lower` and `upper` is stacked (a far away dummy `lower` with zero radius means no
// neck), then, if flagged, the upper bubble itself. A bubble with necks to lower bubbles is
// flagged on its last neck event, so its necks lie right under it and above every bubble with
// a lower index.
uniform vec4 uParams0;                // 0-3: k, AA width (logical px), color sharpness, depth clamp
uniform vec4 uParams1;                // 4-7: size bias, reference radius, event count, group count
uniform vec4 uEventsA[kMaxEvents];    // 8-167: lower bubble: center x, center y, radius, opacity
uniform vec4 uEventsB[kMaxEvents];    // 168-327: upper bubble: center x, center y, radius, and
                                      // opacity o if the bubble is drawn here, else -1 - o
uniform vec4 uEventsC[kMaxEvents];    // 328-487: packed rgb: surface lower, mask lower,
                                      // surface upper, mask upper
uniform vec4 uSpotsA[kMaxSpotGroups]; // 488-615: spots 4i..4i+3 as 4 x (x, y, radius),
uniform vec4 uSpotsB[kMaxSpotGroups]; // 616-743: spread over A, B, C
uniform vec4 uSpotsC[kMaxSpotGroups]; // 744-871
uniform vec4 uParams2;                // 872-875: stacking (0 or 1), edge fade (logical px), spot strength, spot core
uniform vec4 uParams3;                // 876-879: spot falloff exponent, unused, unused, unused

out vec4 fragColor;

// Source-over for premultiplied colors.
vec4 over(vec4 src, vec4 dst) {
  return src + dst * (1.0 - src.a);
}

// Polynomial smooth minimum.
float smin(float a, float b, float k) {
  float h = max(k - abs(a - b), 0.0) / k;
  return min(a, b) - h * h * k * 0.25;
}

// 0xRRGGBB stored in a float (exact up to 2^24).
vec3 unpackRgb(float v) {
  float r = floor((v + 0.5) / 65536.0);
  float rest = v - r * 65536.0;
  float g = floor((rest + 0.5) / 256.0);
  float b = rest - g * 256.0;
  return vec3(r, g, b) / 255.0;
}

// Color weight of a bubble at signed distance di: grows towards the inside (up to the depth
// clamp), optionally favors bigger bubbles, and fades to exactly 0 at distance k.
float weight(float di, float radius) {
  float e = -max(di, -uParams0.w) * uParams0.z + (radius - uParams1.y) * uParams1.x;
  return exp(clamp(e, -80.0, 80.0)) *
      (1.0 - smoothstep(0.5 * uParams0.x, uParams0.x, di));
}

// Inner glow alpha: white radial gradient centered at center - 0.2r with radius 0.8r.
float glowAlpha(vec2 p, vec4 b) {
  vec2 glowCenter = b.xy - vec2(b.z * 0.2);
  float t = clamp(distance(p, glowCenter) / max(b.z * 0.8, 0.001), 0.0, 1.0);
  return 0.3 * b.w * (1.0 - t);
}

// Mask spot: radial gradient [maskColor, transparent], solid up to the core fraction of the
// radius, then fading as (1 - t)^falloff, scaled by strength (original: core 0.05, falloff 1,
// strength 1). Returns the remaining transparency factor for mask opacity o.
// Must match the culling estimate in metaballs.dart (_spotAlphaAt).
float spotKeep(vec2 p, vec3 s, float o) {
  float core = uParams2.w;
  float t = clamp((distance(p, s.xy) / s.z - core) / max(1.0 - core, 0.001), 0.0, 1.0);
  return 1.0 - clamp(o * uParams2.z * pow(1.0 - t, uParams3.x), 0.0, 1.0);
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  float k = uParams0.x;

  // Union distance (smooth min) and proximity-weighted sums of per-bubble values.
  float d = 100000.0;
  float wSum = 0.0;
  vec4 surface = vec4(0.0); // premultiplied
  vec4 mask = vec4(0.0);    // premultiplied
  float glow = 0.0;         // white, premultiplied alpha

  // Stacking: bubbles and necks arrive bottom to top (event order), so lerping towards each
  // one's values by its own coverage leaves the top covering one's values, with a soft
  // transition across its edge. stackKeep = how much of the pixel is outside every bubble and
  // stacked neck (there the weighted blend is used).
  float stacking = uParams2.x;
  // Transition width across the top bubble's edge, separate from the neck color fade.
  float edge = max(uParams2.y, uParams0.y);
  vec4 stackSurface = vec4(0.0);
  vec4 stackMask = vec4(0.0);
  float stackGlow = 0.0;
  float stackKeep = 1.0;

  int events = int(uParams1.z);
  for (int i = 0; i < kMaxEvents; i++) {
    if (i >= events) break;
    vec4 lowB = uEventsA[i];
    vec4 upB = uEventsB[i];
    vec4 colors = uEventsC[i];
    // The upper bubble with its opacity decoded from the flag: o >= 0 as is, -1 - o -> o.
    vec4 ub = vec4(upB.xyz, abs(upB.w + 0.5) - 0.5);
    float du = distance(p, ub.xy) - ub.z;
    float dl = distance(p, lowB.xy) - lowB.z;

    // Neck: only the coverage the pair's smooth union adds to the two shapes (0 inside either
    // bubble and wherever they don't fuse), colored by the pair's weighted blend.
    float cn = stacking * max(
        clamp(0.5 - smin(dl, du, k) / edge, 0.0, 1.0) -
            clamp(0.5 - min(dl, du) / edge, 0.0, 1.0),
        0.0);
    if (cn > 0.0) {
      float wl = weight(dl, lowB.z);
      float wu = weight(du, ub.z);
      float wn = wl + wu;
      if (wn > 0.0) {
        float invN = 1.0 / wn;
        vec4 ns = (wl * vec4(unpackRgb(colors.x) * lowB.w, lowB.w) +
            wu * vec4(unpackRgb(colors.z) * ub.w, ub.w)) * invN;
        vec4 nm = (wl * vec4(unpackRgb(colors.y) * lowB.w, lowB.w) +
            wu * vec4(unpackRgb(colors.w) * ub.w, ub.w)) * invN;
        float ng = (wl * glowAlpha(p, lowB) + wu * glowAlpha(p, ub)) * invN;
        stackSurface = mix(stackSurface, ns, cn);
        stackMask = mix(stackMask, nm, cn);
        stackGlow = mix(stackGlow, ng, cn);
        stackKeep *= 1.0 - cn;
      }
    }

    // The upper bubble itself, on top of its necks.
    if (upB.w >= 0.0) {
      d = smin(d, du, k);
      float w = weight(du, ub.z);
      vec4 bs = vec4(unpackRgb(colors.z) * ub.w, ub.w);
      vec4 bm = vec4(unpackRgb(colors.w) * ub.w, ub.w);
      float bg = glowAlpha(p, ub);
      wSum += w;
      surface += w * bs;
      mask += w * bm;
      glow += w * bg;
      float ci = stacking * clamp(0.5 - du / edge, 0.0, 1.0);
      stackSurface = mix(stackSurface, bs, ci);
      stackMask = mix(stackMask, bm, ci);
      stackGlow = mix(stackGlow, bg, ci);
      stackKeep *= 1.0 - ci;
    }
  }

  // Anti-aliased coverage over the AA width.
  float coverage = clamp(0.5 - d / uParams0.y, 0.0, 1.0);

  vec4 c = vec4(0.0);
  if (coverage > 0.0 && wSum > 0.0) {
    float invW = 1.0 / wSum;
    surface *= invW;
    mask *= invW;
    glow *= invW;

    // Inside bubbles and stacked necks: the stacked (top) values; the stack sums started from 0
    // and carry total weight `inside`, hence the normalization.
    float inside = 1.0 - stackKeep;
    if (inside > 0.0) {
      float invInside = 1.0 / inside;
      surface = mix(surface, stackSurface * invInside, inside);
      mask = mix(mask, stackMask * invInside, inside);
      glow = mix(glow, stackGlow * invInside, inside);
    }

    // Spots share one color here, so stacking them is order-independent: 1 - prod(1 - a).
    float o = mask.a;
    float keep = 1.0;
    int groups = int(uParams1.w);
    for (int j = 0; j < kMaxSpotGroups; j++) {
      if (j >= groups) break;
      vec4 a = uSpotsA[j];
      vec4 b = uSpotsB[j];
      vec4 s = uSpotsC[j];
      keep *= spotKeep(p, a.xyz, o);
      keep *= spotKeep(p, vec3(a.w, b.x, b.y), o);
      keep *= spotKeep(p, vec3(b.z, b.w, s.x), o);
      keep *= spotKeep(p, s.yzw, o);
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
