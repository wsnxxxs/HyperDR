#include <metal_stdlib>
using namespace metal;

// The display layer of the canvas, shared by the Mac and iOS targets: each
// rendition arrives as a base plus a gain (`DisplayPair`), is rebuilt at the
// screen's weight at SOURCE resolution, then drawn with the comparison split,
// detail tiles and overlays.

struct DisplayLayerParams {
    float4 baseOffset, alternateOffset;
    float gainMin, gainMax, inverseGamma, weight;
    uint gainChannels, coding, firstSlice, firstPlane;
};

// Bilinear in the stored coding, then decoded: an ISO code is interpolated
// before its gamma, as a gain-map reader does.
float3 sampleDisplayGain(uint2 xy, uint2 size, texture2d<float, access::read> gain,
                         constant DisplayLayerParams& p) {
    const float2 gainSize = float2(gain.get_width(), gain.get_height());
    const float2 g = clamp((float2(xy) + 0.5) * gainSize / float2(size) - 0.5,
                           float2(0), gainSize - 1);
    const uint2 lo = uint2(floor(g));
    const uint2 hi = min(lo + 1, uint2(gainSize) - 1);
    const float2 w = fract(g);
    const float4 v = mix(mix(gain.read(lo), gain.read(uint2(hi.x, lo.y)), w.x),
                         mix(gain.read(uint2(lo.x, hi.y)), gain.read(hi), w.x), w.y);
    float3 value = p.gainChannels == 1 ? float3(v.r) : v.rgb;
    if (p.coding == 1) {
        value = p.gainMin + (p.gainMax - p.gainMin) * pow(clamp(value, 0.0, 1.0), p.inverseGamma);
    }
    return value;
}

// Three slices: base, full HDR (overlay statistics), and weighted HDR. A
// headroom-only update writes plane 2 without touching base or full HDR.
// Weight zero still applies both ISO offsets; clipping is the final step.
kernel void composeDisplayLayers(texture2d<float, access::read> base [[texture(0)]],
                                 texture2d<float, access::read> gain [[texture(1)]],
                                 texture2d_array<float, access::write> out [[texture(2)]],
                                 constant DisplayLayerParams& p [[buffer(0)]],
                                 uint3 xy [[thread_position_in_grid]]) {
    const uint2 size = uint2(base.get_width(), base.get_height());
    const uint plane = p.firstPlane + xy.z;
    if (xy.x >= size.x || xy.y >= size.y || plane >= 3) return;
    const float3 sdr = base.read(xy.xy).rgb;
    float3 value = sdr;
    const float weight = plane == 1 ? 1.0 : clamp(p.weight, 0.0, 1.0);
    if (plane != 0 && p.coding == 2) {
        // The alternate rendition: keep both endpoints exact.
        const float3 hdr = gain.read(xy.xy).rgb;
        if (weight >= 1) value = hdr;
        else if (weight > 0) {
            const float3 ratio = max(float3(1e-6), (hdr + p.alternateOffset.rgb) / max(float3(1e-6), sdr + p.baseOffset.rgb));
            value = max(float3(0), (sdr + p.baseOffset.rgb) * pow(ratio, weight) - p.alternateOffset.rgb);
        }
    } else if (plane != 0) {
        value = max(float3(0), (sdr + p.baseOffset.rgb) * exp2(sampleDisplayGain(xy.xy, size, gain, p) * weight)
                               - p.alternateOffset.rgb);
    }
    out.write(float4(value, 1), xy.xy, p.firstSlice + plane);
}

struct CompositionVertex {
    float4 position [[position]];
    float2 uv;
};

struct CompositionParams {
    float4 rect;
    float2 uvScale;
    uint slice, flags;
    float padding0, hdrRange, backingScale, padding1, padding2, padding;
    float4 maskColor, highlightColor, shadowColor, stripe;
};

vertex CompositionVertex compositionVertex(uint index [[vertex_id]],
                                        constant CompositionParams& p [[buffer(0)]]) {
    const float2 corners[4] = {float2(0,0),float2(1,0),float2(0,1),float2(1,1)};
    float2 c = corners[index];
    CompositionVertex out;
    out.position = float4(mix(p.rect.x,p.rect.z,c.x),mix(p.rect.y,p.rect.w,c.y),0,1);
    out.uv = float2(c.x,1-c.y) * p.uvScale;
    return out;
}

fragment float4 compositionFragment(CompositionVertex in [[stage_in]],
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
