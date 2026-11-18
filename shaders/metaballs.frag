#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// Capacities: 2 * kMaxEventPairs events and 4 * kMaxSpotGroups spots per draw.
// Must match _kSdfMaxEvents / _kSdfMaxSpots in metaballs.dart.
// Uniform budget: 4 + 40 * 3 + 32 * 3 = 220 vec4.
const int kMaxEventPairs = 40;
const int kMaxSpotGroups = 32;

// Float indices are listed for setFloat() in metaballs.dart. Every array is indexed by the
// loop counter only; events go in pairs and spots in groups of 4 (unused slots are padded with
// dummies that contribute nothing).
//
// Events are listed bottom to top (layer order); each is one bubble (center x, center y,
// radius, w) whose kind is encoded in w with its opacity o:
// - w = o: draw the bubble; it becomes the current lower bubble;
// - w = -1 - o: don't draw it (it isn't in the tile), it only becomes the current lower bubble;
// - w = 2 + o: stack the neck between the current lower bubble and this one.
// A bubble's necks to higher bubbles follow right after it, so they lie above it and under
// every bubble with a higher index.
uniform vec4 uParams0;                  // 0-3: k, AA width (logical px), color sharpness, depth clamp
uniform vec4 uParams1;                  // 4-7: size bias, reference radius, event pair count, group count
uniform vec4 uEventsA[kMaxEventPairs];  // 8-167: event 2i: x, y, radius, w
uniform vec4 uEventsB[kMaxEventPairs];  // 168-327: event 2i+1, same layout
uniform vec4 uEventsC[kMaxEventPairs];  // 328-487: packed rgb: surface 2i, mask 2i,
                                        // surface 2i+1, mask 2i+1
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

  // Current lower bubble (opacity decoded), its signed distance and packed colors.
  vec4 lb = vec4(-100000.0, -100000.0, 0.0, 0.0);
  float dl = 100000.0;
  vec2 lc = vec2(0.0);

  int eventPairs = int(uParams1.z);
  for (int i = 0; i < kMaxEventPairs; i++) {
    if (i >= eventPairs) break;
    vec4 colors = uEventsC[i];

    // ---- Event 2i (same code as event 2i + 1 below) ----
    vec4 ev = uEventsA[i];
    vec2 ec = colors.xy;
    float de = distance(p, ev.xy) - ev.z;
    if (ev.w < 1.5) {
      // A bubble: it becomes the current lower bubble; drawn unless flagged (-1 - o -> o).
      lb = vec4(ev.xyz, abs(ev.w + 0.5) - 0.5);
      dl = de;
      lc = ec;
      if (ev.w >= 0.0) {
        d = smin(d, dl, k);
        float w = weight(dl, lb.z);
        vec4 bs = vec4(unpackRgb(lc.x) * lb.w, lb.w);
        vec4 bm = vec4(unpackRgb(lc.y) * lb.w, lb.w);
        float bg = glowAlpha(p, lb);
        wSum += w;
        surface += w * bs;
        mask += w * bm;
        glow += w * bg;
        float ci = stacking * clamp(0.5 - dl / edge, 0.0, 1.0);
        stackSurface = mix(stackSurface, bs, ci);
        stackMask = mix(stackMask, bm, ci);
        stackGlow = mix(stackGlow, bg, ci);
        stackKeep *= 1.0 - ci;
      }
    } else {
      // Neck between the current lower bubble and this one: only the coverage their smooth
      // union adds to the two shapes (0 inside either bubble and wherever they don't fuse),
      // colored by the pair's weighted blend.
      vec4 ub = vec4(ev.xyz, ev.w - 2.0);
      float cn = stacking * max(
          clamp(0.5 - smin(dl, de, k) / edge, 0.0, 1.0) -
              clamp(0.5 - min(dl, de) / edge, 0.0, 1.0),
          0.0);
      if (cn > 0.0) {
        float wl = weight(dl, lb.z);
        float wu = weight(de, ub.z);
        float wn = wl + wu;
        if (wn > 0.0) {
          float invN = 1.0 / wn;
          vec4 ns = (wl * vec4(unpackRgb(lc.x) * lb.w, lb.w) +
              wu * vec4(unpackRgb(ec.x) * ub.w, ub.w)) * invN;
          vec4 nm = (wl * vec4(unpackRgb(lc.y) * lb.w, lb.w) +
              wu * vec4(unpackRgb(ec.y) * ub.w, ub.w)) * invN;
          float ng = (wl * glowAlpha(p, lb) + wu * glowAlpha(p, ub)) * invN;
          stackSurface = mix(stackSurface, ns, cn);
          stackMask = mix(stackMask, nm, cn);
          stackGlow = mix(stackGlow, ng, cn);
          stackKeep *= 1.0 - cn;
        }
      }
    }

    // ---- Event 2i + 1 ----
    ev = uEventsB[i];
    ec = colors.zw;
    de = distance(p, ev.xy) - ev.z;
    if (ev.w < 1.5) {
      lb = vec4(ev.xyz, abs(ev.w + 0.5) - 0.5);
      dl = de;
      lc = ec;
      if (ev.w >= 0.0) {
        d = smin(d, dl, k);
        float w = weight(dl, lb.z);
        vec4 bs = vec4(unpackRgb(lc.x) * lb.w, lb.w);
        vec4 bm = vec4(unpackRgb(lc.y) * lb.w, lb.w);
        float bg = glowAlpha(p, lb);
        wSum += w;
        surface += w * bs;
        mask += w * bm;
        glow += w * bg;
        float ci = stacking * clamp(0.5 - dl / edge, 0.0, 1.0);
        stackSurface = mix(stackSurface, bs, ci);
        stackMask = mix(stackMask, bm, ci);
        stackGlow = mix(stackGlow, bg, ci);
        stackKeep *= 1.0 - ci;
      }
    } else {
      vec4 ub = vec4(ev.xyz, ev.w - 2.0);
      float cn = stacking * max(
          clamp(0.5 - smin(dl, de, k) / edge, 0.0, 1.0) -
              clamp(0.5 - min(dl, de) / edge, 0.0, 1.0),
          0.0);
      if (cn > 0.0) {
        float wl = weight(dl, lb.z);
        float wu = weight(de, ub.z);
        float wn = wl + wu;
        if (wn > 0.0) {
          float invN = 1.0 / wn;
          vec4 ns = (wl * vec4(unpackRgb(lc.x) * lb.w, lb.w) +
              wu * vec4(unpackRgb(ec.x) * ub.w, ub.w)) * invN;
          vec4 nm = (wl * vec4(unpackRgb(lc.y) * lb.w, lb.w) +
              wu * vec4(unpackRgb(ec.y) * ub.w, ub.w)) * invN;
          float ng = (wl * glowAlpha(p, lb) + wu * glowAlpha(p, ub)) * invN;
          stackSurface = mix(stackSurface, ns, cn);
          stackMask = mix(stackMask, nm, cn);
          stackGlow = mix(stackGlow, ng, cn);
          stackKeep *= 1.0 - cn;
        }
      }
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
