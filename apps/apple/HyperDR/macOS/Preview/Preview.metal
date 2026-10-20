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

// Pass 2, drawing the intermediate into the drawable, is shared with the iOS
// canvas: `previewDisplayVertex` / `previewDisplayFragment` in
// Shared/Canvas/EDRDisplay.metal. The composition canvas is shared too
// (Shared/Canvas/Composition.metal); until the Mac editor renders through
// HyperDRRender (P7-2b step 4), this kernel hands it the engine's planes.

// Copies a frame's native planes into a display pair: the base as rgba, a v2
// gain as its ISO codes (the compositor decodes them after resampling), and
// v1's full-size HDR image as the alternate rendition.
kernel void uploadPreviewFrame(device const float* base [[buffer(0)]],
                               device const float* gain [[buffer(1)]],
                               constant ReconstructParams& p [[buffer(2)]],
                               texture2d<float, access::write> baseOut [[texture(0)]],
                               texture2d<float, access::write> gainOut [[texture(1)]],
                               uint2 xy [[thread_position_in_grid]]) {
    if (xy.x < p.width && xy.y < p.height) {
        const uint i = xy.y * (p.baseRowBytes / 4) + xy.x * 3;
        const float3 sdr = float3(base[i], base[i + 1], base[i + 2]);
        baseOut.write(float4(sdr, 1), xy);
        if (p.gainChannels != 1) {
            const uint j = xy.y * (p.gainRowBytes / 4) + xy.x * 3;
            gainOut.write(float4(gain[j], gain[j + 1], gain[j + 2], 1), xy);
        }
    }
    if (p.gainChannels == 1 && xy.x < p.gainWidth && xy.y < p.gainHeight) {
        gainOut.write(float4(gain[xy.y * (p.gainRowBytes / 4) + xy.x]), xy);
    }
}
