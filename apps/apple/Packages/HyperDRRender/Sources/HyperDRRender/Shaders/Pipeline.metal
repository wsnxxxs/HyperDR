#include <metal_stdlib>
using namespace metal;
// AE-3 P3 Oklab fitting, preserving negatives until this output boundary.
float sm(float a, float b, float x) {
  float t = clamp((x - a) / (b - a), 0.f, 1.f);
  return t * t * (3.f - 2.f * t);
}
float lum(float3 a) { return max(0.f, 0.2289746f * a.r + 0.6917385f * a.g + 0.0792869f * a.b); }
float3 labToRGB(float L, float A, float B) {
  float l = L + .3963377774f * A + .2158037573f * B, m = L - .1055613458f * A - .0638541728f * B,
        s = L - .0894841775f * A - 1.2914855480f * B;
  return float3(3.1281105290f * l * l * l - 2.2570750184f * m * m * m + .1293047884f * s * s * s,
                -1.0911281609f * l * l * l + 2.4132667618f * m * m * m - .3221681709f * s * s * s,
                -.0260136497f * l * l * l - .5080276490f * m * m * m + 1.5333166822f * s * s * s);
}
float cb(float x) { return copysign(pow(abs(x), 1.f / 3.f), x); }
// P3-only port of image/color.hpp. Metal has no double; searches remain 32 iterations.
float3 fit(float3 c, float upper) {
  if (all(c >= 0.f) && all(c <= upper))
    return c;
  float y = clamp(lum(c), 0.f, upper);
  float3 neutral(y);
  if (!(y > 0.f && y < upper))
    return neutral;
  float l = cb(dot(c, float3(.4813272912f, .4620679117f, .0564956029f))),
        m = cb(dot(c, float3(.2288381013f, .6532343999f, .1179544132f))),
        s = cb(dot(c, float3(.0839860178f, .2242727893f, .6922208389f)));
  float L = .2104542553f * l + .7936177850f * m - .0040720468f * s,
        A = 1.9779984951f * l - 2.4285922050f * m + .4505937099f * s,
        B = .0259040371f * l + .7827717662f * m - .8086757660f * s;
  if (length(float2(A, B)) <= 1e-9f)
    return neutral;
  float hue = atan2(B, A) * 57.295779513f,
        sw = sm(-170.f, -150.f, hue) * (1.f - sm(-60.f, -40.f, hue));
  float3 straight = neutral;
  if (sw > 0.f) {
    float amount = 1.f;
    for (uint k = 0; k < 3; k++) {
      float d = c[k] - y;
      if (d > 0)
        amount = min(amount, (upper - y) / d);
      if (d < 0)
        amount = min(amount, -y / d);
    }
    straight = neutral + clamp(amount, 0.f, 1.f) * (c - neutral);
    if (sw >= 1.f)
      return clamp(straight, 0.f, upper);
  }
  float lo = 0, hi = 1;
  float3 best = neutral;
  for (uint k = 0; k < 32; k++) {
    float mid = (lo + hi) * .5f;
    float3 rgb = labToRGB(L, A * mid, B * mid);
    float v = lum(rgb);
    if (v > 0)
      rgb *= y / v;
    float tolerance = 1e-7f * max(upper, 1.f);
    if (v > 0 && all(rgb >= -tolerance) && all(rgb <= upper + tolerance)) {
      lo = mid;
      best = rgb;
    } else
      hi = mid;
  }
  return clamp(sw * straight + (1.f - sw) * best, 0.f, upper);
}

kernel void sourceHDRSplit(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> base [[texture(1)]],
                           texture2d<float, access::write> gain [[texture(2)]],
                           constant uint &unused [[buffer(0)]],
                           uint2 pos [[thread_position_in_grid]]) {
    if (pos.x >= base.get_width() || pos.y >= base.get_height()) return;
    float4 hdr = src.read(pos);
    float g = log2(max(1.f, max(max(hdr.r, hdr.g), hdr.b)));
    base.write(float4(fit(hdr.rgb * exp2(-g), 1.f), hdr.a), pos);
    gain.write(float4(g, 0, 0, 1), pos);
}

struct Sampling { uint outputWidth, outputHeight, x, y; };
kernel void sampleSource(texture2d<float, access::sample> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant Sampling &p [[buffer(0)]],
                         uint2 pos [[thread_position_in_grid]]) {
    if (pos.x >= dst.get_width() || pos.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(pos + uint2(p.x, p.y)) + .5f) / float2(p.outputWidth, p.outputHeight);
    dst.write(src.sample(s, uv), pos);
}
kernel void zeroGain(texture2d<float, access::write> dst [[texture(0)]],
                     constant uint &unused [[buffer(0)]], uint2 pos [[thread_position_in_grid]]) {
    if (pos.x < dst.get_width() && pos.y < dst.get_height()) dst.write(float4(0), pos);
}
