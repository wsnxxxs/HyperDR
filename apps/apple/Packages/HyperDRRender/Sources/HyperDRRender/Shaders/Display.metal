// Gain values are decoded at their native resolution, before display sampling.
struct DisplayHDRUniform { float3x3 p3ToGain,gainToP3;float4 baseOffset,alternateOffset;uint4 channels; };
kernel void displayHDR(texture2d<float,access::read> base [[texture(0)]],
                       texture2d<float,access::sample> gain [[texture(1)]],
                       texture2d<float,access::write> output [[texture(2)]],
                       constant DisplayHDRUniform& p [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float3 g=gain.sample(s,(float2(pos)+.5f)/float2(base.get_width(),base.get_height())).rgb;
    if(p.channels.x==1)g=g.rrr;
    float4 b=base.read(pos);
    float3 h=p.gainToP3*((p.p3ToGain*b.rgb+p.baseOffset.xyz)*exp2(g)-p.alternateOffset.xyz);
    output.write(float4(h,b.a),pos);
}
struct DisplayISOUniform { float4 minimum,maximum,inverseGamma;uint4 channels; };
struct DisplayLegacyUniform { float3x3 gainToP3;float4 baseOffset,alternateOffset,region,size,inputRegion; };
void displayPeak(float3 g,device atomic_uint* peak,uint lane) {
    float value=simd_max(max(0.f,max(g.x,max(g.y,g.z))));
    if(lane==0)atomic_fetch_max_explicit(peak,as_type<uint>(value),memory_order_relaxed);
}
kernel void displayBase(texture2d<float,access::read> input [[texture(0)]],
                        texture2d<float,access::write> output [[texture(1)]],
                        constant float3x3& matrix [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    float4 b=input.read(pos);output.write(float4(matrix*b.rgb,b.a),pos);
}
kernel void displayISOGain(texture2d<float,access::read> input [[texture(0)]],
                           texture2d<float,access::write> output [[texture(1)]],
                           constant DisplayISOUniform& p [[buffer(0)]],device atomic_uint* peak [[buffer(1)]],
                           uint2 pos [[thread_position_in_grid]],uint lane [[thread_index_in_simdgroup]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    float3 code=input.read(pos).rgb;if(p.channels.x==1)code=code.rrr;
    float3 g=p.minimum.xyz+(p.maximum.xyz-p.minimum.xyz)*pow(clamp(code,0.f,1.f),p.inverseGamma.xyz);
    output.write(float4(g,0),pos);displayPeak(g,peak,lane);
}
kernel void displayGainPeak(texture2d<float,access::read> input [[texture(0)]],
                            constant uint& channels [[buffer(0)]],device atomic_uint* peak [[buffer(1)]],
                            uint2 pos [[thread_position_in_grid]],uint lane [[thread_index_in_simdgroup]]) {
    if(pos.x>=input.get_width() || pos.y>=input.get_height())return;
    float3 g=input.read(pos).rgb;if(channels==1)g=g.rrr;displayPeak(g,peak,lane);
}
kernel void displayLegacyGain(texture2d<float,access::sample> base [[texture(0)]],
                              texture2d<float,access::sample> hdr [[texture(1)]],
                              texture2d<float,access::write> output [[texture(2)]],
                              constant DisplayLegacyUniform& p [[buffer(0)]],device atomic_uint* peak [[buffer(1)]],
                              uint2 pos [[thread_position_in_grid]],uint lane [[thread_index_in_simdgroup]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    float3 h=sourceSample(hdr,float2(pos)+p.region.xy+.5f,p.size.xy,p.inputRegion).rgb;
    float3 g=isoLogRatio(h+p.alternateOffset.xyz,sourceSample(base,float2(pos)+p.region.xy+.5f,p.size.xy,p.inputRegion).rgb+p.baseOffset.xyz);
    output.write(float4(g,0),pos);
    // Legacy headroom describes HDR / SDR white, rather than HDR / local base.
    displayPeak(log2(max(float3(1),p.gainToP3*h)),peak,lane);
}
