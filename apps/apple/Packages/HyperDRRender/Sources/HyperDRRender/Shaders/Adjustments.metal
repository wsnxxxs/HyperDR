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
        float factor=exp2(amount), originalY=y;
        rgb *= factor;
        if (sdr && amount > 0) {
            // This original-domain knee tends to white as EV tends to zero.
            // The upper power joins with slope factor and reaches white at slope zero.
            float knee=exp2(-2*amount);
            if(originalY>knee) {
                float distance=clamp((1-originalY)/(1-knee),0.f,1.f);
                target=1-(1-1/factor)*pow(distance,factor+1);
                rgb*=target/(originalY*factor);
            }
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
    float4 inputRegion;
    float4 film; // strength (0: no film), grain amount, 1/pixel area (µm⁻²), exposure factor
    float4 halation; // per-channel strength, w: the render samples a halation map
    int4 scatter; // xy: the region's offset in the scattered film exposure, z: the render reads it
    float4 pair; // x: equal offset for independently edited SDR/HDR endpoints
    float4 effects; // generic grain, halation, inverse 35 mm pixel area, stock processing
};
float3 p3to709(float3 x) { return float3(dot(x,float3(1.22494018f,-.22494018f,0)),dot(x,float3(-.04205695f,1.04205695f,0)),dot(x,float3(-.01963755f,-.07863605f,1.09827360f))); }
float3 toP3from709(float3 x) { return float3(dot(x,float3(.82246197f,.17753803f,0)),dot(x,float3(.03319420f,.96680580f,0)),dot(x,float3(.01708263f,.07239741f,.91051996f))); }
float3 p3to2020(float3 x) { return float3(dot(x,float3(.753833f,.198597f,.047570f)),dot(x,float3(.045744f,.941777f,.012479f)),dot(x,float3(-.001210f,.017602f,.983608f))); }
float3 toP3from2020(float3 x) { return float3(dot(x,float3(1.3435783f,-.2821797f,-.0613986f)),dot(x,float3(-.0652975f,1.0757879f,-.0104905f)),dot(x,float3(.0028218f,-.0195985f,1.0167767f))); }
float3 p3toCine(float3 x) { return float3(dot(x,float3(.77815155f,.11728624f,.10456221f)),dot(x,float3(.07226832f,.75994794f,.16778375f)),dot(x,float3(.02346043f,.06084114f,.91569844f))); }
float3 cineToP3(float3 x) { return float3(dot(x,float3(1.30640907f,-.19250497f,-.11390411f)),dot(x,float3(-.11858463f,1.35294405f,-.23435942f)),dot(x,float3(-.02559149f,-.08496073f,1.11055222f))); }
// Same 8-decimal NPM as the Swift reference. Space 5 is S-Gamut3.Cine; 6 S-Gamut3;
// 7 V-Gamut; 8 F-Gamut (Rec.2020); 9 AWG3; 10 AWG4; 11 Cinema Gamut.
float3 p3toSG3(float3 x) { return float3(dot(x,float3(.67716998f,.22268083f,.10014919f)),dot(x,float3(.05823254f,.80559897f,.13616849f)),dot(x,float3(.00574488f,.03981469f,.95444043f))); }
float3 sg3ToP3(float3 x) { return float3(dot(x,float3(1.51312381f,-.41331979f,-.09980402f)),dot(x,float3(-.10860213f,1.27979248f,-.17119035f)),dot(x,float3(-.00457729f,-.05089900f,1.05547629f))); }
float3 p3toVG(float3 x) { return float3(dot(x,float3(.70145111f,.19732955f,.10121935f)),dot(x,float3(.05979648f,.82841649f,.11178703f)),dot(x,float3(.00617097f,.04603128f,.94779775f))); }
float3 vgToP3(float3 x) { return float3(dot(x,float3(1.45564245f,-.34032783f,-.11531462f)),dot(x,float3(-.10447649f,1.23951197f,-.13503547f)),dot(x,float3(-.00440341f,-.05798302f,1.06238642f))); }
float3 p3toFGamut(float3 x) { return float3(dot(x,float3(.75383303f,.19859737f,.04756960f)),dot(x,float3(.04574385f,.94177722f,.01247893f)),dot(x,float3(-.00121034f,.01760172f,.98360862f))); }
float3 fgamutToP3(float3 x) { return float3(dot(x,float3(1.34357825f,-.28217967f,-.06139858f)),dot(x,float3(-.06529745f,1.07578792f,-.01049046f)),dot(x,float3(.00282179f,-.01959849f,1.01677671f))); }
float3 p3toAWG3(float3 x) { return float3(dot(x,float3(.76001934f,.13248356f,.10749710f)),dot(x,float3(.00840830f,.80472802f,.18686368f)),dot(x,float3(-.00135534f,.08556969f,.91578565f))); }
float3 awg3ToP3(float3 x) { return float3(dot(x,float3(1.31782216f,-.20495324f,-.11286893f)),dot(x,float3(-.01453774f,1.27247685f,-.25793911f)),dot(x,float3(.00330873f,-.11920173f,1.11589300f))); }
float3 p3toAWG4(float3 x) { return float3(dot(x,float3(.67695999f,.21998630f,.10305371f)),dot(x,float3(.07251887f,.81542700f,.11205413f)),dot(x,float3(0.f,.04142423f,.95857577f))); }
float3 awg4ToP3(float3 x) { return float3(dot(x,float3(1.52050240f,-.40429866f,-.11620373f)),dot(x,float3(-.13603158f,1.26984798f,-.13381640f)),dot(x,float3(.00587852f,-.05487566f,1.04899714f))); }
float3 p3toCinema(float3 x) { return float3(dot(x,float3(.66516377f,.20889950f,.12593674f)),dot(x,float3(.06595013f,.75819764f,.17585223f)),dot(x,float3(.01650097f,.16958652f,.81391252f))); }
float3 cinemaToP3(float3 x) { return float3(dot(x,float3(1.54602980f,-.39137139f,-.15465841f)),dot(x,float3(-.13366788f,1.41972914f,-.28606126f)),dot(x,float3(-.00349265f,-.28787973f,1.29137238f))); }
float3 toLogPrimaries(float3 x,uint space) {
    if(space==5) return p3toCine(x);
    if(space==6) return p3toSG3(x);
    if(space==7) return p3toVG(x);
    if(space==8) return p3toFGamut(x);
    if(space==9) return p3toAWG3(x);
    if(space==10) return p3toAWG4(x);
    return p3toCinema(x);
}
float3 fromLogPrimaries(float3 x,uint space) {
    if(space==5) return cineToP3(x);
    if(space==6) return sg3ToP3(x);
    if(space==7) return vgToP3(x);
    if(space==8) return fgamutToP3(x);
    if(space==9) return awg3ToP3(x);
    if(space==10) return awg4ToP3(x);
    return cinemaToP3(x);
}
float pqEncode(float x) { float z=pow(clamp(x*.0203f,0.f,1.f),2610.f/16384); return pow((3424.f/4096+2413.f/128*z)/(1+2392.f/128*z),2523.f/32); }
float pqDecode(float x) { float z=pow(clamp(x,0.f,1.f),32.f/2523); return pow(max(z-3424.f/4096,0.f)/max(2413.f/128-2392.f/128*z,1e-6f),16384.f/2610)/.0203f; }
// Below each knee, including negatives, the white-paper linear segment is used.
float logEncode(float v,uint space) {
    if(space<=6) return v>=.01125f ? (420+261.5f*log10((v+.01f)/.19f))/1023 : (v*(171.2102946929f-95)/.01125f+95)/1023;
    if(space==7) return v<.01f ? 5.6f*v+.125f : .241514f*log10(v+.00873f)+.598206f;
    if(space==8) return v<.000889f ? 8.799461f*v+.092864f : .245281f*log10(5.555556f*v+.064829f)+.384316f;
    if(space==9) return v>.010591f ? .247190f*log10(5.555556f*v+.052272f)+.385537f : 5.367655f*v+.092809f;
    if(space==10) {
        float a=2231.826309067688f,b=.9071358748778103f,c=.09286412512218964f,s=.1135972086105891f,t=-.01805699611991131f;
        return v>=t ? (log2(a*v+64.f)-6.f)/14.f*b+c : (v-t)/s;
    }
    float x=v/.9f;
    if(x<-.014f) return -.36726845f*log10(-x*14.98325f+1.f)+.12783901f;
    if(x<=.014f) return 1.9754798f*x+.12512219f;
    return .36726845f*log10(x*14.98325f+1.f)+.12240537f;
}
float logDecode(float v,uint space) {
    if(space<=6) return v>=171.2102946929f/1023 ? pow(10.f,(v*1023-420)/261.5f)*.19f-.01f : (v*1023-95)*.01125f/(171.2102946929f-95);
    if(space==7) return v<.181f ? (v-.125f)/5.6f : pow(10.f,(v-.598206f)/.241514f)-.00873f;
    if(space==8) return v<.100686685370811f ? (v-.092864f)/8.799461f : (pow(10.f,(v-.384316f)/.245281f)-.064829f)/5.555556f;
    if(space==9) { float knee=5.367655f*.010591f+.092809f; return v>knee ? (pow(10.f,(v-.385537f)/.247190f)-.052272f)/5.555556f : (v-.092809f)/5.367655f; }
    if(space==10) {
        float a=2231.826309067688f,b=.9071358748778103f,c=.09286412512218964f,s=.1135972086105891f,t=-.01805699611991131f;
        return v>=0.f ? (pow(2.f,14.f*((v-c)/b)+6.f)-64.f)/a : v*s+t;
    }
    float x;
    if(v<.097465473f) x=-(pow(10.f,(.12783901f-v)/.36726845f)-1.f)/14.98325f;
    else if(v<=.15277891f) x=(v-.12512219f)/1.9754798f;
    else x=(pow(10.f,(v-.12240537f)/.36726845f)-1.f)/14.98325f;
    return x*.9f;
}
float3 lutEncode(float3 x,uint space) {
    if (space >= 5) x=toLogPrimaries(x,space);
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
        if(space>=5) x[c]=logEncode(v,space);
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
        if(space>=5) x[c]=logDecode(v,space);
        else if(space==4) x[c]=pqDecode(v);
        else if(space==2) x[c]=pow(max(v,0.f),2.4f);
        else x[c]=v<=.04045f ? v/12.92f : pow((v+.055f)/1.055f,2.4f);
    }
    if(space>=5) return fromLogPrimaries(x,space);
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
    changed=fit(changed,p.flags.y && p.lutInfo.w<=2 ? 1.f : max(1.f,maximum(changed)));
    return changed;
}
struct WorkingPair { float3 base; float3 gain; float alpha; };
// Light and colour in linear light; each look declares its own input transform.
float3 graphScene(float4 pixel,constant GraphUniform& p,texture3d<float,access::read> cube,device const float4* table,bool authoredBase=false) {
    float3 rgb=pixel.rgb;
    rgb=pointOp(rgb,5,p.tone1.y,p.flags.x==0);rgb=pointOp(rgb,6,p.tone1.z,p.flags.x==0);
    rgb=pointOp(rgb,0,p.tone0.x,p.flags.x==0 || authoredBase);rgb=pointOp(rgb,1,p.tone0.y,false);
    rgb=pointOp(rgb,2,p.tone0.z,false);rgb=pointOp(rgb,3,p.tone0.w,false);rgb=pointOp(rgb,4,p.tone1.x,false);
    rgb=pointOp(rgb,7,p.tone1.w,false);rgb=pointOp(rgb,8,p.color.x,false);
    // Log/film input retains signed wide-gamut scene values through its primary
    // transform. Fit only at the display/output boundary.
    bool logLook=p.flags.z && p.lutInfo.z>=5;
    if(!logLook && p.effects.w==0) rgb=fit(rgb,max(1.f,maximum(rgb))); // C2: fit at an upper bound >= Y, never remove HDR luminance.
    return rgb;
}
// `exposed`, when w is set, is the film exposure after the in-emulsion scatter.
WorkingPair preparePair(float4 pixel,float4 baseline,constant GraphUniform& p,texture3d<float,access::read> cube,device const float4* table,
                        const device FilmData& film,texture2d<float,access::read> filmLUT,int2 site,float3 glow=0,float4 exposed=0,
                        constant float4* grainKernel=nullptr) {
    float3 rgb=graphScene(pixel,p,cube,table);
    float3 neutralHDR=rgb;
    // Every look is evaluated at full strength, then mixed with a separately
    // rendered display-reference baseline. Never mix scene exposure with a print.
    if(p.flags.z) rgb=applyLUT(rgb,p,cube,table);
    float3 filmScene=rgb;
    rgb=fit(rgb,max(1.f,maximum(rgb)));
    float g=(p.flags.x!=0 || p.flags.z) ? log2(max(1.f,maximum(rgb))) : 0;
    float3 base=fit(rgb*exp2(-g),1.f);
    float3 stockDelta=0;
    bool independentStock=p.effects.w>0 && p.film.x<1 && (p.film.y>0 || p.halation.w>0);
    if(p.effects.w>0) {
        float3 raw=exposed.w>0 ? exposed.xyz : filmRaw(filmScene*p.film.w,film,filmLUT);
        float3 rawWithGlow=p.halation.w>0 ? (raw+p.halation.xyz*glow)/(1+p.halation.xyz) : raw;
        float3 completed=fit(filmFromRaw(rawWithGlow,film,p.film.yz,site,grainKernel),1.f);
        if(independentStock) {
            // The colour rendition has no grain/halation. The complete physical
            // stock delta is added after its colour crossfade, independently of t.
            base=fit(filmFromRaw(raw,film,float2(0,p.film.z),site,grainKernel),1.f);
            stockDelta=completed-base;
        } else base=completed; // t=1 preserves the legacy stock path exactly.
    }
    if(p.flags.y) {
        base=applyLUT(base,p,cube,table);
        if(p.lutInfo.w>2) {
            float3 hdr=base*exp2(g);
            g=log2(max(1.f,maximum(hdr)));
            base=fit(hdr*exp2(-g),1.f);
        }
    }
    float3 gain=g;
    float weight=(p.flags.y || p.flags.z) ? p.color.y : p.film.x;
    if(p.flags.x==3) {
        // An imported gain map already defines an SDR rendition. Re-splitting
        // its HDR maximum on the first nonzero edit destroys that rendition.
        // Edit both endpoints, then carry their RGB ratio (including blacks).
        float offset=p.pair.x;
        float3 neutralBase=fit(graphScene(baseline,p,cube,table,true),1.f);
        neutralHDR=fit(neutralHDR,max(1.f,maximum(neutralHDR)));
        float3 styledHDR=base*exp2(g);
        if(p.flags.y) {
            base=applyLUT(neutralBase,p,cube,table);
            styledHDR=max(float3(0),(base+offset)*(neutralHDR+offset)/(neutralBase+offset)-offset);
            if(p.lutInfo.w>2) base=fit(base/ max(1.f,maximum(base)),1.f);
        }
        float3 hdr=weight>0 ? mix(neutralHDR,styledHDR,weight) : neutralHDR;
        base=weight>0 ? mix(neutralBase,base,weight) : neutralBase;
        if(independentStock) {
            base=fit(base+stockDelta,1.f);
            hdr=max(hdr+stockDelta*exp2(g),0.f);
        }
        gain=log2((max(hdr,0.f)+offset)/(base+offset));
        return {base,gain,pixel.a};
    }
    float3 renderedHDR=base*exp2(g);
    if((weight>0 && weight<1) || (p.effects.w>0 && weight==0)) {
        float3 original=graphScene(baseline,p,cube,table);
        original=fit(original,max(1.f,maximum(original)));
        float oldGain=p.flags.x!=0 ? log2(max(1.f,maximum(original))) : 0;
        float3 oldBase=fit(original*exp2(-oldGain),1.f);
        float3 hdr=mix(oldBase*exp2(oldGain),base*exp2(g),weight);
        renderedHDR=hdr;
        base=mix(oldBase,base,weight);
        // The two endpoints can have different HDR ratios and colours. Retain
        // both the SDR and HDR crossfade exactly with per-channel gain. A single
        // gain would either move the SDR base or change the reconstructed hue.
        gain=g==oldGain ? float3(g) : select(log2(max(hdr/max(base,1e-30f),1e-30f)),float3(0),base==0);

    }
    if(independentStock) {
        base=fit(base+stockDelta,1.f);
        renderedHDR=max(renderedHDR+stockDelta*exp2(g),0.f);
        gain=log2((renderedHDR+p.pair.x)/(base+p.pair.x));
        return {base,gain,pixel.a};
    }
    if(p.pair.x>0) {
        // Independent effects edit both endpoints and can light a black channel.
        // Encode their common offset before the output-stage effect is applied.
        gain=log2((max(base*exp2(gain),0.f)+p.pair.x)/(base+p.pair.x));
    }
    return {base,gain,pixel.a};
}
float softPeak(float peak,float limit,bool gate) {
    if(!gate || peak<=1 || limit<=1) return peak;
    float knee=1+.75f*(limit-1), width=limit-knee;
    return peak<=knee ? peak : knee+width*(1-exp(-(peak-knee)/width));
}
// Neutral 35 mm grain uses Portra particle statistics without its colour transform.
// The same monochrome noise perturbs both endpoints; a smooth envelope protects black/white.
float3 effectEndpoint(float3 rgb,float3 glow,float noise,constant GraphUniform& p) {
    rgb=max(float3(0),rgb+p.effects.y*float3(.08f,.025f,.004f)*glow);
    if(p.effects.x>0) {
        float scale=max(1.f,maximum(rgb)), y=clamp(lum(rgb)/scale,0.f,1.f);
        rgb=max(float3(0),rgb+noise*(4*y*(1-y))*scale);
    }
    return rgb;
}
WorkingPair applyEffects(WorkingPair pair,float3 glow,int2 site,constant GraphUniform& p,
                         const device FilmData& film,constant float4* grainKernel) {
    if(p.effects.x==0 && p.effects.y==0) return pair;
    float noise=0;
    if(p.effects.x>0 && grainKernel!=nullptr) {
        float3 density=.5f*film.densityMaximum.xyz;
        float3 delta=filmGrain(density,film,float2(p.effects.x,p.effects.z),site,grainKernel)-density;
        noise=rawY(delta)*.5f;
    }
    float offset=p.pair.x;
    float3 hdr=(pair.base+offset)*exp2(pair.gain)-offset;
    pair.base=fit(effectEndpoint(pair.base,glow,noise,p),1.f);
    hdr=effectEndpoint(hdr,glow,noise,p);
    pair.gain=select(log2(max((hdr+offset)/max(pair.base+offset,1e-30f),1e-30f)),float3(0),pair.base+offset==0);
    return pair;
}
// Fixed-scale per-cell integrals. Every source pixel contributes; bright single
// pixels survive in the peak plane even when the analysis resolution is small.
kernel void graphCells(texture2d<float,access::read> src [[texture(0)]],
                       texture2d<float,access::write> stats [[texture(1)]],
                       texture2d<float,access::write> peaks [[texture(2)]],
                       texture3d<float,access::read> cube [[texture(3)]],
                       texture2d<float,access::write> masks [[texture(4)]],
                       texture2d<float,access::read> filmLUT [[texture(5)]],
                       texture2d<float,access::read> baseline [[texture(6)]],
                       constant GraphUniform& p [[buffer(0)]],device const float4* table [[buffer(1)]],
                       const device FilmData& film [[buffer(2)]],
                       uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=stats.get_width() || pos.y>=stats.get_height()) return;
    uint2 lo=pos*uint2(src.get_width(),src.get_height())/uint2(stats.get_width(),stats.get_height());
    uint2 hi=(pos+1)*uint2(src.get_width(),src.get_height())/uint2(stats.get_width(),stats.get_height());
    float4 sum=0,peak=0;
    for(uint y=lo.y;y<hi.y;y++)for(uint x=lo.x;x<hi.x;x++) {
        float4 original=src.read(uint2(x,y));
        auto v=preparePair(original,baseline.read(uint2(x,y)),p,cube,table,film,filmLUT,int2(x,y));
        float l=lum(v.base), request=sm(p.hdr.x,1.f,l), z=clamp(log2(l+1e-6f),-8.f,8.f);
        sum+=float4(l,request,z,z*z);
        float offset=p.pair.x;
        peak=max(peak,float4(maximum((v.base+offset)*exp2(v.gain)-offset),maximum(v.base),maximum(v.gain),maximum(original.rgb)));
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
// Film exposure over each analysis cell's exact footprint (pixels on its edges by the
// fraction they cover), for the halation map: its cells then sit where the render
// samples them.
kernel void graphFilmCells(texture2d<float,access::read> src [[texture(0)]],texture2d<float,access::write> dst [[texture(1)]],
                           texture3d<float,access::read> cube [[texture(2)]],texture2d<float,access::read> filmLUT [[texture(3)]],
                           constant GraphUniform& p [[buffer(0)]],device const float4* table [[buffer(1)]],
                           const device FilmData& film [[buffer(2)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=dst.get_width() || pos.y>=dst.get_height())return;
    float2 scale=float2(src.get_width(),src.get_height())/float2(dst.get_width(),dst.get_height());
    float2 lo=float2(pos)*scale,hi=float2(pos+1)*scale;
    int2 a=int2(floor(lo)),b=min(int2(ceil(hi)),int2(src.get_width(),src.get_height()));
    float3 sum=0;
    for(int y=a.y;y<b.y;y++) {
        float wy=min(hi.y,float(y+1))-max(lo.y,float(y));
        for(int x=a.x;x<b.x;x++) {
            float wx=min(hi.x,float(x+1))-max(lo.x,float(x));
            sum+=wx*wy*filmRaw(graphScene(src.read(uint2(x,y)),p,cube,table)*p.film.w,film,filmLUT);
        }
    }
    dst.write(float4(sum/(scale.x*scale.y),0),pos);
}
// Scene highlights (including captured HDR) drive the generic orange/red glow.
// Integrate exact cell footprints, with the same global grid as film halation.
kernel void graphEffectCells(texture2d<float,access::read> src [[texture(0)]],texture2d<float,access::write> dst [[texture(1)]],
                             texture3d<float,access::read> cube [[texture(2)]],constant GraphUniform& p [[buffer(0)]],
                             device const float4* table [[buffer(1)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=dst.get_width() || pos.y>=dst.get_height())return;
    float2 scale=float2(src.get_width(),src.get_height())/float2(dst.get_width(),dst.get_height());
    float2 lo=float2(pos)*scale,hi=float2(pos+1)*scale;
    int2 a=int2(floor(lo)),b=min(int2(ceil(hi)),int2(src.get_width(),src.get_height()));
    float value=0;
    for(int y=a.y;y<b.y;y++)for(int x=a.x;x<b.x;x++) {
        float weight=(min(hi.y,float(y+1))-max(lo.y,float(y)))*(min(hi.x,float(x+1))-max(lo.x,float(x)));
        float highlight=max(0.f,lum(graphScene(src.read(uint2(x,y)),p,cube,table))-.7f);
        value+=weight*highlight;
    }
    dst.write(float4(float3(value/(scale.x*scale.y)),0),pos);
}
// Film exposure of a render's pixels from p.region.zw on (a region and its halo), for
// the in-emulsion scatter.
kernel void graphFilmExposure(texture2d<float,access::sample> src [[texture(0)]],texture2d<float,access::write> dst [[texture(1)]],
                              texture3d<float,access::read> cube [[texture(2)]],texture2d<float,access::read> filmLUT [[texture(3)]],
                              constant GraphUniform& p [[buffer(0)]],device const float4* table [[buffer(1)]],
                              const device FilmData& film [[buffer(2)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=dst.get_width() || pos.y>=dst.get_height())return;
    float3 rgb=graphScene(sourceSample(src,float2(pos+p.region.zw)+.5f,float2(p.region.xy),p.inputRegion),p,cube,table);
    dst.write(float4(filmRaw(rgb*p.film.w,film,filmLUT),0),pos);
}
// Expansion/model values describe zero-offset HDR = base * 2^stops, rather
// than the encoded paired curve. Convert that target before combining gains.
float3 expansionGain(float3 base,float stops,float offset) {
    if(offset==0) return float3(stops);
    return log2((base*exp2(stops)+offset)/(base+offset));
}
float3 scaleEndpointGain(float3 base,float3 gain,float strength,float offset,uint domain) {
    if(offset==0 || domain==3 || strength==1) return gain*strength;
    float3 hdr=max((base+offset)*exp2(gain)-offset,0.f);
    float3 paired=max((base+offset)*exp2(gain*strength)-offset,0.f);
    float3 plain=base*exp2(log2(max(hdr/max(base,1e-30f),1e-30f))*strength);
    // Newly lit black channels need the paired curve; positive channels retain
    // the original zero-offset strength semantics as an effect tends to zero.
    hdr=select(paired,plain,base>0);
    return log2((hdr+offset)/(base+offset));
}
kernel void graphOutput(texture2d<float,access::sample> src [[texture(0)]],texture2d<float,access::write> base [[texture(1)]],
                        texture2d<float,access::write> gain [[texture(2)]],texture3d<float,access::read> cube [[texture(3)]],
                        texture2d<float,access::sample> expansion [[texture(4)]],texture2d<float,access::sample> model [[texture(5)]],
                        texture2d<float,access::read> filmLUT [[texture(6)]],
                        texture2d<float,access::sample> halation [[texture(7)]],
                        texture2d<float,access::read> scattered [[texture(8)]],
                        texture2d<float,access::sample> baseline [[texture(9)]],
                        constant GraphUniform& p [[buffer(0)]],
                        device const float4* table [[buffer(1)]],const device FilmData& film [[buffer(2)]],
                        constant float4* grainKernel [[buffer(3)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=base.get_width() || pos.y>=base.get_height())return;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 uv=(float2(pos+p.region.zw)+.5f)/float2(p.region.xy);
    auto pair=preparePair(sourceSample(src,float2(pos+p.region.zw)+.5f,float2(p.region.xy),p.inputRegion),
                         sourceSample(baseline,float2(pos+p.region.zw)+.5f,float2(p.region.xy),p.inputRegion),p,cube,table,film,filmLUT,int2(pos+p.region.zw),
                         p.halation.w>0 ? filmSmooth(halation,uv) : float3(0),
                         p.scatter.z ? float4(scattered.read(uint2(int2(pos)+p.scatter.xy)).rgb,1) : float4(0),grainKernel);
    pair=applyEffects(pair,p.effects.y>0 ? filmSmooth(halation,uv) : float3(0),int2(pos+p.region.zw),p,film,grainKernel);
    float3 g=pair.gain;
    float offset=p.pair.x;
    if(p.mode.x)g=max(g,expansionGain(pair.base,expansion.sample(s,uv).x*p.color.z/3,offset));
    if(p.mode.y)g=max(g,expansionGain(pair.base,model.sample(s,uv).x,offset));
    g=scaleEndpointGain(pair.base,g,p.color.w,offset,p.flags.x);
    float3 hdr=(pair.base+offset)*exp2(g)-offset;
    float limit=exp2(p.color.z);
    float peak=maximum(hdr), mapped=softPeak(peak,limit,p.hdr.w!=0);
    bool physical=p.effects.x>0 || p.effects.y>0;
    // A newly enabled generic effect must not trigger the shoulder below its
    // legal ceiling. Cap only its actual overflow, continuously at that ceiling.
    if(!p.hdr.w && physical && peak>limit) mapped=limit;
    if(peak>0 && mapped!=peak) {
        if(offset>0)g=log2((max(hdr*(mapped/peak),0.f)+offset)/(pair.base+offset));
        else g+=log2(max(mapped/peak,1e-30f));
    }
    if(p.hdr.z>0 && p.flags.x!=0 && p.flags.x!=3) {
        float m=maximum(pair.base);
        if(m>.7f) {
            float target=mix(m,.7f+.3f*(1-exp(-(m-.7f)/.3f)),p.hdr.z);
            if(offset>0) {
                float3 rendition=(pair.base+offset)*exp2(g)-offset;
                pair.base*=target/m;
                g=log2((max(rendition,0.f)+offset)/(pair.base+offset));
            } else { pair.base*=target/m;g+=log2(m/target); }
        }
    }
    if(!p.flags.w)g=0;
    base.write(float4(pair.base,pair.alpha),pos);gain.write(float4(g,0),pos);
}
struct AuthorUniform { float4 minimum,maximum,inverseGamma,baseOffset,alternateOffset,controls;uint4 info;float4 inputRegion,gainRegion; };
float3 isoLogRatio(float3 numerator,float3 denominator) {
    // Zero over zero is an unlit channel: choose zero stops, as in the double reference.
    return select(log2(max(numerator/max(denominator,1e-30f),1e-30f)),float3(0),denominator==0);
}
kernel void authoredOutput(texture2d<float,access::sample> baseWorking [[texture(0)]],texture2d<float,access::sample> encoded [[texture(1)]],
                           texture2d<float,access::sample> systemHDR [[texture(2)]],texture2d<float,access::write> output [[texture(3)]],
                           constant AuthorUniform& p [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float3 b=(p.info.y&4) ? baseWorking.read(pos).rgb
        : sourceSample(baseWorking,float2(pos+uint2(p.info.z,p.info.w))+.5f,p.controls.zw,p.inputRegion).rgb;
    float3 oB=p.baseOffset.xyz,oA=p.alternateOffset.xyz;
    float3 g;
    if(p.info.y&1) {
        float3 v=sourceSample(encoded,float2(pos+uint2(p.info.z,p.info.w))+.5f,p.controls.zw,p.gainRegion).rgb;if(p.info.x==1)v=v.rrr;
        g=p.minimum.xyz+(p.maximum.xyz-p.minimum.xyz)*pow(clamp(v,0.f,1.f),p.inverseGamma.xyz);
    } else {
        // Legacy Apple: exact per-channel ISO inversion, never a luminance ratio.
        g=isoLogRatio(sourceSample(systemHDR,float2(pos+uint2(p.info.z,p.info.w))+.5f,p.controls.zw,p.inputRegion).rgb+oA,b+oB);
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

// Model grid is raw log2, unsmoothed. Auto start retains the prediction; an
// explicit expansion start gates it using the untouched SDR guide luminance.
kernel void modelGainWeights(texture2d<float,access::read> cells [[texture(0)]],
                             texture2d<float,access::sample> model [[texture(1)]],
                             texture2d<float,access::write> output [[texture(2)]],
                             constant float& start [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float y=cells.read(pos).x;
    float g=max(0.f,model.sample(s,(float2(pos)+.5f)/float2(output.get_width(),output.get_height())).x);
    if(start>=0)g*=sm(.75f*start,max(.001f,min(1.f,1.1f*start)),y);
    output.write(float4(y,g,y*y,y*g),pos);
}

kernel void effectMask(texture2d<float,access::sample> source [[texture(0)]],
                       texture2d<float,access::write> output [[texture(1)]],
                       texture2d<float,access::sample> gain [[texture(2)]],
                       texture2d<float,access::sample> originalGuide [[texture(3)]],
                       constant GraphUniform& p [[buffer(0)]],
                       uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 uv=(float2(pos+p.region.zw)+.5f)/float2(p.region.xy);
    float4 original=sourceSample(source,float2(pos+p.region.zw)+.5f,float2(p.region.xy),p.inputRegion);float weight=0;
    if(p.mode.z) { output.write(float4(0),pos);return; }
    if(p.mode.x<3) {
        float3 rgb=pointOp(original.rgb,5,p.tone1.y,p.flags.x==0);
        rgb=pointOp(rgb,6,p.tone1.z,p.flags.x==0);
        rgb=pointOp(rgb,0,p.tone0.x,p.flags.x==0);rgb=pointOp(rgb,1,p.tone0.y,false);
        if(p.mode.x>0)rgb=pointOp(rgb,2,p.tone0.z,false);
        if(p.mode.x>1)rgb=pointOp(rgb,3,p.tone0.w,false);
        float y=lum(rgb);
        weight=p.mode.x==0 ? sm(.4f,1.f,y) : p.mode.x==1 ? 1-sm(0.f,.5f,y) : 1-sm(0.f,.1f,y);
    } else if(p.mode.x<5) {
        float4 guide=originalGuide.sample(s,uv);
        if(p.mode.w)weight=p.mode.w==1 ? 1.f : sm(.75f*p.hdr.x,max(.001f,min(1.f,1.1f*p.hdr.x)),guide.x);
        else weight=guide.y;
    } else {
        // Normalized display gain is local to this ROI (or a whole native map).
        float3 g=gain.sample(s,(float2(pos)+.5f)/float2(output.get_width(),output.get_height())).rgb;
        float amount=p.mode.y==1 ? g.r : max(g.r,max(g.g,g.b));
        weight=p.mode.x==5 ? clamp(amount/p.color.z,0.f,1.f) : (amount>1e-6f ? 1.f : 0.f);
    }
    output.write(float4(weight,0,0,0),pos);
}
