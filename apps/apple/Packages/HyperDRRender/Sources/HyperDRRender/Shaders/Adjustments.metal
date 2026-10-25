// Shared point operators, used by individual nodes and the fused full graph.
float maximum(float3 x) { return max(x.r, max(x.g, x.b)); }
float rawY(float3 x) { return dot(x, float3(.2289746f,.6917385f,.0792869f)); }
float contrastY(float y, float c) {
    if (c == 1 || y >= 1 || y <= 0) return y;
    // Shape perceptual lightness, keeping black, middle gray and white fixed.
    // Both pieces share the gray slope; the white slope is exactly one.
    float x = pow(y, 1.f / 2.4f), pivot = pow(.18f, 1.f / 2.4f);
    float a = log(c) / log(1.6f), k = a * (a > 0 ? 1.6f : .8f);
    float target;
    if (x <= pivot) {
        float t = x / pivot;
        target = pivot * (t - k*t*t*t*(1-t));
    } else {
        float t = (x-pivot)/(1-pivot);
        target = pivot + (1-pivot)*(t + k*t*(1-t)*(1-t));
    }
    return pow(target, 2.4f);
}
float3 colorLab(float3 rgb) {
    float l=cb(dot(rgb,float3(.4813272912f,.4620679117f,.0564956029f)));
    float m=cb(dot(rgb,float3(.2288381013f,.6532343999f,.1179544132f)));
    float s=cb(dot(rgb,float3(.0839860178f,.2242727893f,.6922208389f)));
    return float3(.2104542553f*l+.7936177850f*m-.0040720468f*s,
                  1.9779984951f*l-2.4285922050f*m+.4505937099f*s,
                  .0259040371f*l+.7827717662f*m-.8086757660f*s);
}
float3 colorPreserveY(float3 rgb,float target) {
    float y=lum(rgb); return y>1e-8f ? rgb*(target/y) : float3(target);
}
float3 colorVibrance(float3 rgb,float amount) {
    if(amount==0) return rgb;
    float y=lum(rgb),scale=max(1.f,y);
    float3 lab=colorLab(rgb/scale);
    float relative=length(lab.yz)/max(.001f,lab.x),hue=atan2(lab.z,lab.y)*180.f/M_PI_F;
    if(hue<0) hue+=360.f;
    float skin=sm(20.f,30.f,hue)*(1-sm(75.f,90.f,hue))*(1-sm(.3f,.5f,relative));
    float weight=(amount>0 ? 1-sm(.08f,.45f,relative) : .25f+.75f*sm(.08f,.45f,relative))*(1-2*skin/3);
    lab.yz*=1+amount*weight*(amount>0 ? 1.2f : .65f);
    return colorPreserveY(labToRGB(lab.x,lab.y,lab.z),y);
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
    if (op == 7) return colorVibrance(rgb,amount);
    if (op == 8) {
        float3 chroma = rgb - y;
        float factor = 1+a;
        return y + chroma * factor;
    }
    if (op == 1) target = contrastY(y,amount);
    if (op == 2) {
        if (y > 1) {
            float left=a<0 ? 1.f : exp2(-3*a), right=exp2(2*a), x=y-1, t=min(x,1.f);
            // Integrate a smoothstep of the slope over the first stop above white.
            // Beyond it the old HDR slope resumes with a constant offset.
            target=1+right*x+(left-right)*(t-t*t*t+.5f*t*t*t*t);
        }
        else if (y > .15f) {
            float t = (y-.15f)/.85f;
            target = .15f + .85f*t/(t+(1-t)*exp2(-3*a*t));
            if(a<0) target=mix(target,y,sm(.8f,1.f,y));
        }
    }
    if (op == 3 && y < .5f) { float t=y/.5f; target=.5f*(t+.8f*a*t*(1-t)*(1-t)); }
    // Whites deliberately crosses SDR white; the gain split retains that light.
    // This replaces the original plan's concern that a white-point control clips HDR.
    if (op == 9 && y > 0) target = y*exp2(2.f*a*y/(y+.5f));
    if (op == 4 && y < .5f) {
        float encoded = (y<=.0031308f ? 12.92f*max(0.f,y) : 1.055f*pow(y,1.f/2.4f)-.055f);
        float changed = a > 0 ? max(0.f,encoded-.1f*a*(1-sm(.1f,.5f,encoded)))
                              : encoded-.12f*a*(1-sm(0.f,.5f,encoded));
        target = (changed<=.04045f ? changed/12.92f : pow((changed+.055f)/1.055f,2.4f));
        if(a<0) return rgb+(target-y);
    }
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

struct ColorToolsUniform { float4 band0, band1, band2, band3, band4, band5, band6, band7; float4 grade0,grade1,grade2,grade3,gradeOptions; };
struct GraphUniform {
    float4 tone0, tone1, color, hdr;
    uint4 flags, lutInfo;
    float4 lutMin, lutMax;
    uint4 region, mode;
    float4 inputRegion;
    float4 film; // strength (0: no film), grain amount, 1/pixel area (µm⁻²), exposure factor
    float4 halation; // per-channel strength, w: the render samples a halation map
    int4 scatter; // xy: the region's offset in the scattered film exposure, z: the render reads it
    float4 pair; // x: target-pair offset, y: AI model reconstruction offset
    float4 effects; // generic grain, halation, inverse 35 mm pixel area, stock processing
    float4 light; // whites, curve table offset, curve table size
    float4 curveHDRTails;
    float4 lutExposure; // scene multiplier before Log encoding
    ColorToolsUniform colorTools;
    uint4 toneSpatialInfo;
    float4 toneSpatialSettings,toneAtmosphere;
    float4 toneBaselineAtmosphere;
};
// Smooth neighbouring memberships in OKLCH; equal weights to the Swift reference.
void hslWeights(float3 rgb, thread float* weights) {
    float3 lab=colorLab(rgb/max(1.f,lum(rgb)));
    float fade=sm(.015f,.06f,length(lab.yz)/max(.001f,lab.x));
    float hue=atan2(lab.z,lab.y)*180.f/M_PI_F;
    if(hue<25) hue+=360.f;
    const float centers[9]={25,55,95,145,195,265,305,335,385};
    for(uint i=0;i<8;i++) weights[i]=0;
    for(uint i=0;i<8;i++) if(hue>=centers[i] && hue<centers[i+1]) {
        float t=sm(centers[i],centers[i+1],hue);
        weights[i]=(1-t)*fade;weights[(i+1)%8]=t*fade;
    }
}
float3 colorMixer(float3 rgb,constant ColorToolsUniform& p) {
    const float3 bands[8]={p.band0.xyz,p.band1.xyz,p.band2.xyz,p.band3.xyz,p.band4.xyz,p.band5.xyz,p.band6.xyz,p.band7.xyz};
    bool active=false;for(uint i=0;i<8;i++) active=active || any(bands[i]!=0.f);
    if(!active) return rgb;
    float weights[8];hslWeights(rgb,weights);
    float3 delta=0;for(uint i=0;i<8;i++) delta+=bands[i]*weights[i];
    if(all(delta==0.f)) return rgb;
    float y=lum(rgb);float3 lab=colorLab(rgb/max(1.f,y));
    float hue=atan2(lab.z,lab.y)+delta.x*M_PI_F/6.f;
    float chroma=length(lab.yz)*max(0.f,1+delta.y);
    lab.yz=chroma*float2(cos(hue),sin(hue));
    return colorPreserveY(labToRGB(lab.x,lab.y,lab.z),y*exp2(delta.z));
}
float3 colorGrade(float3 rgb,constant ColorToolsUniform& p) {
    const float3 wheels[4]={p.grade0.xyz,p.grade1.xyz,p.grade2.xyz,p.grade3.xyz};
    bool active=false;for(uint i=0;i<4;i++) active=active || wheels[i].y!=0 || wheels[i].z!=0;
    if(!active) return rgb;
    float y=lum(rgb);float3 lab=colorLab(rgb/max(1.f,y));
    float position=clamp(min(1.f,cb(y))+p.gradeOptions.y*.2f,0.f,1.f),width=.08f+.22f*p.gradeOptions.x;
    float shadows=1-sm(.35f-width,.35f+width,position),highlights=sm(.75f-width,.75f+width,position);
    const float weights[4]={shadows,1-shadows-highlights,highlights,1};
    float2 offset=0;float light=0;
    for(uint i=0;i<4;i++) {
        float hue=wheels[i].x*M_PI_F/180.f,chroma=.18f*wheels[i].y*weights[i]*lab.x;
        offset+=chroma*float2(cos(hue),sin(hue));light+=wheels[i].z*weights[i];
    }
    lab.yz+=offset;
    return colorPreserveY(labToRGB(lab.x,lab.y,lab.z),y*exp2(light));
}
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

// Manufacturer xy NPMs; AP1 D60 -> D65 uses Bradford.
float3 toFGamutC(float3 x) { return float3(dot(x,float3(0.61463729f,0.30848762f,0.07687509f)),dot(x,float3(0.07251020f,0.81533444f,0.11215536f)),dot(x,float3(-0.00000000f,0.04142423f,0.95857577f))); }
float3 fromFGamutC(float3 x) { return float3(dot(x,float3(1.70260384f,-0.64106582f,-0.06153802f)),dot(x,float3(-0.15232327f,1.29117787f,-0.13885460f)),dot(x,float3(0.00658255f,-0.05579742f,1.04921487f))); }
float3 toDGamut(float3 x) { return float3(dot(x,float3(0.74092272f,0.15138586f,0.10769142f)),dot(x,float3(0.02527437f,0.80940408f,0.16532156f)),dot(x,float3(0.01312916f,0.09676215f,0.89010869f))); }
float3 fromDGamut(float3 x) { return float3(dot(x,float3(1.35998174f,-0.24002153f,-0.11996021f)),dot(x,float3(-0.03924070f,1.27045756f,-0.23121686f)),dot(x,float3(-0.01579403f,-0.13456887f,1.15036290f))); }
float3 toDWG(float3 x) { return float3(dot(x,float3(0.67351724f,0.20159153f,0.12489123f)),dot(x,float3(0.06032906f,0.75003422f,0.18963673f)),dot(x,float3(0.05654380f,0.12707417f,0.81638203f))); }
float3 fromDWG(float3 x) { return float3(dot(x,float3(1.53154371f,-0.38718496f,-0.14435875f)),dot(x,float3(-0.10031767f,1.41325474f,-0.31293708f)),dot(x,float3(-0.09046195f,-0.19316357f,1.28362552f))); }
float3 toAP1(float3 x) { return float3(dot(x,float3(0.73579791f,0.21216649f,0.05203560f)),dot(x,float3(0.04717988f,0.93804570f,0.01477441f)),dot(x,float3(0.00356366f,0.04114189f,0.95529445f))); }
float3 fromAP1(float3 x) { return float3(dot(x,float3(1.37921413f,-0.30886414f,-0.07034998f)),dot(x,float3(-0.06933486f,1.08229675f,-0.01296189f)),dot(x,float3(-0.00215901f,-0.04545932f,1.04761833f))); }

float3 toLogPrimaries(float3 x,uint space) {
    if(space==12 || space==14 || space==15) return p3toFGamut(x);
    if(space==13) return toFGamutC(x);
    if(space==16) return toDGamut(x);
    if(space==18) return toDWG(x);
    if(space==19) return toAP1(x);
    if(space==5) return p3toCine(x);
    if(space==6) return p3toSG3(x);
    if(space==7) return p3toVG(x);
    if(space==8) return p3toFGamut(x);
    if(space==9) return p3toAWG3(x);
    if(space==10) return p3toAWG4(x);
    return p3toCinema(x);
}
float3 fromLogPrimaries(float3 x,uint space) {
    if(space==12 || space==14 || space==15) return fgamutToP3(x);
    if(space==13) return fromFGamutC(x);
    if(space==16) return fromDGamut(x);
    if(space==18) return fromDWG(x);
    if(space==19) return fromAP1(x);
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
    if(space==12) return v < 0.00089f ? 8.735631f*v+0.092864f : 0.344676f*log10(0.555556f*v+0.009468f)+0.790453f;
    if(space==14) return v >= 0.01f ? 0.08550479f*log2(v+0.00964052f)+0.69336945f : 47.28711236f*pow(max(0.f,v+0.05641088f),2.f);
    if(space==15) return v < 0.328f ? 650.f*(sign(v+0.0075f)*pow(abs(v+0.0075f),1.f/3.f))/1023.f : (150.f*log(v)+619.f)/1023.f;
    if(space==16) return v <= 0.0078f ? 6.025f*v+0.0929f : 0.256663f*log10(0.9892f*v+0.0108f)+0.584555f;
    if(space==17) return 0.092864125f + (v < 0.f ? -1.f : 1.f)*0.24136077f*log10(1.f+87.099375f*abs(v)/0.9f);
    if(space==18) return v <= 0.00262409f ? v*10.44426855f : (log2(v+0.0075f)+7.f)*0.07329248f;
    if(space==19) return v <= 0.0078125f ? 10.5402377416545f*v+0.0729055341958355f : (log2(v)+9.72f)/17.52f;

    if(space<=6) return v>=.01125f ? (420+261.5f*log10((v+.01f)/.19f))/1023 : (v*(171.2102946929f-95)/.01125f+95)/1023;
    if(space==7) return v<.01f ? 5.6f*v+.125f : .241514f*log10(v+.00873f)+.598206f;
    if(space==8 || space==13) return v<.000889f ? 8.799461f*v+.092864f : .245281f*log10(5.555556f*v+.064829f)+.384316f;
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
    if(space==12) return v < 0.100537775223865f ? (v-0.092864f)/8.735631f : (pow(10.f,(v-0.790453f)/0.344676f)-0.009468f)/0.555556f;
    if(space==14) return v >= 47.28711236f*pow(0.06641088f,2.f) ? exp2((v-0.69336945f)/0.08550479f)-0.00964052f : sqrt(max(0.f,v)/47.28711236f)-0.05641088f;
    if(space==15) return v*1023.f < 452.f ? ((v*1023.f/650.f)*(v*1023.f/650.f)*(v*1023.f/650.f))-0.0075f : exp((v*1023.f-619.f)/150.f);
    if(space==16) return v <= 0.14f ? (v-0.0929f)/6.025f : (pow(10.f,(v-0.584555f)/0.256663f)-0.0108f)/0.9892f;
    if(space==17) return (v < 0.092864125f ? -1.f : 1.f)*(pow(10.f,abs(v-0.092864125f)/0.24136077f)-1.f)/87.099375f*0.9f;
    if(space==18) return v <= 0.02740668f ? v/10.44426855f : exp2(v/0.07329248f-7.f)-0.0075f;
    if(space==19) return v <= 0.155251141552511f ? (v-0.0729055341958355f)/10.5402377416545f : exp2(v*17.52f-9.72f);

    if(space<=6) return v>=171.2102946929f/1023 ? pow(10.f,(v*1023-420)/261.5f)*.19f-.01f : (v*1023-95)*.01125f/(171.2102946929f-95);
    if(space==7) return v<.181f ? (v-.125f)/5.6f : pow(10.f,(v-.598206f)/.241514f)-.00873f;
    if(space==8 || space==13) return v<.100686685370811f ? (v-.092864f)/8.799461f : (pow(10.f,(v-.384316f)/.245281f)-.064829f)/5.555556f;
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
    if (space >= 5 && space != 20) x=toLogPrimaries(x,space);
    else if (space == 20) x=p3toFGamut(x);
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
        if(space>=5 && space!=20) x[c]=logEncode(v,space);
        else if(space==4) x[c]=pqEncode(v);
        else if(space==2 || space==20) x[c]=pow(max(v,0.f),1.f/2.4f);
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
        if(space>=5 && space!=20) x[c]=logDecode(v,space);
        else if(space==4) x[c]=pqDecode(v);
        else if(space==2 || space==20) x[c]=pow(max(v,0.f),2.4f);
        else x[c]=v<=.04045f ? v/12.92f : pow((v+.055f)/1.055f,2.4f);
    }
    if(space>=5 && space!=20) return fromLogPrimaries(x,space);
    if(space==20) return fgamutToP3(x);
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
    float3 changed=lutDecode(lutSample(lutEncode(rgb*p.lutExposure.x,p.lutInfo.z),p,cube,table),p.lutInfo.w);
    changed=fit(changed,p.flags.y && (p.lutInfo.w<=2 || p.lutInfo.w==20) ? 1.f : max(1.f,maximum(changed)));
    return changed;
}
struct WorkingPair { float3 base; float3 gain; float alpha; };
float curveEncode(float y) { return y<=.0031308f ? 12.92f*y : 1.055f*pow(y,1.f/2.4f)-.055f; }
float curveDecode(float x) { return x<=.04045f ? x/12.92f : pow((x+.055f)/1.055f,2.4f); }
float curveLookup(float x,uint slot,constant GraphUniform& p,device const float4* table) {
    float position=clamp(x,0.f,1.f)*1023.f;
    uint i=min(uint(position),1022u), offset=uint(p.light.y)+slot*1024;
    return mix(table[offset+i].x,table[offset+i+1].x,position-float(i));
}
float3 applyToneCurve(float3 rgb, constant GraphUniform& p, device const float4* table) {
    if(p.light.z==0) return rgb;
    float y=lum(rgb);
    if(y>0 && y<1)rgb*=curveDecode(curveLookup(curveEncode(y),0,p,table))/y;
    for(uint c=0;c<3;c++)if(rgb[c]>0 && rgb[c]<1)
        rgb[c]=curveDecode(curveLookup(curveEncode(rgb[c]),3+c,p,table));
    return rgb;
}
float3 isoLogRatio(float3 numerator,float3 denominator);
float3 endpointCurve(float3 rgb,uint slot,bool sdr,constant GraphUniform& p,device const float4* table) {
    float y=lum(rgb);
    if(y<=0 || (y<=1 && !sdr))return rgb;
    float x=y>1 ? 1+log2(y) : curveEncode(y), mapped;
    if(x>1) {
        float bounded=min(x,5.f);
        float2 tail=slot==0 ? p.curveHDRTails.xy : p.curveHDRTails.zw;
        mapped=x>=tail.x ? tail.y+(x-tail.x) : curveLookup((bounded-1)/4,slot==0 ? 6 : 7,p,table);
        mapped=exp2(max(1.f,mapped)-1);
    } else mapped=curveDecode(max(x,curveLookup(x,slot,p,table)));
    return rgb*(mapped/y);
}
float4 toneSpatialSample(float2 uv,constant GraphUniform& p,device const float4* table) {
    float2 position=clamp(uv*float2(p.toneSpatialInfo.xy)-.5f,0.f,float2(p.toneSpatialInfo.xy)-1);
    uint2 a=uint2(position),b=min(a+1,p.toneSpatialInfo.xy-1);
    float2 t=position-float2(a);uint w=p.toneSpatialInfo.x,o=p.toneSpatialInfo.z;
    return mix(mix(table[o+a.y*w+a.x],table[o+a.y*w+b.x],t.x),
               mix(table[o+b.y*w+a.x],table[o+b.y*w+b.x],t.x),t.y);
}
float3 spatialDehaze(float3 rgb,float3 air,float transmission,float amount) {
    if(amount==0)return rgb;
    if(amount<0)return mix(rgb,air,-amount*.45f);
    float y=lum(rgb),a=lum(air);if(y<=0)return rgb;
    // Near-air white objects/sky have an unreliable dark-channel estimate.
    float t=max(max(.2f,transmission),min(1.f,.3f/max(.001f,abs(y-a))));
    float recovered=(y-a)/t+a;
    // Bound luminance and recover modest original chroma, without subtracting
    // atmospheric RGB (which would introduce coloured edge fringes).
    float ratio=clamp(recovered/y,.6f,1.3f);
    float minimum=min(rgb.x,min(rgb.y,rgb.z));
    float chromaLimit=y/max(1e-6f,y-minimum);
    float chroma=min(max(1.f,chromaLimit),1+min(.3f,.3f*(1/t-1))*amount);
    return (y+(rgb-y)*chroma)*(1+(ratio-1)*amount);
}
float3 spatialClarity(float3 rgb,float low,float amount) {
    float y=lum(rgb);if(amount==0 || y<=0)return rgb;
    float weight=sm(.01f,.1f,y)*(1-sm(.8f,2.f,y));
    return rgb*exp2(.8f*amount*weight*(log2(y+1e-4f)-low));
}
// Light and colour in linear light; each look declares its own input transform.
float3 graphScene(float4 pixel,constant GraphUniform& p,texture3d<float,access::read> cube,device const float4* table,bool authoredBase=false,bool whites=true,float2 uv=float2(.5f),bool spatialEnabled=true,bool beforeMixer=false,bool baselineGuide=false) {
    float3 rgb=pixel.rgb;
    rgb=pointOp(rgb,5,p.tone1.y,p.flags.x==0);rgb=pointOp(rgb,6,p.tone1.z,p.flags.x==0);
    rgb=pointOp(rgb,0,p.tone0.x,p.flags.x==0 || authoredBase);
    float4 spatial=p.toneSpatialInfo.w ? toneSpatialSample(uv,p,table) : float4(1,0,0,0);
    bool baseGuide=authoredBase || baselineGuide;
    if(p.toneSpatialInfo.w && spatialEnabled)rgb=spatialDehaze(rgb,baseGuide ? p.toneBaselineAtmosphere.xyz : p.toneAtmosphere.xyz,baseGuide ? spatial.w : spatial.x,p.toneSpatialSettings.x);
    rgb=pointOp(rgb,1,p.tone0.y,false);
    rgb=pointOp(rgb,2,p.tone0.z,false);rgb=pointOp(rgb,3,p.tone0.w,false);rgb=pointOp(rgb,9,whites ? p.light.x : 0.f,false);rgb=pointOp(rgb,4,p.tone1.x,false);
    if(p.toneSpatialInfo.w && spatialEnabled)rgb=spatialClarity(rgb,baseGuide ? spatial.z : spatial.y,p.toneSpatialSettings.y);
    if(p.light.w==1)return rgb;
    if(p.light.w==2) {
        float y=lum(rgb);
        return p.light.z!=0 && y>0 && y<1 ? rgb*curveDecode(curveLookup(curveEncode(y),0,p,table))/y : rgb;
    }
    rgb=applyToneCurve(rgb,p,table);
    rgb=pointOp(rgb,7,p.tone1.w,false);rgb=pointOp(rgb,8,p.color.x,false);
    if(beforeMixer) return rgb;
    rgb=colorMixer(rgb,p.colorTools);
    rgb=colorGrade(rgb,p.colorTools);
    // Log/film input retains signed wide-gamut scene values through its primary
    // transform. Fit only at the display/output boundary.
    bool logLook=p.flags.z && p.lutInfo.z>=5 && p.lutInfo.z!=20;
    if(!logLook && p.effects.w==0) rgb=fit(rgb,max(1.f,maximum(rgb))); // C2: fit at an upper bound >= Y, never remove HDR luminance.
    return rgb;
}
// Keep pre-existing SDR colour overflow in the SDR fit. Only the increase
// relative to the same edit without Whites becomes newly generated gain.
float sdrWhitesGain(float3 rgb,float4 pixel,constant GraphUniform& p,texture3d<float,access::read> cube,
                    device const float4* table,float2 uv) {
    if(p.light.x<=0 && p.toneSpatialSettings.x==0 && p.toneSpatialSettings.y==0) return 0;
    float3 original=graphScene(pixel,p,cube,table,false,false,uv,false);
    original=fit(original,max(1.f,maximum(original)));
    return max(0.f,log2(max(1.f,maximum(rgb))/max(1.f,maximum(original))));
}
// `exposed`, when w is set, is the film exposure after the in-emulsion scatter.
WorkingPair preparePair(float4 pixel,float4 baseline,constant GraphUniform& p,texture3d<float,access::read> cube,device const float4* table,
                        const device FilmData& film,texture2d<float,access::read> filmLUT,int2 site,float3 glow=0,float4 exposed=0,
                        constant float4* grainKernel=nullptr,float2 uv=float2(.5f)) {
    float3 rgb=graphScene(pixel,p,cube,table,false,true,uv);
    float3 neutralHDR=rgb;
    // Every look is evaluated at full strength, then mixed with a separately
    // rendered display-reference baseline. Never mix scene exposure with a print.
    if(p.flags.z) rgb=applyLUT(rgb,p,cube,table);
    float3 filmScene=rgb;
    rgb=fit(rgb,max(1.f,maximum(rgb)));
    float g=(p.flags.x!=0 || p.flags.z) ? log2(max(1.f,maximum(rgb))) : sdrWhitesGain(rgb,pixel,p,cube,table,uv);
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
        if(p.lutInfo.w>2 && p.lutInfo.w!=20) {
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
        float3 neutralBase=fit(graphScene(baseline,p,cube,table,true,true,uv),1.f);
        neutralHDR=fit(neutralHDR,max(1.f,maximum(neutralHDR)));
        float3 styledHDR=base*exp2(g);
        if(p.flags.y) {
            base=applyLUT(neutralBase,p,cube,table);
            styledHDR=max(float3(0),(base+offset)*(neutralHDR+offset)/(neutralBase+offset)-offset);
            if(p.lutInfo.w>2 && p.lutInfo.w!=20) base=fit(base/ max(1.f,maximum(base)),1.f);
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
        float3 original=graphScene(baseline,p,cube,table,false,true,uv,true,false,true);
        original=fit(original,max(1.f,maximum(original)));
        float oldGain=p.flags.x!=0 ? log2(max(1.f,maximum(original))) : sdrWhitesGain(original,baseline,p,cube,table,uv);
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
        auto v=preparePair(original,baseline.read(uint2(x,y)),p,cube,table,film,filmLUT,int2(x,y),float3(0),float4(0),nullptr,(float2(x,y)+.5f)/float2(src.get_width(),src.get_height()));
        float l=lum(v.base), request=sm(p.hdr.x,1.f,l), z=clamp(log2(l+1e-6f),-8.f,8.f);
        sum+=float4(l,request,z,z*z);
        float offset=p.pair.x;
        peak=max(peak,float4(maximum((v.base+offset)*exp2(v.gain)-offset),maximum(v.base),maximum(v.gain),maximum(original.rgb)));
    }
    float4 mean=sum/float((hi.x-lo.x)*(hi.y-lo.y));stats.write(mean,pos);peaks.write(peak,pos);
    masks.write(float4(sm(.15f,1.f,mean.x),1-sm(0.f,.5f,mean.x),1-sm(0.f,.1f,mean.x),mean.y),pos);
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
            sum+=wx*wy*filmRaw(graphScene(src.read(uint2(x,y)),p,cube,table,false,true,(float2(x,y)+.5f)/float2(src.get_width(),src.get_height()))*p.film.w,film,filmLUT);
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
        float highlight=max(0.f,lum(graphScene(src.read(uint2(x,y)),p,cube,table,false,true,(float2(x,y)+.5f)/float2(src.get_width(),src.get_height())))-.7f);
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
    float3 rgb=graphScene(sourceSample(src,float2(pos+p.region.zw)+.5f,float2(p.region.xy),p.inputRegion),p,cube,table,false,true,(float2(pos+p.region.zw)+.5f)/float2(p.region.xy));
    dst.write(float4(filmRaw(rgb*p.film.w,film,filmLUT),0),pos);
}
// Reconstruct each gain source using its own offset, then encode that HDR
// endpoint in the destination pair before combining it with captured gain.
float3 expansionGain(float3 base,float stops,float offset,float reconstructionOffset) {
    // Keep the original zero-offset expression for analytic/non-research gains.
    if(reconstructionOffset==0) {
        if(offset==0) return float3(stops);
        return log2((base*exp2(stops)+offset)/(base+offset));
    }
    if(offset==reconstructionOffset) return float3(stops);
    float3 hdr=(base+reconstructionOffset)*exp2(stops)-reconstructionOffset;
    return log2((max(hdr,0.f)+offset)/(base+offset));
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
                         p.scatter.z ? float4(scattered.read(uint2(int2(pos)+p.scatter.xy)).rgb,1) : float4(0),grainKernel,uv);
    pair=applyEffects(pair,p.effects.y>0 ? filmSmooth(halation,uv) : float3(0),int2(pos+p.region.zw),p,film,grainKernel);
    float3 g=pair.gain;
    float offset=p.pair.x;
    if(p.mode.x)g=max(g,expansionGain(pair.base,expansion.sample(s,uv).x*p.color.z/3,offset,0));
    if(p.mode.y && p.pair.y>0) {
        // Research strength scales predicted stops, before reconstruction with
        // the model's own offset. Scaling the encoded HDR/base ratio instead
        // makes near-black pixels discontinuous with the exactly black channel.
        g=scaleEndpointGain(pair.base,g,p.color.w,offset,p.flags.x);
        g=max(g,expansionGain(pair.base,model.sample(s,uv).x*p.color.w,offset,p.pair.y));
    } else {
        if(p.mode.y)g=max(g,expansionGain(pair.base,model.sample(s,uv).x,offset,0));
        g=scaleEndpointGain(pair.base,g,p.color.w,offset,p.flags.x);
    }
    float3 hdr=(pair.base+offset)*exp2(g)-offset;
    // Probe the actual node input, before downstream curves/shoulder/rolloff.
    if(p.light.w==3 || ((p.light.w==4 || p.light.w==5) && p.light.z==0)) {
        base.write(float4(p.light.w==3 ? pair.base : hdr,pair.alpha),pos);gain.write(float4(0),pos);return;
    }
    if(p.light.z!=0) {
        float y=lum(pair.base);
        if(y>0 && y<1)pair.base*=curveDecode(curveLookup(curveEncode(y),1,p,table))/y;
        pair.base=fit(pair.base,1.f);
        if(p.light.w==5) { base.write(float4(hdr,pair.alpha),pos);gain.write(float4(0),pos);return; }
        hdr=endpointCurve(hdr,0,false,p,table);
        if(p.light.w==4) { base.write(float4(hdr,pair.alpha),pos);gain.write(float4(0),pos);return; }
        hdr=endpointCurve(hdr,2,true,p,table);
        g=isoLogRatio(max(hdr,0.f)+offset,pair.base+offset);
    }
    float limit=exp2(p.color.z);
    float peak=maximum(hdr), mapped=softPeak(peak,limit,p.hdr.w!=0 || ((p.light.z!=0 || p.toneSpatialInfo.w!=0) && peak>limit));
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
        if(p.mode.x>1) { rgb=pointOp(rgb,3,p.tone0.w,false);rgb=pointOp(rgb,9,p.light.x,false); }
        float y=lum(rgb);
        weight=p.mode.x==0 ? sm(.15f,1.f,y) : p.mode.x==1 ? 1-sm(0.f,.5f,y) : 1-sm(0.f,.1f,y);
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

kernel void curveProbe(texture2d<float,access::sample> source [[texture(0)]],
                       texture2d<float,access::write> output [[texture(1)]],
                       texture3d<float,access::read> cube [[texture(2)]],
                       constant GraphUniform& p [[buffer(0)]],device const float4* table [[buffer(1)]],
                       uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    float4 pixel=sourceSample(source,float2(p.region.zw)+.5f,float2(p.region.xy),p.inputRegion);
    output.write(float4(graphScene(pixel,p,cube,table,false,true,(float2(p.region.zw)+.5f)/float2(p.region.xy)),1),pos);
}

// Fixed-grid spatial estimates. Atmospheric light is chosen from this compact
// grid; native-size renders only interpolate the guide and compose point ops.
kernel void toneSpatialExpose(texture2d<float,access::read> scene [[texture(0)]],
                              texture2d<float,access::read> base [[texture(1)]],
                              texture2d<float,access::write> outScene [[texture(2)]],
                              texture2d<float,access::write> outBase [[texture(3)]],
                              constant GraphUniform& p [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=outScene.get_width() || pos.y>=outScene.get_height())return;
    float3 h=scene.read(pos).rgb,b=base.read(pos).rgb;
    h=pointOp(pointOp(h,5,p.tone1.y,false),6,p.tone1.z,false);
    b=pointOp(pointOp(b,5,p.tone1.y,false),6,p.tone1.z,false);
    outScene.write(float4(pointOp(h,0,p.tone0.x,p.flags.x==0),1),pos);
    outBase.write(float4(pointOp(b,0,p.tone0.x,true),1),pos);
}
kernel void toneDarkChannel(texture2d<float,access::read> scene [[texture(0)]],
                            texture2d<float,access::write> output [[texture(1)]],
                            constant float4& air [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    float3 rgb=scene.read(pos).rgb;
    float dark=air.w!=0 ? min(rgb.r/air.r,min(rgb.g/air.g,rgb.b/air.b)) : min(1.f,min(rgb.r,min(rgb.g,rgb.b)));
    output.write(float4(max(0.f,dark),0,0,0),pos);
}
kernel void toneMinimum(texture2d<float,access::read> src [[texture(0)]],
                        texture2d<float,access::write> output [[texture(1)]],
                        constant BoxUniform& p [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=p.width || pos.y>=p.height)return;
    int center=p.vertical ? pos.y : pos.x,limit=p.vertical ? p.height : p.width;
    float minimum=INFINITY;
    for(int i=max(0,center-int(p.radius));i<=min(limit-1,center+int(p.radius));i++) {
        minimum=min(minimum,src.read(p.vertical ? uint2(pos.x,i) : uint2(i,pos.y)).x);
    }
    output.write(float4(minimum,0,0,0),pos);
}
kernel void toneTransmissionMoments(texture2d<float,access::read> scene [[texture(0)]],
                                    texture2d<float,access::read> dark [[texture(1)]],
                                    texture2d<float,access::write> output [[texture(2)]],
                                    constant uint& unused [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    float guide=min(1.f,lum(scene.read(pos).rgb)),t=max(.2f,1-.95f*dark.read(pos).x);
    output.write(float4(guide,t,guide*guide,guide*t),pos);
}
kernel void toneTransmissionCoefficients(texture2d<float,access::read> means [[texture(0)]],
                                         texture2d<float,access::write> output [[texture(1)]],
                                         constant uint& unused [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    float4 m=means.read(pos);float a=(m.w-m.x*m.y)/(max(0.f,m.z-m.x*m.x)+.001f);
    output.write(float4(a,m.y-a*m.x,0,0),pos);
}
kernel void toneTransmission(texture2d<float,access::read> moments [[texture(0)]],
                             texture2d<float,access::read> coefficients [[texture(1)]],
                             texture2d<float,access::write> output [[texture(2)]],
                             constant uint& unused [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    float2 c=coefficients.read(pos).xy;
    output.write(float4(clamp(c.x*moments.read(pos).x+c.y,.2f,1.f),0,0,0),pos);
}
float3 toneBeforeClarity(float3 rgb,float transmission,constant GraphUniform& p) {
    rgb=spatialDehaze(rgb,p.toneAtmosphere.xyz,transmission,p.toneSpatialSettings.x);
    rgb=pointOp(rgb,1,p.tone0.y,false);rgb=pointOp(rgb,2,p.tone0.z,false);
    rgb=pointOp(rgb,3,p.tone0.w,false);rgb=pointOp(rgb,9,p.light.x,false);
    return pointOp(rgb,4,p.tone1.x,false);
}
kernel void toneLogMoments(texture2d<float,access::read> scene [[texture(0)]],
                           texture2d<float,access::read> base [[texture(1)]],
                           texture2d<float,access::read> transmission [[texture(2)]],
                           texture2d<float,access::write> output [[texture(3)]],
                           constant GraphUniform& p [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    float t=transmission.read(pos).x;
    float h=log2(lum(toneBeforeClarity(scene.read(pos).rgb,t,p))+1e-4f);
    float b=log2(lum(toneBeforeClarity(base.read(pos).rgb,t,p))+1e-4f);
    output.write(float4(h,h*h,b,b*b),pos);
}
kernel void toneLogCoefficients(texture2d<float,access::read> means [[texture(0)]],
                               texture2d<float,access::write> output [[texture(1)]],
                               constant uint& unused [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    float4 m=means.read(pos);float2 variance=max(float2(0),m.yw-m.xz*m.xz),a=variance/(variance+.04f);
    output.write(float4(a.x,m.x*(1-a.x),a.y,m.z*(1-a.y)),pos);
}
kernel void toneFinishMap(texture2d<float,access::read> logs [[texture(0)]],
                          texture2d<float,access::read> coefficients [[texture(1)]],
                          texture2d<float,access::read> transmission [[texture(2)]],
                          texture2d<float,access::write> output [[texture(3)]],
                          constant uint& unused [[buffer(0)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=output.get_width() || pos.y>=output.get_height())return;
    float4 c=coefficients.read(pos),l=logs.read(pos);
    output.write(float4(transmission.read(pos).x,c.x*l.x+c.y,c.z*l.z+c.w,0),pos);
}
// One small patch, before the mixer; no readback of the full preview is needed.
kernel void graphMixerSample(texture2d<float,access::read> src [[texture(0)]],
                             texture3d<float,access::read> cube [[texture(1)]],
                             constant GraphUniform& p [[buffer(0)]],device const float4* table [[buffer(1)]],
                             device float4* result [[buffer(2)]],uint2 pos [[thread_position_in_grid]]) {
    if(any(pos!=uint2(0))) return;
    float3 rgb=0;
    int2 high=int2(src.get_width()-1,src.get_height()-1);
    for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
        uint2 site=uint2(clamp(int2(p.region.zw)+int2(x,y),int2(0),high));
        rgb+=graphScene(src.read(site),p,cube,table,false,true,(float2(site)+.5f)/float2(src.get_width(),src.get_height()),true,true);
    }
    result[0]=float4(rgb/9.f,1);
}
