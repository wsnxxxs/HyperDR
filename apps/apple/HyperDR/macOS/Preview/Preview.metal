#include <metal_stdlib>
using namespace metal;

// Pass 1 reconstructs extended-range pixels from the engine's native float
// planes, with no intermediate copy: the buffers are the frame's own page
// aligned storage (see `PreviewFrame.metalBuffers`). The maths below is the
// Web editor's `sampleHdr` in `preview/packet.js`; the shader test checks it
// against a frozen JavaScript reference.
struct ReconstructParams {
    uint width, height;
    uint baseRowBytes;
    uint gainWidth, gainHeight, gainRowBytes, gainChannels;
    uint original;
    float gainMin, gainMax, inverseGamma, gainWeight, baseOffset, alternateOffset;
};

// The decoded ISO log gain must survive even when the full rendition clips
// to black. Shared by legacy reconstruction and the composition cache.
float sampleLogGain(uint2 xy, device const float* gain, constant ReconstructParams& p) {
    // v2: one monochrome gain plane, bilinearly resampled and decoded.
    const float2 size = float2(p.gainWidth, p.gainHeight);
    const float2 g = clamp((float2(xy) + 0.5) * size / float2(p.width, p.height) - 0.5,
                           float2(0), size - 1);
    const uint2 lo = uint2(floor(g));
    const uint2 hi = min(lo + 1, uint2(p.gainWidth - 1, p.gainHeight - 1));
    const float2 w = fract(g);
    const uint stride = p.gainRowBytes / 4;
    const float code = clamp(mix(mix(gain[lo.y * stride + lo.x], gain[lo.y * stride + hi.x], w.x),
                                 mix(gain[hi.y * stride + lo.x], gain[hi.y * stride + hi.x], w.x), w.y),
                             0.0, 1.0);
    return p.gainMin + (p.gainMax - p.gainMin) * pow(code, p.inverseGamma);
}

float3 reconstructPixel(uint2 xy, device const float* base, device const float* gain,
                        constant ReconstructParams& p) {
    const uint baseIndex = xy.y * (p.baseRowBytes / 4) + xy.x * 3;
    const float3 sdr = float3(base[baseIndex], base[baseIndex + 1], base[baseIndex + 2]);
    if (p.original != 0) return sdr;
    if (p.gainChannels != 1) {
        // v1: the gain plane is a full-size HDR image, already reconstructed.
        const uint index = xy.y * (p.gainRowBytes / 4) + xy.x * 3;
        return float3(gain[index], gain[index + 1], gain[index + 2]);
    }
    return max(float3(0.0), (sdr + p.baseOffset) * exp2(sampleLogGain(xy, gain, p) * p.gainWeight)
                            - p.alternateOffset);
}

// Production intermediate: rgba16Float, one texel per source pixel.
kernel void reconstructFrame(device const float* base [[buffer(0)]],
                             device const float* gain [[buffer(1)]],
                             constant ReconstructParams& p [[buffer(2)]],
                             texture2d<float, access::write> out [[texture(0)]],
                             uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= p.width || xy.y >= p.height) return;
    out.write(float4(reconstructPixel(xy, base, gain, p), 1.0), xy);
}

// Same kernel, readable float target: the shader test compares pass 1 against
// the frozen Web reference without half-float quantisation.
kernel void reconstructFrame32(device const float* base [[buffer(0)]],
                               device const float* gain [[buffer(1)]],
                               constant ReconstructParams& p [[buffer(2)]],
                               texture2d<float, access::write> out [[texture(0)]],
                               uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= p.width || xy.y >= p.height) return;
    out.write(float4(reconstructPixel(xy, base, gain, p), 1.0), xy);
}

// Pass 2 draws the intermediate texture into the drawable. The photo rect is
// computed on the CPU by CanvasTransform and passed in normalised device
// coordinates; everything outside it stays transparent.
struct DisplayParams {
    float4 rect;  // minX, minY, maxX, maxY in NDC
};

struct DisplayVertex {
    float4 position [[position]];
    float2 uv;
};

vertex DisplayVertex previewDisplayVertex(uint index [[vertex_id]],
                                         constant DisplayParams& p [[buffer(0)]]) {
    const float2 corners[4] = {float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1)};
    const float2 corner = corners[index];
    const float2 position = float2(mix(p.rect.x, p.rect.z, corner.x),
                                   mix(p.rect.y, p.rect.w, corner.y));
    DisplayVertex out;
    out.position = float4(position, 0, 1);
    // Source frames are top-down; NDC y grows upwards.
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

fragment float4 previewDisplayFragment(DisplayVertex in [[stage_in]],
                                       texture2d<float> image [[texture(0)]]) {
    // Mip filtering keeps a zoomed-out photo stable instead of aliasing;
    // magnification uses the same linear filter, as the Web canvas does.
    constexpr sampler displaySampler(filter::linear, mip_filter::linear,
                                     address::clamp_to_edge);
    return image.sample(displaySampler, in.uv);
}

// M2-R: each two-slice cache stores (base RGB, ISO log gain) and
// (full-gain RGB, compact-plane marker). The alpha channels retain enough
// information for any headroom weight, without another allocation or pass 1.
// RGB/v1 frames keep their supplied full rendition and existing interpolation.
kernel void reconstructComposition(device const float* base [[buffer(0)]],
                                   device const float* gain [[buffer(1)]],
                                   constant ReconstructParams& input [[buffer(2)]],
                                   constant uint& firstSlice [[buffer(3)]],
                                   texture2d_array<float, access::write> out [[texture(0)]],
                                   uint3 xy [[thread_position_in_grid]]) {
    if (xy.x >= input.width || xy.y >= input.height || xy.z > 1) return;
    uint i = xy.y * (input.baseRowBytes / 4) + xy.x * 3;
    bool compact = input.gainChannels == 1;
    float4 value;
    if (xy.z == 0) {
        value = float4(base[i], base[i+1], base[i+2], compact ? sampleLogGain(xy.xy, gain, input) : 0.0);
    } else {
        value = float4(reconstructPixel(xy.xy, base, gain, input), compact ? 1.0 : 0.0);
    }
    out.write(value, xy.xy, firstSlice + xy.z);
}

struct CompositionParams {
    float4 rect;
    float2 uvScale;
    uint slice, flags;
    float weight, hdrRange, backingScale, baseOffset, alternateOffset, padding;
    float4 maskColor, highlightColor, shadowColor, stripe;
};

vertex DisplayVertex compositionVertex(uint index [[vertex_id]],
                                        constant CompositionParams& p [[buffer(0)]]) {
    const float2 corners[4] = {float2(0,0),float2(1,0),float2(0,1),float2(1,1)};
    float2 c = corners[index];
    DisplayVertex out;
    out.position = float4(mix(p.rect.x,p.rect.z,c.x),mix(p.rect.y,p.rect.w,c.y),0,1);
    out.uv = float2(c.x,1-c.y) * p.uvScale;
    return out;
}

fragment float4 compositionFragment(DisplayVertex in [[stage_in]],
                                      constant CompositionParams& p [[buffer(0)]],
                                      texture2d_array<float> image [[texture(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 texel = 0.5 / float2(image.get_width(), image.get_height());
    float2 uv = clamp(in.uv, texel, p.uvScale - texel);
    float4 cachedBase = image.sample(s,uv,p.slice);
    float4 cachedHDR = image.sample(s,uv,p.slice+1);
    float3 base = cachedBase.rgb;
    float3 hdr = cachedHDR.rgb;
    float3 value = hdr;
    if (p.flags & 1) value = base;
    else if (cachedHDR.a > 0.5 && p.weight < 1) {
        // ISO reconstruction: never infer gain from a clipped full rendition.
        // Weight zero still applies both offsets; SDR preview is explicit.
        value = max(float3(0), (base + p.baseOffset) * exp2(cachedBase.a * clamp(p.weight, 0.0, 1.0)) - p.alternateOffset);
    } else if (p.weight <= 0) value = base;
    else if (p.weight < 1) {
        float3 ratio = max(float3(1e-6), (hdr + p.alternateOffset) / max(float3(1e-6), base + p.baseOffset));
        value = max(float3(0), (base + p.baseOffset) * pow(ratio, p.weight) - p.alternateOffset);
    }
    if (p.flags & 8) {
        float3 Y = float3(0.2289746,0.6917385,0.0792869);
        float stops = max(0.0,log2(max(dot(hdr,Y),1e-6) / max(dot(base,Y),1e-6)));
        float w = p.hdrRange > 0 ? clamp(stops/p.hdrRange,0.0,1.0) : 0;
        if (w > 0.01) value = mix(value,p.maskColor.rgb,w*p.maskColor.a);
    }
    // Screen-point coordinates: the period never grows with photo zoom.
    bool stripe = fmod(dot(in.position.xy,p.stripe.zw),p.stripe.x) < p.stripe.y;
    if (stripe && (p.flags & 2) && max(hdr.r,max(hdr.g,hdr.b)) >= max(1.0,exp2(p.hdrRange))*exp2(-0.01))
        value = mix(value,p.highlightColor.rgb,p.highlightColor.a);
    if (stripe && (p.flags & 4) && max(base.r,max(base.g,base.b)) < 0.5/255.0/12.92)
        value = mix(value,p.shadowColor.rgb,p.shadowColor.a);
    return float4(value,1);
}
