// Shared point operators, used by individual nodes and the fused full graph.
float maximum(float3 x) { return max(x.r, max(x.g, x.b)); }
float rawY(float3 x) { return dot(x, float3(.2289746f,.6917385f,.0792869f)); }
float contrastY(float y, float c) {
    if (c == 1 || y >= 1 || y <= 0) return y;
    if (y <= .18f) return .18f * pow(y / .18f, c);
    // AE-3 anchors and gray-point slope, with a cubic upper segment whose
    // derivative is exactly one at white, matching the EDR identity segment.
    float t = (y - .18f) / .82f;
    return .18f + .82f * (t + (c-1) * t * (1-t) * (1-t));
}
float3 pointOp(float3 rgb, uint op, float amount, bool sdr) {
    if (op == 1 ? amount == 1 : amount == 0) return rgb;
    float y = lum(rgb), target = y, a = amount;
    if (op == 0) {
        rgb *= exp2(amount);
        y = lum(rgb);
        if (sdr && amount > 0 && y > .48f) {
            target = .48f + .52f * (1 - exp(-(y-.48f)/.52f));
            rgb *= target / y;
        }
        return rgb;
    }
    if (op == 5 || op == 6) {
        float3 scale = op == 5 ? exp2(float3(.4f*a,0,-.4f*a))
                              : exp2(float3(-.2f*a,.4f*a,-.2f*a));
        float3 changed = rgb * scale;
        // Linear matrix M = D + 1*(w' - w'D), so w'M = w' exactly.
        return changed + (rawY(rgb) - rawY(changed));
    }
    if (op == 7 || op == 8) {
        float3 chroma = rgb - y;
        float saturation = maximum(abs(chroma)) / max(y,1e-6f);
        float factor = op == 7 ? 1 + a*(1-sm(.15f,1.f,saturation)) : 1+a;
        return y + chroma * factor;
    }
    if (op == 1) target = contrastY(y,amount);
    if (op == 2) target = y > 1 ? 1+(y-1)*exp2(2*a) : y + .3f*a*sm(.4f,1.f,y)*(1-y);
    if (op == 3 && y < .5f) { float t=y/.5f; target=.5f*(t+.8f*a*t*(1-t)*(1-t)); }
    if (op == 4 && y < .1f) target = max(0.f,y-.03f*a*(1-sm(0.f,.1f,y)));
    return y > 1e-8f ? rgb * (target/y) : (op == 4 ? rgb + target : rgb);
}
struct PointUniform { uint op, sdr; float value, unused; };
kernel void adjustPoint(texture2d<float,access::read> src [[texture(0)]],
                        texture2d<float,access::write> dst [[texture(1)]],
                        constant PointUniform& p [[buffer(0)]], uint2 pos [[thread_position_in_grid]]) {
    if (pos.x >= dst.get_width() || pos.y >= dst.get_height()) return;
    float4 x = src.read(pos);
    dst.write(float4(pointOp(x.rgb,p.op,p.value,p.sdr),x.a),pos);
}

struct GraphUniform {
    float4 tone0, tone1, color, hdr;
    uint4 flags, lutInfo;
    float4 lutMin, lutMax;
    uint4 region, mode;
};
float3 p3to709(float3 x) { return float3(dot(x,float3(1.22494018f,-.22494018f,0)),dot(x,float3(-.04205695f,1.04205695f,0)),dot(x,float3(-.01963755f,-.07863605f,1.09827360f))); }
float3 toP3from709(float3 x) { return float3(dot(x,float3(.82246197f,.17753803f,0)),dot(x,float3(.03319420f,.96680580f,0)),dot(x,float3(.01708263f,.07239741f,.91051996f))); }
float3 p3to2020(float3 x) { return float3(dot(x,float3(.753833f,.198597f,.047570f)),dot(x,float3(.045744f,.941777f,.012479f)),dot(x,float3(-.001210f,.017602f,.983608f))); }
float3 toP3from2020(float3 x) { return float3(dot(x,float3(1.3435783f,-.2821797f,-.0613986f)),dot(x,float3(-.0652975f,1.0757879f,-.0104905f)),dot(x,float3(.0028218f,-.0195985f,1.0167767f))); }
float3 p3toCine(float3 x) { return float3(dot(x,float3(.77815155f,.11728624f,.10456221f)),dot(x,float3(.07226832f,.75994794f,.16778375f)),dot(x,float3(.02346043f,.06084114f,.91569844f))); }
float3 cineToP3(float3 x) { return float3(dot(x,float3(1.30640907f,-.19250497f,-.11390411f)),dot(x,float3(-.11858463f,1.35294405f,-.23435942f)),dot(x,float3(-.02559149f,-.08496073f,1.11055222f))); }
float pqEncode(float x) { float z=pow(clamp(x*.0203f,0.f,1.f),2610.f/16384); return pow((3424.f/4096+2413.f/128*z)/(1+2392.f/128*z),2523.f/32); }
float pqDecode(float x) { float z=pow(clamp(x,0.f,1.f),32.f/2523); return pow(max(z-3424.f/4096,0.f)/max(2413.f/128-2392.f/128*z,1e-6f),16384.f/2610)/.0203f; }
float3 lutEncode(float3 x,uint space) {
    if (space == 5) x=p3toCine(x);
    else if (space == 3 || space == 4) x=p3to2020(x);
    else if (space != 1) {
        // Fit the 709 cube at constant luminance before applying its matrix.
        float3 n=rawY(x), r=p3to709(x); float amount=1;
        float y=clamp(rawY(x),0.f,1.f);
        for(uint c=0;c<3;c++) { float d=r[c]-y; if(d>0) amount=min(amount,(1-y)/d); if(d<0) amount=min(amount,-y/d); }
        x=p3to709(float3(y)+clamp(amount,0.f,1.f)*(x-float3(y)));
    }
    if (space == 3) {
        float3 display=max(x*.203f,0.f); float y=dot(display,float3(.2627f,.6780f,.0593f));
        if (y <= 0) return 0; if (y >= 1) return 1;
        float upper=pow(y,1.f-1.f/1.2f), peak=maximum(display);
        if(peak>upper) display=y+(upper-y)/(peak-y)*(display-y);
        x=min(1.f,display*pow(y,1.f/1.2f-1.f));
        for(uint c=0;c<3;c++) x[c]=x[c]<=1.f/12 ? sqrt(3*x[c]) : .17883277f*log(12*x[c]-.28466892f)+.55991073f;
        return x;
    }
    for(uint c=0;c<3;c++) {
        float v=x[c];
        if(space==5) x[c]=v>=.01125f ? (420+261.5f*log10((v+.01f)/.19f))/1023 : (v*(171.2102946929f-95)/.01125f+95)/1023;
        else if(space==4) x[c]=pqEncode(v);
        else if(space==2) x[c]=pow(max(v,0.f),1.f/2.4f);
        else x[c]=v<=.0031308f ? 12.92f*v : 1.055f*pow(v,1.f/2.4f)-.055f;
    }
    return x;
}
float3 lutDecode(float3 x,uint space) {
    if(space==3) {
        for(uint c=0;c<3;c++) { float v=clamp(x[c],0.f,1.f);x[c]=v<=.5f ? v*v/3 : (exp((v-.55991073f)/.17883277f)+.28466892f)/12; }
        x*=pow(abs(dot(x,float3(.2627f,.6780f,.0593f))),.2f)/.203f;
    } else for(uint c=0;c<3;c++) {
        float v=x[c];
        if(space==5) x[c]=v>=171.2102946929f/1023 ? pow(10.f,(v*1023-420)/261.5f)*.19f-.01f : (v*1023-95)*.01125f/(171.2102946929f-95);
        else if(space==4) x[c]=pqDecode(v);
        else if(space==2) x[c]=pow(max(v,0.f),2.4f);
        else x[c]=v<=.04045f ? v/12.92f : pow((v+.055f)/1.055f,2.4f);
    }
    if(space==5) return cineToP3(x);
    if(space==3 || space==4) return toP3from2020(x);
    if(space!=1) return toP3from709(x);
    return x;
}
float3 lutSample(float3 rgb,constant GraphUniform& p, texture3d<float,access::read> cube, device const float4* table) {
    float3 pos=clamp((rgb-p.lutMin.xyz)/(p.lutMax.xyz-p.lutMin.xyz),0.f,1.f)*float(p.lutInfo.x-1);
    uint3 lo=uint3(floor(pos)),hi=min(lo+1,p.lutInfo.x-1);float3 t=pos-float3(lo);
    if(!p.lutInfo.y) return float3(mix(table[lo.x].r,table[hi.x].r,t.x),mix(table[lo.y].g,table[hi.y].g,t.y),mix(table[lo.z].b,table[hi.z].b,t.z));
    float3 a=mix(mix(cube.read(uint3(lo.x,lo.y,lo.z)).rgb,cube.read(uint3(hi.x,lo.y,lo.z)).rgb,t.x),mix(cube.read(uint3(lo.x,hi.y,lo.z)).rgb,cube.read(uint3(hi.x,hi.y,lo.z)).rgb,t.x),t.y);
    float3 b=mix(mix(cube.read(uint3(lo.x,lo.y,hi.z)).rgb,cube.read(uint3(hi.x,lo.y,hi.z)).rgb,t.x),mix(cube.read(uint3(lo.x,hi.y,hi.z)).rgb,cube.read(uint3(hi.x,hi.y,hi.z)).rgb,t.x),t.y);
    return mix(a,b,t.z);
}
float3 applyLUT(float3 rgb,constant GraphUniform& p,texture3d<float,access::read> cube,device const float4* table) {
    if(p.color.y==0) return rgb;
    float3 changed=lutDecode(lutSample(lutEncode(rgb,p.lutInfo.z),p,cube,table),p.lutInfo.w);
    changed=fit(changed,p.flags.y ? 1.f : max(1.f,maximum(changed)));
    return mix(rgb,changed,p.color.y);
}
struct WorkingPair { float3 base; float gain; float alpha; };
WorkingPair preparePair(float4 pixel,constant GraphUniform& p,texture3d<float,access::read> cube,device const float4* table) {
    float3 rgb=pixel.rgb;
    rgb=pointOp(rgb,5,p.tone1.y,p.flags.x==0);rgb=pointOp(rgb,6,p.tone1.z,p.flags.x==0);
    rgb=pointOp(rgb,0,p.tone0.x,p.flags.x==0);rgb=pointOp(rgb,1,p.tone0.y,false);
    rgb=pointOp(rgb,2,p.tone0.z,false);rgb=pointOp(rgb,3,p.tone0.w,false);rgb=pointOp(rgb,4,p.tone1.x,false);
    rgb=pointOp(rgb,7,p.tone1.w,false);rgb=pointOp(rgb,8,p.color.x,false);
    rgb=fit(rgb,max(1.f,maximum(rgb))); // C2: fit at an upper bound >= Y, never remove HDR luminance.
    if(p.flags.z) rgb=applyLUT(rgb,p,cube,table);
    float g=(p.flags.x!=0 || p.flags.z) ? log2(max(1.f,maximum(rgb))) : 0;
    float3 base=fit(rgb*exp2(-g),1.f);
    if(p.flags.y) base=applyLUT(base,p,cube,table);
    return {base,g,pixel.a};
}
float softPeak(float peak,float limit,bool gate) {
    if(!gate || peak<=1 || limit<=1) return peak;
    float knee=1+.75f*(limit-1), width=limit-knee;
    return peak<=knee ? peak : knee+width*(1-exp(-(peak-knee)/width));
}
// Fixed-scale per-cell integrals. Every source pixel contributes; bright single
// pixels survive in the peak plane even when the analysis resolution is small.
kernel void graphCells(texture2d<float,access::read> src [[texture(0)]],
                       texture2d<float,access::write> stats [[texture(1)]],
                       texture2d<float,access::write> peaks [[texture(2)]],
                       texture3d<float,access::read> cube [[texture(3)]],
                       texture2d<float,access::write> masks [[texture(4)]],
                       constant GraphUniform& p [[buffer(0)]],device const float4* table [[buffer(1)]],
                       uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=stats.get_width() || pos.y>=stats.get_height()) return;
    uint2 lo=pos*uint2(src.get_width(),src.get_height())/uint2(stats.get_width(),stats.get_height());
    uint2 hi=(pos+1)*uint2(src.get_width(),src.get_height())/uint2(stats.get_width(),stats.get_height());
    float4 sum=0,peak=0;
    for(uint y=lo.y;y<hi.y;y++)for(uint x=lo.x;x<hi.x;x++) {
        float4 original=src.read(uint2(x,y));
        auto v=preparePair(original,p,cube,table);
        float l=lum(v.base), request=sm(p.hdr.x,1.f,l), z=clamp(log2(l+1e-6f),-8.f,8.f);
        sum+=float4(l,request,z,z*z);
        peak=max(peak,float4(maximum(v.base)*exp2(v.gain),maximum(v.base),v.gain,maximum(original.rgb)));
    }
    float4 mean=sum/float((hi.x-lo.x)*(hi.y-lo.y));stats.write(mean,pos);peaks.write(peak,pos);
    masks.write(float4(sm(.4f,1.f,mean.x),1-sm(0.f,.5f,mean.x),1-sm(0.f,.1f,mean.x),mean.y),pos);
}
struct BoxUniform { uint radius,vertical,width,height; };
kernel void graphBox(texture2d<float,access::read> src [[texture(0)]],texture2d<float,access::write> dst [[texture(1)]],
                     constant BoxUniform& p [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=p.width || pos.y>=p.height)return;float4 sum=0;
    int index=p.vertical?pos.y:pos.x,low=max(0,index-int(p.radius)),high=min(int(p.vertical?p.height:p.width)-1,index+int(p.radius));
    for(int k=low;k<=high;k++)sum+=src.read(p.vertical?uint2(pos.x,k):uint2(k,pos.y));
    dst.write(sum/float(high-low+1),pos);
}
kernel void graphWeights(texture2d<float,access::read> cells [[texture(0)]],texture2d<float,access::read> env [[texture(1)]],
                         texture2d<float,access::write> dst [[texture(2)]],constant GraphUniform& p [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=dst.get_width() || pos.y>=dst.get_height())return;
    float4 c=cells.read(pos),e=env.read(pos);
    float spec=sm(1.f,2.5f,c.z-e.z),absolute=sm(.7f,1.5f,c.x*exp2(3*c.y));
    float noise=.35f*(1-sm(.03f,.2f,c.x))*sm(.005f,.07f,max(0.f,e.w-e.z*e.z));
    float gain=3*c.y*(p.hdr.y+(1-p.hdr.y)*spec*absolute)*(1-noise);
    dst.write(float4(c.x,gain,c.x*c.x,c.x*gain),pos);
}
kernel void graphCoefficients(texture2d<float,access::read> mean [[texture(0)]],texture2d<float,access::write> dst [[texture(1)]],
                              constant uint& unused [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=dst.get_width() || pos.y>=dst.get_height())return;float4 m=mean.read(pos);
    float a=(m.w-m.x*m.y)/(max(0.f,m.z-m.x*m.x)+.005f);dst.write(float4(a,m.y-a*m.x,0,0),pos);
}
kernel void graphFinalGain(texture2d<float,access::read> cells [[texture(0)]],texture2d<float,access::read> coeff [[texture(1)]],
                           texture2d<float,access::read> weights [[texture(2)]],texture2d<float,access::write> dst [[texture(3)]],
                           constant uint& unused [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=dst.get_width() || pos.y>=dst.get_height())return;
    float y=cells.read(pos).x;float2 c=coeff.read(pos).xy;
    dst.write(float4(clamp(c.x*y+c.y,0.f,weights.read(pos).y),0,0,0),pos);
}
kernel void graphPeak(texture2d<float,access::read> peaks [[texture(0)]],texture2d<float,access::read> gain [[texture(1)]],
                      constant uint& unused [[buffer(0)]],device float4* output [[buffer(1)]],uint pos [[thread_position_in_grid]]) {
    if(pos)return;float4 value=0;float analytic=0;
    for(uint y=0;y<peaks.get_height();y++)for(uint x=0;x<peaks.get_width();x++) {
        value=max(value,peaks.read(uint2(x,y)));analytic=max(analytic,gain.read(uint2(x,y)).x);
    }
    output[0]=float4(value.xyz,analytic);output[1]=float4(value.w,0,0,0);
}
kernel void graphOutput(texture2d<float,access::sample> src [[texture(0)]],texture2d<float,access::write> base [[texture(1)]],
                        texture2d<float,access::write> gain [[texture(2)]],texture3d<float,access::read> cube [[texture(3)]],
                        texture2d<float,access::sample> expansion [[texture(4)]],constant GraphUniform& p [[buffer(0)]],
                        device const float4* table [[buffer(1)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=base.get_width() || pos.y>=base.get_height())return;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 uv=(float2(pos+p.region.zw)+.5f)/float2(p.region.xy);
    auto pair=preparePair(src.sample(s,uv),p,cube,table);
    float g=pair.gain;
    if(p.mode.x)g=max(g,expansion.sample(s,uv).x*p.color.z/3);
    g*=p.color.w;
    float peak=maximum(pair.base)*exp2(g), mapped=softPeak(peak,exp2(p.color.z),p.hdr.w!=0);
    if(peak>0)g+=log2(max(mapped/peak,1e-30f));
    if(p.hdr.z>0 && p.flags.x!=0 && p.flags.x!=3) {
        float m=maximum(pair.base);
        if(m>.7f) {
            float target=mix(m,.7f+.3f*(1-exp(-(m-.7f)/.3f)),p.hdr.z);
            pair.base*=target/m;g+=log2(m/target);
        }
    }
    if(!p.flags.w)g=0;
    base.write(float4(pair.base,pair.alpha),pos);gain.write(float4(g,0,0,0),pos);
}
struct AuthorUniform { float4 minimum,maximum,inverseGamma,baseOffset,alternateOffset,controls;uint4 info; };
float3 isoLogRatio(float3 numerator,float3 denominator) {
    // Zero over zero is an unlit channel: choose zero stops, as in the double reference.
    return select(log2(max(numerator/max(denominator,1e-30f),1e-30f)),float3(0),denominator==0);
}
kernel void authoredOutput(texture2d<float,access::sample> baseWorking [[texture(0)]],texture2d<float,access::sample> encoded [[texture(1)]],
                           texture2d<float,access::sample> systemHDR [[texture(2)]],texture2d<float,access::write> output [[texture(3)]],
                           constant AuthorUniform& p [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 uv=(float2(pos+uint2(p.info.z,p.info.w))+.5f)/p.controls.zw;
    float3 b=baseWorking.sample(s,uv).rgb,oB=p.baseOffset.xyz,oA=p.alternateOffset.xyz;
    float3 g;
    if(p.info.y&1) {
        float3 v=encoded.sample(s,uv).rgb;if(p.info.x==1)v=v.rrr;
        g=p.minimum.xyz+(p.maximum.xyz-p.minimum.xyz)*pow(clamp(v,0.f,1.f),p.inverseGamma.xyz);
    } else {
        // Legacy Apple: exact per-channel ISO inversion, never a luminance ratio.
        g=isoLogRatio(systemHDR.sample(s,uv).rgb+oA,b+oB);
    }
    float3 neutral=isoLogRatio(b+oA,b+oB);
    g=neutral+(g-neutral)*p.controls.x;
    float3 h=(b+oB)*exp2(g)-oA;
    float peak=maximum(h),mapped=softPeak(peak,exp2(p.controls.y),p.info.y&2);
    if(peak>0 && mapped!=peak) {
        h*=mapped/peak;g=isoLogRatio(h+oA,b+oB);
    }
    output.write(float4(g,0),pos);
}
