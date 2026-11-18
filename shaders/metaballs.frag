#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// Capacities: 2 * kMaxEventPairs events and 4 * kMaxSpotGroups spots per draw.
// Must match _kSdfMaxEvents / _kSdfMaxSpots in metaballs.dart.
// Uniform budget: 2 + 40 * 3 + 32 * 3 = 218 vec4.
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
uniform vec4 uParams1;                  // 4-7: stacking strength, edge width (logical px), event pair count, group count
uniform vec4 uEventsA[kMaxEventPairs];  // 8-167: event 2i: x, y, radius, w
uniform vec4 uEventsB[kMaxEventPairs];  // 168-327: event 2i+1, same layout
uniform vec4 uEventsC[kMaxEventPairs];  // 328-487: packed rgb: surface 2i, mask 2i,
                                        // surface 2i+1, mask 2i+1
uniform vec4 uSpotsA[kMaxSpotGroups];   // 488-615: spots 4i..4i+3 as 4 x (x, y, radius),
uniform vec4 uSpotsB[kMaxSpotGroups];   // 616-743: spread over A, B, C
uniform vec4 uSpotsC[kMaxSpotGroups];   // 744-871

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

// Packed rgb with opacity o, premultiplied.
vec4 premulRgb(float packedRgb, float o) {
  return vec4(unpackRgb(packedRgb) * o, o);
}

// Color weight of a bubble at signed distance di: grows towards the inside (up to the depth
// clamp) and fades to exactly 0 at distance k.
float weight(float di) {
  float e = -max(di, -uParams0.w) * uParams0.z;
  return exp(clamp(e, -80.0, 80.0)) *
      (1.0 - smoothstep(0.5 * uParams0.x, uParams0.x, di));
}

// Inner glow alpha: white radial gradient centered at center - 0.2r with radius 0.8r.
float glowAlpha(vec2 p, vec4 b) {
  vec2 glowCenter = b.xy - vec2(b.z * 0.2);
  float t = clamp(distance(p, glowCenter) / max(b.z * 0.8, 0.001), 0.0, 1.0);
  return 0.3 * b.w * (1.0 - t);
}

// Mask spot: radial gradient [maskColor, transparent] with stops 0.05 and 1 (solid up to 5% of
// the radius, then a linear fade). Returns the remaining transparency factor for mask
// opacity o. Must match the culling estimate in metaballs.dart (_spotAlphaAt).
float spotKeep(vec2 p, vec3 s, float o) {
  float t = clamp((distance(p, s.xy) / s.z - 0.05) / 0.95, 0.0, 1.0);
  return 1.0 - clamp(o * (1.0 - t), 0.0, 1.0);
}

// Applies one event `ev` with packed colors `ec` (see the layout above).
//
// d, wSum, surface, mask, glow: union distance (smooth min) and proximity-weighted sums.
// stack*: stacking (see main()).
// dl, lw, ls, lm, lg: the current lower bubble's signed distance, weight, premultiplied
// surface and mask, and glow alpha.
void applyEvent(
    vec2 p, vec4 ev, vec2 ec, float k, float stacking, float edge,
    inout float d, inout float wSum, inout vec4 surface, inout vec4 mask, inout float glow,
    inout vec4 stackSurface, inout vec4 stackMask, inout float stackGlow,
    inout float stackKeep,
    inout float dl, inout float lw, inout vec4 ls, inout vec4 lm, inout float lg) {
  float de = distance(p, ev.xy) - ev.z;
  if (ev.w < 1.5) {
    // A bubble: it becomes the current lower bubble; drawn unless flagged (-1 - o -> o).
    float o = abs(ev.w + 0.5) - 0.5;
    dl = de;
    lw = weight(de);
    ls = premulRgb(ec.x, o);
    lm = premulRgb(ec.y, o);
    lg = glowAlpha(p, vec4(ev.xyz, o));
    if (ev.w >= 0.0) {
      d = smin(d, de, k);
      wSum += lw;
      surface += lw * ls;
      mask += lw * lm;
      glow += lw * lg;
      float ci = stacking * clamp(0.5 - de / edge, 0.0, 1.0);
      stackSurface = mix(stackSurface, ls, ci);
      stackMask = mix(stackMask, lm, ci);
      stackGlow = mix(stackGlow, lg, ci);
      stackKeep *= 1.0 - ci;
    }
  } else {
    // Neck between the current lower bubble and this one: only the coverage their smooth
    // union adds to the two shapes (0 inside either bubble and wherever they don't fuse),
    // colored by the pair's weighted blend.
    float cn = stacking * max(
        clamp(0.5 - smin(dl, de, k) / edge, 0.0, 1.0) -
            clamp(0.5 - min(dl, de) / edge, 0.0, 1.0),
        0.0);
    if (cn > 0.0) {
      float o = ev.w - 2.0;
      float wu = weight(de);
      float wn = lw + wu;
      if (wn > 0.0) {
        float invN = 1.0 / wn;
        vec4 ns = (lw * ls + wu * premulRgb(ec.x, o)) * invN;
        vec4 nm = (lw * lm + wu * premulRgb(ec.y, o)) * invN;
        float ng = (lw * lg + wu * glowAlpha(p, vec4(ev.xyz, o))) * invN;
        stackSurface = mix(stackSurface, ns, cn);
        stackMask = mix(stackMask, nm, cn);
        stackGlow = mix(stackGlow, ng, cn);
        stackKeep *= 1.0 - cn;
      }
    }
  }
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
  float stacking = uParams1.x;
  // Transition width across the top bubble's edge: max(edge fade, AA width).
  float edge = uParams1.y;
  vec4 stackSurface = vec4(0.0);
  vec4 stackMask = vec4(0.0);
  float stackGlow = 0.0;
  float stackKeep = 1.0;

  // Current lower bubble: signed distance, weight, premultiplied surface and mask, glow.
  float dl = 100000.0;
  float lw = 0.0;
  vec4 ls = vec4(0.0);
  vec4 lm = vec4(0.0);
  float lg = 0.0;

  int eventPairs = int(uParams1.z);
  for (int i = 0; i < kMaxEventPairs; i++) {
    if (i >= eventPairs) break;
    vec4 colors = uEventsC[i];
    applyEvent(
        p, uEventsA[i], colors.xy, k, stacking, edge,
        d, wSum, surface, mask, glow,
        stackSurface, stackMask, stackGlow, stackKeep,
        dl, lw, ls, lm, lg);
    applyEvent(
        p, uEventsB[i], colors.zw, k, stacking, edge,
        d, wSum, surface, mask, glow,
        stackSurface, stackMask, stackGlow, stackKeep,
        dl, lw, ls, lm, lg);
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
