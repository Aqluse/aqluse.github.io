#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// Capacities: 2 * kMaxBubblePairs bubbles and 4 * kMaxSpotGroups spots per draw.
// Must match _kSdfMaxBubbles / _kSdfMaxSpots in metaballs.dart.
// Uniform budget: 3 + 32 * 3 + 32 * 3 = 195 vec4.
const int kMaxBubblePairs = 32;
const int kMaxSpotGroups = 32;

// Float indices are listed for setFloat() in metaballs.dart. Every array is indexed by the
// loop counter only; bubbles go in pairs and spots in groups of 4 (unused slots are padded
// with dummies that contribute nothing).
uniform vec4 uParams0;                  // 0-3: k, AA width (logical px), color sharpness, depth clamp
uniform vec4 uParams1;                  // 4-7: size bias, reference radius, pair count, group count
uniform vec4 uBubblesA[kMaxBubblePairs];// 8-135: bubble 2i: center x, center y, radius, opacity
uniform vec4 uBubblesB[kMaxBubblePairs];// 136-263: bubble 2i+1, same layout
uniform vec4 uColors[kMaxBubblePairs];  // 264-391: packed rgb: surface 2i, mask 2i, surface 2i+1, mask 2i+1
uniform vec4 uSpotsA[kMaxSpotGroups];   // 392-519: spots 4i..4i+3 as 4 x (x, y, radius),
uniform vec4 uSpotsB[kMaxSpotGroups];   // 520-647: spread over A, B, C
uniform vec4 uSpotsC[kMaxSpotGroups];   // 648-775
uniform vec4 uParams2;                  // 776-779: stacking (0 or 1), edge fade (logical px), spot strength, spot core
uniform vec4 uParams3;                  // 780-783: spot falloff exponent, unused, unused, unused

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

  // Stacking: bubbles arrive bottom to top (list order), so lerping towards each bubble's
  // values by its own edge coverage leaves the top covering bubble's values inside bubbles,
  // with a soft transition across its edge. stackKeep = how much of the pixel is outside every
  // bubble (there the weighted blend is used, as for the necks).
  float stacking = uParams2.x;
  // Transition width across the top bubble's edge, separate from the neck color fade.
  float edge = max(uParams2.y, uParams0.y);
  vec4 stackSurface = vec4(0.0);
  vec4 stackMask = vec4(0.0);
  float stackGlow = 0.0;
  float stackKeep = 1.0;

  // Layered necks: nDist = smooth union of the lower bubbles this pixel is OUTSIDE of, with their
  // weighted value sums. A bubble's neck with them is the area their smooth union adds beyond
  // the shapes themselves; it is stacked at that bubble's layer, so necks between upper bubbles
  // stay visible over lower bubbles and are hidden by higher ones (the old renderer's order).
  float nDist = 100000.0;
  float nW = 0.0;
  vec4 nSurface = vec4(0.0);
  vec4 nMask = vec4(0.0);
  float nGlow = 0.0;

  int pairs = int(uParams1.z);
  for (int i = 0; i < kMaxBubblePairs; i++) {
    if (i >= pairs) break;
    vec4 colors = uColors[i];

    // ---- Bubble 2i (same code as bubble 2i + 1 below) ----
    vec4 b = uBubblesA[i];
    float di = distance(p, b.xy) - b.z;
    d = smin(d, di, k);
    float w = weight(di, b.z);
    vec4 bs = vec4(unpackRgb(colors.x) * b.w, b.w);
    vec4 bm = vec4(unpackRgb(colors.y) * b.w, b.w);
    float bg = glowAlpha(p, b);
    wSum += w;
    surface += w * bs;
    mask += w * bm;
    glow += w * bg;
    // Neck with the lower outside bubbles: only the coverage added by the smooth union.
    float dn = smin(di, nDist, k);
    float cn = stacking * max(
        clamp(0.5 - dn / edge, 0.0, 1.0) - clamp(0.5 - min(di, nDist) / edge, 0.0, 1.0),
        0.0);
    float nwi = nW + w;
    if (cn > 0.0 && nwi > 0.0) {
      float invN = 1.0 / nwi;
      stackSurface = mix(stackSurface, (nSurface + w * bs) * invN, cn);
      stackMask = mix(stackMask, (nMask + w * bm) * invN, cn);
      stackGlow = mix(stackGlow, (nGlow + w * bg) * invN, cn);
      stackKeep *= 1.0 - cn;
    }
    // The bubble itself, on top of its neck.
    float ci = stacking * clamp(0.5 - di / edge, 0.0, 1.0);
    stackSurface = mix(stackSurface, bs, ci);
    stackMask = mix(stackMask, bm, ci);
    stackGlow = mix(stackGlow, bg, ci);
    stackKeep *= 1.0 - ci;
    // Remember it for the necks of higher bubbles, unless the pixel is inside it. The inclusion
    // fades in over the edge width (a hard in/out switch made the neck shape jump at every
    // bubble edge, producing spikes).
    float o = clamp(0.5 + di / edge, 0.0, 1.0);
    nDist = mix(nDist, smin(nDist, di, k), o);
    nW += w * o;
    nSurface += w * o * bs;
    nMask += w * o * bm;
    nGlow += w * o * bg;

    // ---- Bubble 2i + 1 ----
    b = uBubblesB[i];
    di = distance(p, b.xy) - b.z;
    d = smin(d, di, k);
    w = weight(di, b.z);
    bs = vec4(unpackRgb(colors.z) * b.w, b.w);
    bm = vec4(unpackRgb(colors.w) * b.w, b.w);
    bg = glowAlpha(p, b);
    wSum += w;
    surface += w * bs;
    mask += w * bm;
    glow += w * bg;
    dn = smin(di, nDist, k);
    cn = stacking * max(
        clamp(0.5 - dn / edge, 0.0, 1.0) - clamp(0.5 - min(di, nDist) / edge, 0.0, 1.0),
        0.0);
    nwi = nW + w;
    if (cn > 0.0 && nwi > 0.0) {
      float invN = 1.0 / nwi;
      stackSurface = mix(stackSurface, (nSurface + w * bs) * invN, cn);
      stackMask = mix(stackMask, (nMask + w * bm) * invN, cn);
      stackGlow = mix(stackGlow, (nGlow + w * bg) * invN, cn);
      stackKeep *= 1.0 - cn;
    }
    ci = stacking * clamp(0.5 - di / edge, 0.0, 1.0);
    stackSurface = mix(stackSurface, bs, ci);
    stackMask = mix(stackMask, bm, ci);
    stackGlow = mix(stackGlow, bg, ci);
    stackKeep *= 1.0 - ci;
    o = clamp(0.5 + di / edge, 0.0, 1.0);
    nDist = mix(nDist, smin(nDist, di, k), o);
    nW += w * o;
    nSurface += w * o * bs;
    nMask += w * o * bm;
    nGlow += w * o * bg;
  }

  // Anti-aliased coverage over the AA width.
  float coverage = clamp(0.5 - d / uParams0.y, 0.0, 1.0);

  vec4 c = vec4(0.0);
  if (coverage > 0.0 && wSum > 0.0) {
    float invW = 1.0 / wSum;
    surface *= invW;
    mask *= invW;
    glow *= invW;

    // Inside bubbles: the stacked (top bubble) values; the stack sums started from 0 and
    // carry total weight `inside`, hence the normalization.
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
