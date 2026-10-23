struct ExportUniform {
    float3x3 toGain,toP3;
    float4 baseOffset,alternateOffset;
    uint4 info; // source channels, resplit, flatten alpha, SDR-only / validate-only
    float4 controls; // output ceiling in linear white, apply shoulder, unused
};
float3 exportHDR(float3 b,float3 g,constant ExportUniform& p) {
    return p.toP3*((p.toGain*b+p.baseOffset.xyz)*exp2(g)-p.alternateOffset.xyz);
}
kernel void exportSummary(texture2d<float,access::read> base [[texture(0)]],
                          texture2d<float,access::sample> gain [[texture(1)]],
                          constant ExportUniform& p [[buffer(0)]],device atomic_uint* stats [[buffer(1)]],
                          uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=base.get_width() || pos.y>=base.get_height())return;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float4 b=base.read(pos);float3 g=gain.sample(s,(float2(pos)+.5f)/float2(base.get_width(),base.get_height())).rgb;
    if(p.info.x==1)g=g.rrr;
    if(!all(isfinite(b)) || !all(isfinite(g)))atomic_store_explicit(stats+4,1,memory_order_relaxed);
    if(p.info.w) {
        float3 h=exportHDR(b.rgb,g,p)*clamp(b.a,0.f,1.f);
        if(!all(isfinite(h)))atomic_store_explicit(stats+4,1,memory_order_relaxed);
        return;
    }
    atomic_fetch_max_explicit(stats,as_type<uint>(max(0.f,maximum(g))),memory_order_relaxed);
    if(any(g<0))atomic_store_explicit(stats+1,1,memory_order_relaxed);
    if(b.a<1)atomic_store_explicit(stats+2,1,memory_order_relaxed);
    float3 h=exportHDR(b.rgb,g,p)*clamp(b.a,0.f,1.f);
    if(!all(isfinite(h)))atomic_store_explicit(stats+4,1,memory_order_relaxed);
    float peak=max(0.f,maximum(h));
    atomic_fetch_max_explicit(stats+3,as_type<uint>(peak),memory_order_relaxed);
}
struct ExportPixel { float4 base;float3 gain; };
ExportPixel exportPairPixel(float4 b,float3 g,constant ExportUniform& p) {
    if(p.info.y && !p.info.w) {
        float3 h=exportHDR(b.rgb,g,p);
        if(p.info.z)h*=clamp(b.a,0.f,1.f); // legacy black matte, after ISO reconstruction
        float peak=maximum(h), rawGain=log2(max(1.f,peak));
        // Determine base before applying the output ceiling (H1/R10-001).
        b.rgb=fit(h*exp2(-rawGain),1.f);
        float mapped=softPeak(peak,p.controls.x,p.controls.y!=0);
        g=float3(max(0.f,rawGain+(peak>0 ? log2(max(mapped,1e-20f)/peak) : 0.f)));
    } else if(p.info.z) b.rgb*=clamp(b.a,0.f,1.f);
    return {float4(b.rgb,1),g};
}
kernel void exportPair(texture2d<float,access::read> base [[texture(0)]],
                       texture2d<float,access::sample> gain [[texture(1)]],
                       texture2d<float,access::write> outputBase [[texture(2)]],
                       texture2d<float,access::write> outputGain [[texture(3)]],
                       constant ExportUniform& p [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=outputBase.get_width() || pos.y>=outputBase.get_height())return;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float4 b=base.read(pos);float3 g=gain.sample(s,(float2(pos)+.5f)/float2(base.get_width(),base.get_height())).rgb;
    if(p.info.x==1)g=g.rrr;
    ExportPixel value=exportPairPixel(b,g,p);
    outputBase.write(value.base,pos);outputGain.write(float4(value.gain,0),pos);
}
struct FrameUniform {
    uint4 photo,caption; // canvas rectangles
    float4 paper,shadow; // opacity,sigma,offsetX,offsetY
    uint4 region; // output band y, photo input's canvas y, has photo, has caption
    uint4 horizontal; // output x, photo input's canvas x, caption texture origin x/y
};
float exportErf(float x) {
    float t=1.f/(1.f+.3275911f*abs(x));
    float v=1.f-(((((1.061405429f*t-1.453152027f)*t)+1.421413741f)*t-.284496736f)*t+.254829592f)*t*exp(-x*x);
    return copysign(v,x);
}
float frameCoverage(float x,float lo,float hi,float sigma) {
    if(sigma<=0)return x>=lo && x<hi ? 1.f : 0.f;
    float s=1.f/(sigma*sqrt(2.f));return .5f*(exportErf((x-lo)*s)-exportErf((x-hi)*s));
}
kernel void exportFrame(texture2d<float,access::read> photoBase [[texture(0)]],
                        texture2d<float,access::read> photoGain [[texture(1)]],
                        texture2d<float,access::read> caption [[texture(2)]],
                        texture2d<float,access::write> base [[texture(3)]],
                        texture2d<float,access::write> gain [[texture(4)]],
                        constant FrameUniform& p [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=base.get_width() || pos.y>=base.get_height())return;
    uint2 global=pos+uint2(p.horizontal.x,p.region.x);
    bool inPhoto=all(global>=p.photo.xy) && all(global-p.photo.xy<p.photo.zw);
    if(inPhoto && p.region.z) {
        uint2 local=uint2(global.x-p.horizontal.y,global.y-p.region.y);
        base.write(photoBase.read(local),pos);gain.write(photoGain.read(local),pos);return;
    }
    float2 xy=float2(global)+.5f, lo=float2(p.photo.xy)+p.shadow.zw,hi=lo+float2(p.photo.zw);
    float coverage=frameCoverage(xy.x,lo.x,hi.x,p.shadow.y)*frameCoverage(xy.y,lo.y,hi.y,p.shadow.y);
    float3 color=p.paper.rgb*(1.f-p.shadow.x*coverage);
    if(p.region.w && all(global>=p.caption.xy) && all(global-p.caption.xy<p.caption.zw)) {
        float4 ink=caption.read(global-p.horizontal.zw);
        color=mix(color,clamp(ink.rgb,0.f,1.f),clamp(ink.a,0.f,1.f));
    }
    base.write(float4(color,1),pos);gain.write(float4(0),pos);
}

struct ExportPackedUniform { ExportUniform pair;uint4 channels; };
kernel void exportPackedPair(texture2d<float,access::read> base [[texture(0)]],
                             texture2d<float,access::sample> gain [[texture(1)]],
                             constant ExportPackedUniform& p [[buffer(0)]],
                             device packed_uint3* outputBase [[buffer(1)]],
                             device uint* outputGain [[buffer(2)]],device atomic_uint* invalid [[buffer(3)]],
                             uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=base.get_width() || pos.y>=base.get_height())return;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float4 b=base.read(pos);float3 g=gain.sample(s,(float2(pos)+.5f)/float2(base.get_width(),base.get_height())).rgb;
    if(p.pair.info.x==1)g=g.rrr;
    bool bad=!all(isfinite(b)) || !all(isfinite(g));
    // Preserve SDR's finite-input check before flattening can hide NaN alpha,
    // including a finite gain whose affine HDR reconstruction overflows.
    if(p.pair.info.w) {
        float3 h=exportHDR(b.rgb,g,p.pair)*clamp(b.a,0.f,1.f);
        bad=bad || !all(isfinite(h));
    }
    ExportPixel value=exportPairPixel(b,g,p.pair);
    bad=bad || !all(isfinite(value.base)) || !all(isfinite(value.gain));
    uint i=pos.y*base.get_width()+pos.x;
    outputBase[i]=packed_uint3(as_type<uint3>(value.base.rgb));
    if(p.channels.x==1)outputGain[i]=as_type<uint>(value.gain.x);
    else if(p.channels.x==3) {
        uint3 bits=as_type<uint3>(value.gain);
        outputGain[3*i]=bits.x;outputGain[3*i+1]=bits.y;outputGain[3*i+2]=bits.z;
    }
    if(bad)atomic_store_explicit(invalid,1u,memory_order_relaxed);
}
