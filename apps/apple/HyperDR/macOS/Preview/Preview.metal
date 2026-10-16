#include <metal_stdlib>
using namespace metal;

// Same 48-byte uniform layout and reconstruction as gpu.js. The presentation
// layer uses extended *linear* Display P3, so do not apply WGSL's sRGB transfer.
struct PreviewParams {
    float original, width, height, compact;
    float gainMin, gainMax, inverseGamma, baseOffset;
    float alternateOffset, gainWeight, pad1, pad2;
};
struct PreviewVertex { float4 position [[position]]; float2 uv; };
vertex PreviewVertex previewVertex(uint index [[vertex_id]]) {
    const float2 positions[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    const float2 uvs[] = {float2(0,1), float2(2,1), float2(0,-1)};
    return {float4(positions[index], 0, 1), uvs[index]};
}
float3 sampleHDR(uint2 xy, texture2d<float, access::read> base,
                 texture2d<float, access::read> hdr, constant PreviewParams& p) {
    const float3 sdr = base.read(xy).rgb;
    if (p.original >= 0.5) return sdr;
    if (p.compact <= 0.5) return hdr.read(xy).rgb;
    const float2 size(hdr.get_width(), hdr.get_height());
    const float2 g = clamp((float2(xy) + 0.5) * size / float2(p.width, p.height) - 0.5,
                           float2(0), size - 1);
    const uint2 lo = uint2(floor(g)), hi = min(lo + 1, uint2(size) - 1);
    const float2 w = fract(g);
    const float code = clamp(mix(mix(hdr.read(lo).r, hdr.read(uint2(hi.x, lo.y)).r, w.x),
                                 mix(hdr.read(uint2(lo.x, hi.y)).r, hdr.read(hi).r, w.x), w.y), 0.0f, 1.0f);
    const float gain = exp2(mix(p.gainMin, p.gainMax, pow(code, p.inverseGamma)) * p.gainWeight);
    return max(float3(0), (sdr + p.baseOffset) * gain - p.alternateOffset);
}
fragment float4 previewFragment(PreviewVertex in [[stage_in]],
    texture2d<float, access::read> base [[texture(0)]],
    texture2d<float, access::read> hdr [[texture(1)]], constant PreviewParams& p [[buffer(0)]]) {
    const uint2 xy = uint2(clamp(in.uv * float2(p.width, p.height), float2(0), float2(p.width - 1, p.height - 1)));
    return float4(sampleHDR(xy, base, hdr, p), 1);
}
// Offscreen readback exercises the exact reconstruction used by presentation.
kernel void previewVerify(texture2d<float, access::read> base [[texture(0)]],
    texture2d<float, access::read> hdr [[texture(1)]], constant PreviewParams& p [[buffer(0)]],
    device float4* output [[buffer(1)]], uint2 xy [[thread_position_in_grid]]) {
    if (xy.x < uint(p.width) && xy.y < uint(p.height))
        output[xy.y * uint(p.width) + xy.x] = float4(sampleHDR(xy, base, hdr, p), 1);
}
