#include <metal_stdlib>
using namespace metal;

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
