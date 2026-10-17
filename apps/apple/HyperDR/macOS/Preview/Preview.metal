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
    const float multiplier = exp2((p.gainMin + (p.gainMax - p.gainMin) * pow(code, p.inverseGamma))
                                  * p.gainWeight);
    return max(float3(0.0), (sdr + p.baseOffset) * multiplier - p.alternateOffset);
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
