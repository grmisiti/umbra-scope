// Scopes prototype — all shaders written from scratch.
//
// Pipeline per frame:
//   1. decode:    source BGRA8 video texture -> downscaled RGBA16F "frame" texture
//   2. scatter:   one point per frame sample, additive blend into RGBA32F accumulators
//                 (mode 0 = waveform: colour / RGB overlay / luma; 2 = CbCr vectorscope)
//   3. composite: tone-map accumulators (1 - exp(-acc * gain)) + procedural graticule

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------- shared

constant float3 kLuma709 = float3(0.2126, 0.7152, 0.0722);

// Vertical margin in the waveform/parade so 0 and 100% lines are not on the edge.
constant float kWaveMargin = 0.05;

// Rec.709 full-range RGB -> (Cb, Cr) centered at 0, range ±0.5.
static float2 rgb_to_cbcr709(float3 rgb) {
    float y = dot(rgb, kLuma709);
    float cb = (rgb.b - y) / 1.8556;   // 2 * (1 - 0.0722)
    float cr = (rgb.r - y) / 1.5748;   // 2 * (1 - 0.2126)
    return float2(cb, cr);
}

// Scene-linear value from an encoded one, for the stops display (transfer: see StopsTransfer in Renderer.swift).
// Formulas as published by each manufacturer; Rec.709 uses the inverse BT.709 camera curve.
static float to_linear(float y, uint transfer) {
    switch (transfer) {
    case 0:   // Rec.709 (BT.709 OETF)
        return y < 0.081 ? y / 4.5 : pow((y + 0.099) / 1.099, 1.0 / 0.45);
    case 1: { // Canon Log 3 (Canon reflectance x 0.9)
        float x;
        if (y < 0.04076162) x = -(pow(10.0, (0.12783901 - y) / 0.36726845) - 1.0) / 14.98325;
        else if (y <= 0.105357102) x = (y - 0.12512219) / 1.9754798;
        else x = (pow(10.0, (y - 0.12240537) / 0.36726845) - 1.0) / 14.98325;
        return x * 0.9;
    }
    case 2: { // Sony S-Log3
        float c = y * 1023.0;
        return c >= 171.2102946929 ? pow(10.0, (c - 420.0) / 261.5) * 0.19 - 0.01 : (c - 95.0) * 0.01125 / (171.2102946929 - 95.0);
    }
    case 3: { // ARRI LogC3 (EI 800)
        const float cut = 0.010591, a = 5.555556, b = 0.052272, c = 0.247190, d = 0.385537, e = 5.367655, f = 0.092809;
        return y > e * cut + f ? (pow(10.0, (y - d) / c) - b) / a : (y - f) / e;
    }
    case 4: { // Blackmagic Design Film Gen 5
        const float A = 0.08692876065491224, B = 0.005494072432257808, C = 0.5300133392291939, D = 8.283605932402494, E = 0.09246575342465753;
        return y < D * 0.005 + E ? (y - E) / D : exp((y - C) / A) - B;
    }
    case 5: { // DaVinci Intermediate
        const float A = 0.0075, B = 7.0, C = 0.07329248, M = 10.44426855;
        return y <= 0.02740668 ? y / M : pow(2.0, y / C - B) - A;
    }
    default:  // linear
        return y;
    }
}

// Stops display range: -8 .. +6 stops around 18% grey.
constant float kStopsMin = -8.0, kStopsSpan = 14.0;

// Skin tones: CbCr angle within ±15° of the skin line (123° from +Cb), with some chroma and mid luma.
static bool is_skin(float3 rgb) {
    float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float2 c = float2((rgb.b - y) / 1.8556, (rgb.r - y) / 1.5748);
    float ang = atan2(c.y, c.x) * 57.29578;
    return abs(ang - 123.0) < 15.0 && length(c) > 0.015 && y > 0.06 && y < 0.95;
}

static float wave_value_to_ndc(float v) {
    return ((v + kWaveMargin) / (1.0 + 2.0 * kWaveMargin)) * 2.0 - 1.0;
}

// Region of interest, in frame uv (0..1, y down). shape: 0 = none (whole frame), 1 = rectangle, 2 = ellipse.
static bool roi_contains(float2 uv, float4 roi, uint shape) {
    if (shape == 0) return true;
    float2 c = roi.xy + roi.zw * 0.5, half_ = max(roi.zw * 0.5, 1e-6);
    float2 q = (uv - c) / half_;
    return shape == 1 ? all(abs(q) <= 1.0) : dot(q, q) <= 1.0;
}

// Signed distance to the ROI outline in uv units (negative inside); the ellipse one is approximate.
static float roi_distance(float2 uv, float4 roi, uint shape) {
    float2 c = roi.xy + roi.zw * 0.5, half_ = max(roi.zw * 0.5, 1e-6);
    if (shape == 1) {
        float2 d = abs(uv - c) - half_;
        return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
    }
    return (length((uv - c) / half_) - 1.0) * min(half_.x, half_.y);
}

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;           // 0..1, y down
};

// Single oversized triangle covering the viewport.
vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);          // (0,0) (2,0) (0,2)
    FullscreenOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// ---------------------------------------------------------------- 1. decode

struct DecodeUniforms {
    uint swapRB;         // source stores B,G,R
    uint videoRange;     // source is legal range (64-940 of 1023): expand to 0..1
    uint flipY;          // source rows are bottom-up
    uint lutMode;        // bit 0: 1D shaper, bit 1: 3D cube
    float2 shaperRange;  // input range mapped onto the shaper
    float2 cubeRange;    // input range mapped onto the cube
    float shaperSize;
    float cubeSize;
    float2 pad;
};

// Maps v from [range.x, range.y] to texel centres of an n-entry table.
static inline float3 lut_coord(float3 v, float2 range, float n) {
    float3 t = saturate((v - range.x) / (range.y - range.x));
    return t * ((n - 1.0) / n) + 0.5 / n;
}

fragment float4 decode_fragment(FullscreenOut in [[stage_in]],
                                constant DecodeUniforms& u [[buffer(0)]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> shaper [[texture(1)]],
                                texture3d<float> cube [[texture(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = u.flipY ? float2(in.uv.x, 1.0 - in.uv.y) : in.uv;
    // Bilinear downscale; at exactly 2:1 this is a 2x2 box filter.
    float3 rgb = src.sample(s, uv).rgb;
    if (u.swapRB) rgb = rgb.bgr;
    if (u.videoRange) rgb = (rgb - 64.0 / 1023.0) * (1023.0 / 876.0);
    // LUT (Single layout, Source): applied here so every scope reads what the picture shows.
    if (u.lutMode & 1u) {
        float3 c = lut_coord(rgb, u.shaperRange, u.shaperSize);
        rgb = float3(shaper.sample(s, float2(c.r, 0.5)).r, shaper.sample(s, float2(c.g, 0.5)).g,
                     shaper.sample(s, float2(c.b, 0.5)).b);
    }
    if (u.lutMode & 2u) rgb = cube.sample(s, lut_coord(rgb, u.cubeRange, u.cubeSize)).rgb;
    return float4(rgb, 1.0);
}

// ---------------------------------------------------------------- 2. scatter

struct ScatterUniforms {
    uint2 frameSize;
    uint  mode;
    float vecScale;      // CbCr -> NDC
    uint  vecBins;       // logical vectorscope resolution (bins per side)
    uint  vecSpread;     // each bin is spread over vecSpread x vecSpread physical pixels
    uint  waveMode;      // waveform: 0 = colour, 1 = RGB overlay (one instance per channel), 2 = luma
    uint  roiShape;      // see roi_contains
    float4 roi;          // x, y, width, height in frame uv
    float ditherRGB;     // smoothing: size of one code value (1/1023, 1/255) or 0 for off
    float ditherChroma;  // same for Cb/Cr (1/896 for 10-bit, 1/224 for 8-bit)
    float2 lumaRange;    // vectorscope: only samples with luma in [x, y] (HML zones)
    uint  transfer;      // stops display: input curve
    uint  pad1;
    float2 pad2;
};

// Cheap integer hash -> three values in [0, 1).
static float3 hash3(uint n) {
    n = (n ^ 61u) ^ (n >> 16); n *= 9u; n ^= n >> 4; n *= 0x27d4eb2du; n ^= n >> 15;
    uint a = n, b = n * 1664525u + 1013904223u, c = b * 1664525u + 1013904223u;
    return float3(a & 0xffffu, b & 0xffffu, c & 0xffffu) / 65536.0;
}

struct ScatterOut {
    float4 position [[position]];
    float  pointSize [[point_size]];
    float4 color;
};

vertex ScatterOut scatter_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 texture2d<float, access::read> frame [[texture(0)]],
                                 constant ScatterUniforms& u [[buffer(0)]]) {
    uint x = vid % u.frameSize.x;
    uint y = vid / u.frameSize.x;
    float3 rgb = frame.read(uint2(x, y)).rgb;
    // Quantised sources leave empty rows in the waveform and a grid in a zoomed vectorscope. Spread each
    // sample by up to ±half a code value (10- or 8-bit, chosen by the user) so the trace is continuous;
    // the reading moves by less than one code value.
    float3 h = hash3(vid);
    rgb += (h - 0.5) * u.ditherRGB;
    float2 uv = (float2(x, y) + 0.5) / float2(u.frameSize);
    float column = uv.x;
    if (u.roiShape != 0) {
        if (!roi_contains(uv, u.roi, u.roiShape)) {   // outside the selection: drop the point
            ScatterOut o;
            o.position = float4(-2.0, -2.0, 0.0, 1.0);
            o.pointSize = 1.0;
            o.color = float4(0.0);
            return o;
        }
        // The selection's columns fill the waveform's width. A random position inside each source pixel keeps
        // stretched columns from leaving gaps.
        column = saturate(((float(x) + h.z) / float(u.frameSize.x) - u.roi.x) / max(u.roi.z, 1e-6));
    }

    float2 ndc;
    float4 color;

    if (u.mode == 0 && u.waveMode == 0) {    // colour waveform: luma position, the sample's own colour
        float luma = dot(rgb, kLuma709);
        ndc = float2(column * 2.0 - 1.0, wave_value_to_ndc(luma));
        // Normalised to full brightness so dark pixels still show their hue; a little white keeps greys visible.
        float m = max(max(rgb.r, rgb.g), rgb.b);
        float3 hue = m > 1e-4 ? rgb / m : float3(1.0);
        color = float4(mix(hue, float3(1.0), 0.15), 1.0);
    } else if (u.mode == 0 && u.waveMode == 1) {   // RGB overlay waveform: each channel at its own level
        // Pure primaries, so where R, G and B coincide (neutral greys) the sum reads as white.
        float v = rgb[iid];
        ndc = float2(column * 2.0 - 1.0, wave_value_to_ndc(v));
        color = float4(iid == 0 ? 1.0 : 0.0, iid == 1 ? 1.0 : 0.0, iid == 2 ? 1.0 : 0.0, 1.0);
    } else if (u.mode == 0) {                // luma waveform
        float luma = dot(rgb, kLuma709);
        ndc = float2(column * 2.0 - 1.0, wave_value_to_ndc(luma));
        color = float4(1.0);
    } else if (u.mode == 3) {                // stops: x = column, y = exposure in stops around 18% grey
        float3 lin = float3(to_linear(rgb.r, u.transfer), to_linear(rgb.g, u.transfer), to_linear(rgb.b, u.transfer));
        float stops = log2(max(dot(lin, kLuma709), 1e-6) / 0.18);
        ndc = float2(column * 2.0 - 1.0, (stops - kStopsMin) / kStopsSpan * 2.0 - 1.0);
        float m = max(max(rgb.r, rgb.g), rgb.b);
        float3 hue = m > 1e-4 ? rgb / m : float3(1.0);
        color = float4(mix(hue, float3(1.0), 0.4), 1.0);
    } else {                                 // vectorscope, colored by the sample's own hue
        float lumaZone = dot(rgb, kLuma709);
        if (lumaZone < u.lumaRange.x || lumaZone >= u.lumaRange.y) {   // HML: outside this zone
            ScatterOut o;
            o.position = float4(-2.0, -2.0, 0.0, 1.0);
            o.pointSize = 1.0;
            o.color = float4(0.0);
            return o;
        }
        float2 cbcr = rgb_to_cbcr709(rgb);
        // Video stores chroma as Cb/Cr codes (224 steps in 8-bit, 896 in 10-bit), which shows as a dot grid when
        // zoomed: spread by ±half a chroma step too.
        cbcr += (hash3(vid * 7u + 3u).xy - 0.5) * u.ditherChroma;
        float2 logical = cbcr * u.vecScale;
        // Large flat areas send hundreds of thousands of samples to the same CbCr bin, and
        // ordered blending on one pixel serialises. Interleave each bin over K x K physical
        // pixels (picked by vertex_id) so those blends run in parallel; resolve_fragment sums them.
        float2 bin = floor((float2(logical.x, -logical.y) * 0.5 + 0.5) * float(u.vecBins));
        uint k = u.vecSpread;
        float2 sub = float2(vid % k, (vid / k) % k);
        float2 phys = (bin * float(k) + sub + 0.5) / float(u.vecBins * k);
        ndc = float2(phys.x * 2.0 - 1.0, 1.0 - phys.y * 2.0);
        if (any(bin < 0.0) || any(bin >= float(u.vecBins))) ndc = float2(-2.0);   // clip
        float m = max(max(rgb.r, rgb.g), rgb.b);
        float3 hue = m > 1e-4 ? rgb / m : float3(1.0);
        color = float4(mix(float3(1.0), hue, 0.75), 1.0);
    }

    ScatterOut o;
    o.position = float4(ndc, 0.0, 1.0);
    o.pointSize = 1.0;
    o.color = color;
    return o;
}

fragment float4 scatter_fragment(ScatterOut in [[stage_in]]) {
    return in.color;   // blended with ONE + ONE
}

// Sums each K x K block of the spread vectorscope accumulator into one logical bin.
fragment float4 resolve_fragment(FullscreenOut in [[stage_in]],
                                 texture2d<float, access::read> wide [[texture(0)]],
                                 constant uint& spread [[buffer(0)]]) {
    uint2 base = uint2(in.position.xy) * spread;
    float4 sum = 0.0;
    for (uint y = 0; y < spread; ++y)
        for (uint x = 0; x < spread; ++x)
            sum += wide.read(base + uint2(x, y));
    return sum;
}

// ---------------------------------------------------------------- peaks

// Highest and lowest point of the waveform trace: luma (Color/Luma modes) or any channel (RGB mode).
// out[0] = max, out[1] = min, encoded as uint(v * 10000 + 10000) so negative values still order correctly.
// Each SIMD group reduces first, so only one atomic per 32 pixels reaches memory.
struct PeaksArgs {
    uint waveMode;
    uint roiShape;
    uint2 pad;
    float4 roi;
};

kernel void peaks(texture2d<float, access::read> frame [[texture(0)]],
                  device atomic_uint* out [[buffer(0)]],
                  constant PeaksArgs& a [[buffer(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    float hi = -1e9, lo = 1e9;
    uint W = frame.get_width(), H = frame.get_height();
    float2 uv = (float2(gid) + 0.5) / float2(W, H);
    if (gid.x < W && gid.y < H && roi_contains(uv, a.roi, a.roiShape)) {
        float3 rgb = frame.read(gid).rgb;
        if (a.waveMode == 1) {
            hi = max(max(rgb.r, rgb.g), rgb.b);
            lo = min(min(rgb.r, rgb.g), rgb.b);
        } else {
            hi = lo = dot(rgb, kLuma709);
        }
    }
    hi = simd_max(hi);
    lo = simd_min(lo);
    if (simd_is_first()) {
        atomic_fetch_max_explicit(&out[0], uint(clamp(hi, -1.0, 2.0) * 10000.0 + 10000.5), memory_order_relaxed);
        atomic_fetch_min_explicit(&out[1], uint(clamp(lo, -1.0, 2.0) * 10000.0 + 10000.5), memory_order_relaxed);
    }
}

// ---------------------------------------------------------------- waveform envelopes

// Per frame column: the lowest and highest R, G, B and luma (in .a) inside the selection. env[x] holds the minima,
// env[W + x] the maxima; a column with no sample keeps min > max. `hold` keeps the extremes across frames (peak hold)
// and starts over from this frame when `reset` is set.
struct EnvelopeArgs {
    uint roiShape;
    uint reset;
    uint2 pad;
    float4 roi;
};

kernel void wave_envelope(texture2d<float, access::read> frame [[texture(0)]],
                          device float4* env [[buffer(0)]],
                          device float4* hold [[buffer(1)]],
                          constant EnvelopeArgs& a [[buffer(2)]],
                          uint x [[thread_position_in_grid]]) {
    uint W = frame.get_width(), H = frame.get_height();
    if (x >= W) return;
    float4 lo = float4(9.0), hi = float4(-9.0);
    for (uint y = 0; y < H; ++y) {
        float2 uv = (float2(x, y) + 0.5) / float2(W, H);
        if (!roi_contains(uv, a.roi, a.roiShape)) continue;
        float3 rgb = frame.read(uint2(x, y)).rgb;
        float4 v = float4(rgb, dot(rgb, kLuma709));
        lo = min(lo, v);
        hi = max(hi, v);
    }
    env[x] = lo;
    env[W + x] = hi;
    bool empty = lo.a > hi.a;
    if (a.reset != 0) {
        hold[x] = lo;
        hold[W + x] = hi;
    } else if (!empty) {
        hold[x] = min(hold[x], lo);
        hold[W + x] = max(hold[W + x], hi);
    }
}

// Distance in pixels from the curve v == e (both vary across the panel), for 1 px anti-aliased curves.
static float curve_line(float g) {
    float d = abs(g) / max(length(float2(dfdx(g), dfdy(g))), 1e-6);
    return 1.0 - smoothstep(0.5, 1.5, d);
}

// Min/max curves of one channel k (0-2 R, G, B; 3 luma) of an envelope buffer, at panel column fc (in frame columns).
static float envelope_lines(device const float4* e, uint n, float fc, float v, int k) {
    int c0 = clamp(int(floor(fc)), 0, int(n) - 1), c1 = min(c0 + 1, int(n) - 1);
    float f = saturate(fc - float(c0));
    float lo0 = e[c0][k], hi0 = e[n + c0][k], lo1 = e[c1][k], hi1 = e[n + c1][k];
    // An empty column (min > max) borrows its neighbour, so the curve doesn't dive to the sentinel.
    if (lo0 > hi0) { lo0 = lo1; hi0 = hi1; }
    if (lo1 > hi1) { lo1 = lo0; hi1 = hi0; }
    if (lo0 > hi0) return 0.0;
    float lo = mix(lo0, lo1, f), hi = mix(hi0, hi1, f);
    return max(curve_line(v - lo), curve_line(v - hi));
}

// ---------------------------------------------------------------- noise

struct NoiseArgs {
    uint swapRB;
    uint videoRange;
    uint flipY;
    uint roiShape;
    float4 roi;
};

static float3 noise_read(texture2d<float, access::read> src, int2 p, constant NoiseArgs& a) {
    int2 size = int2(src.get_width(), src.get_height());
    float3 rgb = src.read(uint2(clamp(p, int2(0), size - 1))).rgb;
    if (a.swapRB) rgb = rgb.bgr;
    if (a.videoRange) rgb = (rgb - 64.0 / 1023.0) * (1023.0 / 876.0);
    return rgb;
}

// Noise statistics of the received frame (full resolution, before the scopes' downscale), inside the selection.
// Noise is measured on the high-pass residual: pixel minus its 3x3 mean. That cancels smooth gradients and
// shading; for white noise var(residual) = 8/9 var(noise), corrected on the CPU.
// out: [0] count, [1..4] sum of Y, R, G, B, [5..10] sum of squared residuals of Y, Cb, Cr, R, G, B.
kernel void noise_stats(texture2d<float, access::read> src [[texture(0)]],
                        device atomic_float* out [[buffer(0)]],
                        constant NoiseArgs& a [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint W = src.get_width(), H = src.get_height();
    float2 uv = (float2(gid) + 0.5) / float2(W, H);
    if (a.flipY) uv.y = 1.0 - uv.y;
    bool use = gid.x >= 1 && gid.y >= 1 && gid.x + 1 < W && gid.y + 1 < H && roi_contains(uv, a.roi, a.roiShape);

    float v[11];
    for (int i = 0; i < 11; ++i) v[i] = 0.0;
    if (use) {
        int2 p = int2(gid);
        float3 c = noise_read(src, p, a), sum = 0.0;
        for (int dy = -1; dy <= 1; ++dy)
            for (int dx = -1; dx <= 1; ++dx) sum += noise_read(src, p + int2(dx, dy), a);
        float3 r = c - sum / 9.0;                          // high-pass residual, per channel
        float ry = dot(r, kLuma709);
        float2 rc = float2((r.b - ry) / 1.8556, (r.r - ry) / 1.5748);
        v[0] = 1.0;
        v[1] = dot(c, kLuma709); v[2] = c.r; v[3] = c.g; v[4] = c.b;
        v[5] = ry * ry; v[6] = rc.x * rc.x; v[7] = rc.y * rc.y;
        v[8] = r.r * r.r; v[9] = r.g * r.g; v[10] = r.b * r.b;
    }
    // One atomic per SIMD group and value.
    for (int i = 0; i < 11; ++i) {
        float t = simd_sum(v[i]);
        if (simd_is_first() && t != 0.0) atomic_fetch_add_explicit(&out[i], t, memory_order_relaxed);
    }
}

// ---------------------------------------------------------------- readout

struct MeanArgs {
    uint roiShape;
    uint3 pad;
    float4 roi;
};

// Sum of R, G, B and the sample count inside the selection or probe rectangle (decoded frame).
kernel void area_mean(texture2d<float, access::read> frame [[texture(0)]],
                      device atomic_float* out [[buffer(0)]],
                      constant MeanArgs& a [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    uint W = frame.get_width(), H = frame.get_height();
    float2 uv = (float2(gid) + 0.5) / float2(W, H);
    float4 v = 0.0;
    if (gid.x < W && gid.y < H && roi_contains(uv, a.roi, a.roiShape)) v = float4(frame.read(gid).rgb, 1.0);
    v = float4(simd_sum(v.x), simd_sum(v.y), simd_sum(v.z), simd_sum(v.w));
    if (simd_is_first() && v.w > 0.0) {
        for (int i = 0; i < 4; ++i) atomic_fetch_add_explicit(&out[i], v[i], memory_order_relaxed);
    }
}

// ---------------------------------------------------------------- false colour

// Exposure zones on Rec.709 luma (percent of full scale). Everything between the coloured bands stays grey.
static float3 false_color(float v, float3 grey) {
    if (v < 0.025) return float3(0.55, 0.0, 0.85);    // crushed blacks
    if (v < 0.10)  return float3(0.10, 0.35, 1.0);    // near black
    if (v >= 0.38 && v < 0.43) return float3(0.15, 0.80, 0.25);   // 18% grey (middle grey)
    if (v >= 0.52 && v < 0.60) return float3(0.95, 0.50, 0.70);   // skin, one stop over middle grey
    if (v >= 0.98) return float3(1.0, 0.10, 0.10);    // clipping
    if (v >= 0.93) return float3(1.0, 0.90, 0.10);    // near clipping
    return grey;
}

// ---------------------------------------------------------------- 3. composite

struct PanelUniforms {
    uint  kind;          // 0 video, 1 waveform, 3 vectorscope, 4 false colour picture, 5 false colour legend, 6 card
    float gain;
    float vecScale;      // includes the vectorscope zoom
    uint  waveMode;      // 0 colour, 1 RGB overlay, 2 luma (only luma gets the phosphor tint)
    float peakMax;       // waveform peak lines (signal value); below -0.5 = not drawn
    float peakMin;
    uint  roiShape;      // picture panel: selection outline, outside dimmed
    uint  noiseView;     // picture panel: 0 picture, 1 luma noise, 2 chroma noise (high-pass x10 on grey)
    float4 roi;
    float2 size;         // card: size in pixels
    float radius;        // card: corner radius in pixels
    uint  skin;          // picture: keep only skin tones in colour
    float wipe;          // picture: x (0..1) where the Reference (texture 1) starts; < 0 = off
    uint  envFlags;      // waveform: 1 = min/max envelope of this frame, 2 = peak hold
    uint  envColumns;    // waveform: frame columns in the envelope buffers (roi.x/.z map the panel onto them)
    float envPad;
    uint  markKind;      // picture: 1 waveform mark, 2 vectorscope mark to highlight; scopes: outline to draw
    uint  markRGB;       // waveform mark in RGB mode: any channel in range matches
    uint  targetCount;   // waveform / vectorscope / stops: pinned targets in buffer 3 (rgb, stops)
    float vecSignal;     // vectorscope: signal gain (2 = Show 2x Zoom); the graticule keeps its scale
    float4 mark;         // picture: x0, x1, lo, hi (waveform) or cb0, cb1, cr0, cr1; scopes: panel uv x0, x1, y0, y1
};

// Whether a picture sample falls inside a region marked on a scope (see PanelUniforms.mark).
static bool in_scope_mark(float3 rgb, float frameX, constant PanelUniforms& u) {
    float4 m = u.mark;
    if (u.markKind == 1) {
        if (frameX < m.x || frameX > m.y) return false;
        if (u.markRGB != 0) {
            return any(rgb >= m.z && rgb <= m.w);
        }
        float y = dot(rgb, kLuma709);
        return y >= m.z && y <= m.w;
    }
    float2 cbcr = rgb_to_cbcr709(rgb);
    return cbcr.x >= m.x && cbcr.x <= m.y && cbcr.y >= m.z && cbcr.y <= m.w;
}

static float aa_line(float f, float target);   // defined with the graticules below

// Pinned targets (T1…T4): one colour each, matching the labels drawn by the app.
constant float3 kTargetColors[4] = {float3(0.541, 0.169, 0.886), float3(0.486, 0.949, 0.690),
                                    float3(1.0, 0.78, 0.35), float3(1.0, 0.55, 0.75)};

// Measured points on a scope panel, two float4 each (rgb + stops; pair, isReference). Colour = pair; Source points
// solid, Reference points dashed. Waveform: level lines (luma, or R, G and B in RGB mode). Vectorscope: Source a ring
// with a centre dot, Reference a dashed ring. Stops: a line at the exposure.
static float3 draw_targets(float3 c, float2 uv, float2 pixel, constant PanelUniforms& u, constant float4* t) {
    float dashX = step(0.45, fract(pixel.x / 10.0));
    for (uint i = 0; i < min(u.targetCount, 8u); ++i) {
        float4 tg = t[i * 2];
        float4 meta = t[i * 2 + 1];
        float3 col = kTargetColors[uint(meta.x) % 4u];
        bool ref = meta.y > 0.5;
        float style = ref ? dashX : 1.0;
        if (u.kind == 1) {
            float v = (1.0 - uv.y) * (1.0 + 2.0 * kWaveMargin) - kWaveMargin;
            float l = 0.0;
            if (u.waveMode == 1) { for (int k = 0; k < 3; ++k) l = max(l, aa_line(v, tg[k])); }
            else l = aa_line(v, dot(tg.rgb, kLuma709));
            c = mix(c, col, l * style * 0.95);
        } else if (u.kind == 3) {
            float2 cbcr = rgb_to_cbcr709(tg.rgb);
            float sc = u.vecScale * u.vecSignal;
            float2 tuv = float2((cbcr.x * sc + 1.0) * 0.5, (1.0 - cbcr.y * sc) * 0.5);
            float2 p = (uv - tuv) / max(fwidth(uv), float2(1e-6));      // offset in pixels
            float r = length(p);
            float ring = 1.0 - smoothstep(0.6, 1.6, abs(r - 7.0));
            if (ref) ring *= step(0.5, fract(atan2(p.y, p.x) / 6.2831853 * 8.0));   // 8 dashes around
            float centre = ref ? 0.0 : 1.0 - smoothstep(1.5, 2.5, r);
            c = mix(c, col, max(ring, centre));
        } else if (u.kind == 7) {
            float v = (1.0 - uv.y) * kStopsSpan + kStopsMin;
            c = mix(c, col, aa_line(v, tg.w) * style * 0.95);
        }
    }
    return c;
}

// Outline (and a faint fill) of a mark drawn on a scope panel, from its panel-uv rectangle.
static float3 draw_mark_outline(float3 c, float2 uv, constant PanelUniforms& u) {
    float4 r = u.mark;
    float2 lo = float2(min(r.x, r.y), min(r.z, r.w)), hi = float2(max(r.x, r.y), max(r.z, r.w));
    float2 centre = (lo + hi) * 0.5, half_ = (hi - lo) * 0.5;
    float2 q = abs(uv - centre) - half_;
    float d = max(q.x, q.y);                                         // < 0 inside the rectangle
    float edge = 1.0 - smoothstep(0.5, 1.5, abs(d) / max(fwidth(d), 1e-6));
    if (d < 0.0) c = mix(c, float3(0.541, 0.169, 0.886), 0.08);
    return mix(c, float3(0.541, 0.169, 0.886), edge);
}

// Umbra Scope "Phantom" palette.
constant float3 kInk = float3(0.145, 0.141, 0.125);      // #252420 window (Umbra carvão)
constant float3 kPanel = float3(0.188, 0.184, 0.169);    // #302F2B cards
constant float3 kHairline = float3(1.0);                 // drawn at 7% over the card
constant float3 kGraticule = float3(0.62, 0.61, 0.70);
constant float3 kPurple = float3(0.541, 0.169, 0.886);      // #8A2BE2 Roxo Umbra (brand book)

// Anti-aliased line at f == target, ~1px wide regardless of panel size.
static float aa_line(float f, float target) {
    float d = abs(f - target) / max(fwidth(f), 1e-6);
    return 1.0 - smoothstep(0.5, 1.5, d);
}

static float wave_graticule(float2 uv) {
    // uv.y is top-down; convert back to signal value.
    float v = (1.0 - uv.y) * (1.0 + 2.0 * kWaveMargin) - kWaveMargin;
    float g = 0.0;
    for (int i = 0; i <= 10; ++i) {
        float w = (i == 0 || i == 10) ? 0.55 : (i == 5 ? 0.3 : 0.16);
        g = max(g, aa_line(v, float(i) * 0.1) * w);
    }
    return g;
}

static float box_outline(float2 p, float2 c, float halfSize) {
    float d = max(abs(p.x - c.x), abs(p.y - c.y));
    return aa_line(d, halfSize);
}

// Colour of the hue at the direction of cbcr, at full brightness (for the ring around the vectorscope).
static float3 hue_at(float2 cbcr) {
    float2 d = normalize(cbcr) * 0.3;
    float3 rgb = float3(0.5 + 1.5748 * d.y,
                        0.5 - 0.1873 * d.x - 0.4681 * d.y,
                        0.5 + 1.8556 * d.x);
    float lo = min(min(rgb.r, rgb.g), rgb.b), hi = max(max(rgb.r, rgb.g), rgb.b);
    return (rgb - lo) / max(hi - lo, 1e-4);
}

static float vector_graticule(float2 cbcr) {
    float r = length(cbcr);
    float g = 0.0;
    g = max(g, aa_line(r, 0.25) * 0.15);
    // Axes (faint, inside the circle).
    if (r < 0.5) {
        g = max(g, aa_line(cbcr.x, 0.0) * 0.12);
        g = max(g, aa_line(cbcr.y, 0.0) * 0.12);
    }
    // Skin-tone line (~123° from +Cb).
    float a = 123.0 * M_PI_F / 180.0;
    float2 dir = float2(cos(a), sin(a));
    float along = dot(cbcr, dir);
    float across = cbcr.x * dir.y - cbcr.y * dir.x;
    if (along > 0.0 && r < 0.5) g = max(g, aa_line(across, 0.0) * 0.35);
    // 75% colour-bar targets.
    const float3 bars[6] = { float3(1,0,0), float3(1,1,0), float3(0,1,0),
                             float3(0,1,1), float3(0,0,1), float3(1,0,1) };
    for (int i = 0; i < 6; ++i) {
        float2 t = rgb_to_cbcr709(bars[i] * 0.75);
        g = max(g, box_outline(cbcr, t, 0.018) * 0.6);
    }
    return g;
}

fragment float4 composite_fragment(FullscreenOut in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]],
                                   texture2d<float> ref [[texture(1)]],
                                   constant PanelUniforms& u [[buffer(0)]],
                                   device const float4* env [[buffer(1)]],
                                   device const float4* hold [[buffer(2)]],
                                   constant float4* targets [[buffer(3)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 bg = kPanel;
    float3 gratColor = kGraticule;

    if (u.kind == 6) {
        // Card: rounded rectangle with a 1 px hairline; outside the corners it is the window ink.
        float2 p = in.uv * u.size - u.size * 0.5;
        float2 q = abs(p) - (u.size * 0.5 - u.radius - 0.5);
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - u.radius;   // signed distance, px
        float inside = 1.0 - smoothstep(-0.5, 0.5, d);
        float edge = 1.0 - smoothstep(0.0, 1.0, abs(d + 0.5));
        float3 c = mix(kInk, kPanel, inside);
        return float4(mix(c, kHairline, edge * 0.07), 1.0);
    }

    if (u.kind == 0) {
        // Wipe: right of the line shows the Reference picture.
        bool showRef = u.wipe >= 0.0 && in.uv.x >= u.wipe;
        float3 c = showRef ? ref.sample(s, in.uv).rgb : tex.sample(s, in.uv).rgb;
        if (u.skin != 0 && !is_skin(c)) c = float3(dot(c, kLuma709) * 0.35);
        if (u.noiseView != 0) {
            // Residual against the 3x3 neighbourhood, amplified: flat areas show only their noise.
            float2 texel = 1.0 / float2(tex.get_width(), tex.get_height());
            float3 sum = 0.0;
            for (int dy = -1; dy <= 1; ++dy)
                for (int dx = -1; dx <= 1; ++dx) sum += tex.sample(s, in.uv + float2(dx, dy) * texel).rgb;
            float3 r = (c - sum / 9.0) * 10.0;
            float ry = dot(r, kLuma709);
            if (u.noiseView == 1) {
                c = float3(saturate(0.5 + ry));
            } else {
                float2 rc = float2((r.b - ry) / 1.8556, (r.r - ry) / 1.5748);
                c = saturate(float3(0.5 + 1.5748 * rc.y, 0.5 - 0.1873 * rc.x - 0.4681 * rc.y, 0.5 + 1.8556 * rc.x));
            }
        }
        if (u.markKind != 0 && !showRef) {
            // Scope mark: pixels whose values fall in the marked region keep their colour (lifted a little towards
            // purple); the rest of the picture goes dark grey.
            float3 sample = tex.sample(s, in.uv).rgb;
            if (in_scope_mark(sample, in.uv.x, u)) c = mix(c, kPurple, 0.18);
            else c = float3(dot(c, kLuma709) * 0.22);
        }
        if (u.roiShape != 0) {
            float d = roi_distance(in.uv, u.roi, u.roiShape);
            if (d > 0.0) c *= 0.35;                                   // dim outside the selection
            float edge = 1.0 - smoothstep(0.75, 1.75, abs(d) / max(fwidth(d), 1e-6));
            c = mix(c, kPurple, edge);
        }
        if (u.wipe >= 0.0) c = mix(c, kPurple, aa_line(in.uv.x, u.wipe));
        return float4(c, 1.0);
    }
    if (u.kind == 4) {
        float luma = dot(tex.sample(s, in.uv).rgb, kLuma709);
        return float4(false_color(luma, float3(saturate(luma) * 0.75)), 1.0);
    }
    if (u.kind == 5) {
        float v = 1.0 - in.uv.y;   // legend: 100% at the top
        float3 c = false_color(v, float3(v * 0.75));
        float tick = 0.0;
        for (int i = 1; i < 10; ++i) tick = max(tick, aa_line(v, float(i) * 0.1));
        return float4(mix(c, float3(0.0), tick * 0.6), 1.0);
    }

    // Accumulators were rendered with y up in NDC == texture row 0 at the top,
    // so uv maps directly.
    float3 acc = tex.sample(s, in.uv).rgb;
    float3 trace = 1.0 - exp(-acc * u.gain);

    float g;
    if (u.kind == 3) {
        float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
        float2 cbcr = ndc / u.vecScale;
        g = vector_graticule(cbcr);
        // Hue ring at 100% saturation, ~2.5 px wide whatever the zoom.
        float r = length(cbcr);
        float ring = 1.0 - smoothstep(1.0, 2.0, abs(r - 0.5) / max(fwidth(r), 1e-6));
        float3 c = bg + trace;
        c = mix(c, gratColor, g * (1.0 - 0.6 * saturate(max(trace.r, max(trace.g, trace.b)))));
        c = mix(c, hue_at(cbcr), ring);
        if (u.markKind == 2) c = draw_mark_outline(c, in.uv, u);
        if (u.targetCount > 0) c = draw_targets(c, in.uv, in.position.xy, u, targets);
        return float4(c, 1.0);
    } else {
        if (u.kind == 7) {
            // One line per stop; 18% grey (0) brighter.
            float v = (1.0 - in.uv.y) * kStopsSpan + kStopsMin;
            g = 0.0;
            for (int i = -8; i <= 6; ++i) g = max(g, aa_line(v, float(i)) * (i == 0 ? 0.6 : 0.16));
        } else {
            g = wave_graticule(in.uv);
        }
        if (u.waveMode == 2) trace *= float3(0.75, 1.0, 0.8);  // slight green phosphor tint for luma
    }

    float3 c = bg + trace;
    c = mix(c, gratColor, g * (1.0 - 0.6 * saturate(max(trace.r, max(trace.g, trace.b)))));
    if (u.kind == 1 && u.envFlags != 0 && u.envColumns > 1) {
        float v = (1.0 - in.uv.y) * (1.0 + 2.0 * kWaveMargin) - kWaveMargin;
        // Panel x -> frame column (the selection's columns fill the panel, as in the scatter).
        float fc = (u.roi.x + in.uv.x * u.roi.z) * float(u.envColumns) - 0.5;
        bool rgb = u.waveMode == 1;
        const float3 chan[3] = {float3(1.0, 0.42, 0.42), float3(0.45, 1.0, 0.55), float3(0.5, 0.65, 1.0)};
        if (u.envFlags & 2u) {
            // Peak hold: dashed amber, so it reads apart from this frame's envelope and the purple peak values.
            float dash = step(0.5, fract(in.position.x / 8.0));
            float l = 0.0;
            if (rgb) { for (int k = 0; k < 3; ++k) l = max(l, envelope_lines(hold, u.envColumns, fc, v, k)); }
            else l = envelope_lines(hold, u.envColumns, fc, v, 3);
            c = mix(c, float3(1.0, 0.78, 0.35), l * dash * 0.9);
        }
        if (u.envFlags & 1u) {
            if (rgb) {
                for (int k = 0; k < 3; ++k) c = mix(c, chan[k], envelope_lines(env, u.envColumns, fc, v, k) * 0.85);
            } else {
                c = mix(c, float3(0.92, 0.92, 0.96), envelope_lines(env, u.envColumns, fc, v, 3) * 0.8);
            }
        }
    }
    if (u.kind == 1 && u.peakMax > -0.5) {
        float v = (1.0 - in.uv.y) * (1.0 + 2.0 * kWaveMargin) - kWaveMargin;
        float peak = max(aa_line(v, u.peakMax), aa_line(v, u.peakMin));
        c = mix(c, kPurple, peak * 0.9);
    }
    if (u.kind == 1 && u.markKind == 1) c = draw_mark_outline(c, in.uv, u);
    if ((u.kind == 1 || u.kind == 7) && u.targetCount > 0) c = draw_targets(c, in.uv, in.position.xy, u, targets);
    return float4(c, 1.0);
}
