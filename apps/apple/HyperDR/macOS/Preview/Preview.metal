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

// Decode ISO gain directly: a clipped full rendition cannot recover it.
// Shared by legacy reconstruction and the composition compute pass.
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
                        constant ReconstructParams& p, float weight) {
    const uint baseIndex = xy.y * (p.baseRowBytes / 4) + xy.x * 3;
    const float3 sdr = float3(base[baseIndex], base[baseIndex + 1], base[baseIndex + 2]);
    if (p.original != 0) return sdr;
    if (p.gainChannels != 1) {
        // v1: the gain plane is a full-size HDR image, already reconstructed.
        const uint index = xy.y * (p.gainRowBytes / 4) + xy.x * 3;
        return float3(gain[index], gain[index + 1], gain[index + 2]);
    }
    return max(float3(0.0), (sdr + p.baseOffset) * exp2(sampleLogGain(xy, gain, p) * weight)
                            - p.alternateOffset);
}

// Production intermediate: rgba16Float, one texel per source pixel.
kernel void reconstructFrame(device const float* base [[buffer(0)]],
                             device const float* gain [[buffer(1)]],
                             constant ReconstructParams& p [[buffer(2)]],
                             texture2d<float, access::write> out [[texture(0)]],
                             uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= p.width || xy.y >= p.height) return;
    out.write(float4(reconstructPixel(xy, base, gain, p, p.gainWeight), 1.0), xy);
}

// Same kernel, readable float target: the shader test compares pass 1 against
// the frozen Web reference without half-float quantisation.
kernel void reconstructFrame32(device const float* base [[buffer(0)]],
                               device const float* gain [[buffer(1)]],
                               constant ReconstructParams& p [[buffer(2)]],
                               texture2d<float, access::write> out [[texture(0)]],
                               uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= p.width || xy.y >= p.height) return;
    out.write(float4(reconstructPixel(xy, base, gain, p, p.gainWeight), 1.0), xy);
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

// Reconstruct all display weights at SOURCE resolution, before filtering.
// The three slices are base, full HDR (overlay statistics), and weighted HDR.
// A headroom-only update writes plane 2 without touching base or full HDR.
kernel void reconstructComposition(device const float* base [[buffer(0)]],
                                   device const float* gain [[buffer(1)]],
                                   constant ReconstructParams& input [[buffer(2)]],
                                   constant uint& firstSlice [[buffer(3)]],
                                   constant uint& firstPlane [[buffer(4)]],
                                   texture2d_array<float, access::write> out [[texture(0)]],
                                   uint3 xy [[thread_position_in_grid]]) {
    uint plane = firstPlane + xy.z;
    if (xy.x >= input.width || xy.y >= input.height || plane >= 3) return;
    uint i = xy.y * (input.baseRowBytes / 4) + xy.x * 3;
    float3 sdr = float3(base[i], base[i+1], base[i+2]);
    float3 value = sdr;
    if (plane == 1) value = reconstructPixel(xy.xy, base, gain, input, 1.0);
    else if (plane == 2) {
        float weight = clamp(input.gainWeight, 0.0, 1.0);
        if (input.gainChannels == 1) {
            // Raw log gain, not an inverse of a clipped full rendition. Weight
            // zero also applies both ISO offsets; clipping is the final step.
            value = reconstructPixel(xy.xy, base, gain, input, weight);
        } else {
            float3 hdr = reconstructPixel(xy.xy, base, gain, input, 1.0);
            // Preserve RGB/v1 reconstruction and explicit endpoint semantics.
            if (weight >= 1) value = hdr;
            else if (weight > 0) {
                float3 ratio = max(float3(1e-6), (hdr + input.alternateOffset) / max(float3(1e-6), sdr + input.baseOffset));
                value = max(float3(0), (sdr + input.baseOffset) * pow(ratio, weight) - input.alternateOffset);
            }
        }
    }
    out.write(float4(value, 1), xy.xy, firstSlice + plane);
}

struct CompositionParams {
    float4 rect;
    float2 uvScale;
    uint slice, flags;
    float padding0, hdrRange, backingScale, padding1, padding2, padding;
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
    float3 base = image.sample(s,uv,p.slice).rgb;
    float3 hdr = image.sample(s,uv,p.slice+1).rgb;
    // All spatial/mip filtering operates on already reconstructed linear light.
    float3 value = (p.flags & 1) ? base : image.sample(s,uv,p.slice+2).rgb;
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
