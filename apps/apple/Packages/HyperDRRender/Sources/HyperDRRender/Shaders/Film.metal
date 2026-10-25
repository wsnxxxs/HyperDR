// Film emulation (FilmStock.swift is the double reference). Rows match FilmStock.packed():
// matrices are rows of float4; densities carry the base density in w; the two light
// tables are illuminant × sensitivity (printing) and illuminant × observer (viewing).
// levels: slide exposure scale, scanner slope and offset on Y. grain: the density under the
// particles (grain's floor is its negative) and, in w, the scan's blur in pixels. format.x:
// the film format in millimetres. Grain tables: each sublayer's variance ×
// area and third cumulant × area², and its dye clouds (µm).
struct FilmData {
    float4 p3ToReference[3], couplers[3], xyzToP3[3];
    float4 densityMaximum, axes, info, levels, grain, format;
    float4 filmCurves[256], filmCurvesBeforeCouplers[256], paperCurves[256];
    float4 filmDensity[81], scannedDensity[81], printLight[81], scanLight[81];
    float4 grainVariance[3*256], grainThird[3*256], grainClouds[3];
};
float3 filmRows(const device float4* m,float3 v) { return float3(dot(m[0].xyz,v),dot(m[1].xyz,v),dot(m[2].xyz,v)); }
float3 filmLog10(float3 x) { return log10(max(x,0.f)+1e-10f); }
// Per-channel linear interpolation on a uniform 256-sample axis, clamped at both ends.
float3 filmCurve(float3 x,float low,float high,const device float4* table) {
    float3 t=clamp((x-low)/(high-low)*255.f,0.f,255.f),r;
    for(uint c=0;c<3;c++) {
        uint i=min(uint(t[c]),254u);float f=t[c]-float(i);
        r[c]=mix(table[i][c],table[i+1][c],f);
    }
    return r;
}
float filmMitchell(float t) {
    float x=abs(t);const float b=1.f/3,c=1.f/3;
    if(x<1) return ((12-9*b-6*c)*x*x*x+(-18+12*b+6*c)*x*x+(6-2*b))/6;
    if(x<2) return ((-b-6*c)*x*x*x+(6*b+30*c)*x*x+(-12*b-48*c)*x+(8*b+24*c))/6;
    return 0;
}
// Mitchell–Netravali with reflected edges, as spektrafilm's tc lookup.
float3 filmSpectral(texture2d<float,access::read> lut,float2 tc,int size) {
    float2 c=clamp(tc*float(size-1),0.f,float(size-1));
    int2 b=int2(floor(c));float2 f=c-float2(b);
    if(c.x>=float(size-1)) { b.x=size-2;f.x=1; }
    if(c.y>=float(size-1)) { b.y=size-2;f.y=1; }
    float3 sum=0;float weights=0;
    for(int i=0;i<4;i++) {
        int x=b.x-1+i;x=x<0 ? -x : x>=size ? 2*(size-1)-x : x;
        float wx=filmMitchell(f.x+1-float(i));
        for(int j=0;j<4;j++) {
            int y=b.y-1+j;y=y<0 ? -y : y>=size ? 2*(size-1)-y : y;
            float w=wx*filmMitchell(f.y+1-float(j));
            sum+=w*lut.read(uint2(x,y)).rgb;weights+=w;
        }
    }
    return weights!=0 ? sum/weights : sum;
}
uint filmHash(uint v) { v^=v>>16;v*=0x7feb352du;v^=v>>15;v*=0x846ca68bu;v^=v>>16;return v; }
// Unit normal noise of a pixel's three channels; FilmStock.grainNoise computes the same bits.
float3 filmNoise(int x,int y) {
    uint h0=filmHash(as_type<uint>(x)+filmHash(as_type<uint>(y)+0x9e3779b9u)),h1=filmHash(h0),h2=filmHash(h1),h3=filmHash(h2);
    float r=sqrt(-2*log(float(h0>>8)*0x1p-24f+0x1p-25f)),angle=2*M_PI_F*float(h1>>8)*0x1p-24f;
    float blue=sqrt(-2*log(float(h2>>8)*0x1p-24f+0x1p-25f))*cos(2*M_PI_F*float(h3>>8)*0x1p-24f);
    return float3(r*cos(angle),r*sin(angle),blue);
}
// Linear film exposure of a scene colour: the spectral upsampling's chromaticity table
// scaled by X+Y+Z (and a slide's scanner correction).
float3 filmRaw(float3 rgb,const device FilmData& d,texture2d<float,access::read> lut) {
    float3 xyz=filmRows(d.p3ToReference,rgb);
    float s=xyz.x+xyz.y+xyz.z,x=xyz.x/max(s,1e-10f),y=xyz.y/max(s,1e-10f);
    float2 tc=clamp(float2((1-x)*(1-x),y/max(1-x,1e-10f)),0.f,1.f);
    return filmSpectral(lut,tc,int(d.info.w))*s*d.levels.x;
}
// a such that z + a(z² - 1) has this skewness (FilmStock.cornishFisher).
float3 filmBend(float3 skew) {
    float3 target=clamp(skew,0.f,2.5f),a=target/6;
    for(int i=0;i<4;i++) {
        float3 q=1+2*a*a,root=sqrt(q),n=6*a+8*a*a*a;
        a-=(n/(q*root)-target)/(((6+24*a*a)*q-n*6*a)/(q*q*root));
    }
    return a;
}
// spektrafilm's sublayer grain; FilmStock.addGrain is the reference and explains it.
// grain: amount, 1/pixel area (µm⁻²). taps: FilmStock.packedGrainKernel for this render.
float3 filmGrain(float3 density,const device FilmData& d,float2 grain,int2 pixel,constant float4* taps) {
    float3 t=density/d.densityMaximum.xyz*255.f,v[3],total=0,target2=0,target3=0;
    for(int l=0;l<3;l++) {
        v[l]=max(filmCurve(t,0.f,255.f,d.grainVariance+256*l),0.f)*grain.y;total+=v[l];
        target2+=v[l]*taps[57+l].xyz;
        target3+=max(filmCurve(t,0.f,255.f,d.grainThird+256*l),0.f)*grain.y*grain.y*taps[60+l].xyz;
    }
    float3 inverse=1/max(total,1e-30f),a[3]={v[0]*inverse,v[1]*inverse,v[2]*inverse},energy2=0,energy3=0;
    for(int l=0;l<3;l++) for(int m=0;m<3;m++) {
        energy2+=a[l]*a[m]*taps[21+3*l+m].xyz;
        for(int n=0;n<3;n++) energy3+=a[l]*a[m]*a[n]*taps[30+9*l+3*m+n].xyz;
    }
    float3 scale=sqrt(target2/max(energy2,1e-30f)),bend=filmBend(target3/max(scale*scale*scale*energy3,1e-30f)),noise=0;
    int radius=int(taps[63].x);
    for(int dy=-radius;dy<=radius;dy++) {
        int y=abs(dy);
        float3 b0=a[0]*taps[y].xyz,b1=a[1]*taps[7+y].xyz,b2=a[2]*taps[14+y].xyz;
        for(int dx=-radius;dx<=radius;dx++) {
            int x=abs(dx);
            float3 n=filmNoise(pixel.x+dx,pixel.y+dy);
            noise+=(b0*taps[x].xyz+b1*taps[7+x].xyz+b2*taps[14+x].xyz)*(n+bend*(n*n-1));
        }
    }
    return select(max(-d.grain.xyz,density+grain.x*scale*noise*rsqrt(1+2*bend*bend)),density,total<=0);
}
// From film exposure on: development, grain, print and viewing.
// grain: amount, 1/pixel area (µm⁻²); pixel: output coordinates in the full render.
float3 filmFromRaw(float3 raw,const device FilmData& d,float2 grain,int2 pixel,constant float4* grainKernel) {
    float3 logE=filmLog10(raw);
    float3 density=filmCurve(logE,d.axes.x,d.axes.y,d.filmCurves);
    float3 silver=d.info.x!=0 ? d.densityMaximum.xyz-density : density;
    logE-=silver.r*d.couplers[0].xyz+silver.g*d.couplers[1].xyz+silver.b*d.couplers[2].xyz;
    density=filmCurve(logE,d.axes.x,d.axes.y,d.filmCurvesBeforeCouplers);
    if(grain.x>0) density=filmGrain(density,d,grain,pixel,grainKernel);
    if(d.info.y!=0) {
        float3 raw=0;
        for(uint w=0;w<81;w++) raw+=exp10(-(dot(density,d.filmDensity[w].xyz)+d.filmDensity[w].w))*d.printLight[w].xyz;
        density=filmCurve(filmLog10(raw*d.info.z),d.axes.z,d.axes.w,d.paperCurves);
    }
    float3 seen=0;
    for(uint w=0;w<81;w++) seen+=exp10(-(dot(density,d.scannedDensity[w].xyz)+d.scannedDensity[w].w))*d.scanLight[w].xyz;
    seen=max(seen,0.f)+1e-10f;
    seen*=clamp(d.levels.y*seen.y+d.levels.z,0.f,1.f)/(seen.y+1e-10f);
    return filmRows(d.xyzToP3,seen);
}
// scipy.ndimage's 'reflect' edges: (d c b a | a b c d | d c b a).
int filmReflect(int i,int n) {
    int period=2*n,j=((i%period)+period)%period;
    return j<n ? j : period-1-j;
}
// One axis of one Gaussian of a spatial effect (FilmStock.taps): per-channel taps, 2·radius+1
// of them. The second, vertical pass of each later component adds into dst. Film exposure
// textures span the region and its halo, so a reflected edge is always the image's own.
struct FilmBlurUniform { int radius,vertical,accumulate,unused; };
kernel void filmBlur(texture2d<float,access::read> src [[texture(0)]],texture2d<float,access::read_write> dst [[texture(1)]],
                     constant FilmBlurUniform& u [[buffer(0)]],device const float4* taps [[buffer(1)]],
                     uint2 pos [[thread_position_in_grid]]) {
    int w=src.get_width(),h=src.get_height();
    if(int(pos.x)>=w || int(pos.y)>=h) return;
    int n=u.vertical ? h : w,i=u.vertical ? int(pos.y) : int(pos.x);
    float3 sum=0;
    for(int k=-u.radius;k<=u.radius;k++) {
        int j=filmReflect(i+k,n);
        sum+=taps[k+u.radius].xyz*src.read(u.vertical ? uint2(pos.x,j) : uint2(j,pos.y)).rgb;
    }
    if(u.accumulate) sum+=dst.read(pos).rgb;
    dst.write(float4(sum,0),pos);
}
// Cubic B-spline through four bilinear fetches: the halation map, smooth between its cells
// (FilmStock's halation sigma already allows for the spline's and the cells' own width).
float3 filmSmooth(texture2d<float,access::sample> map,float2 uv) {
    constexpr sampler s(coord::pixel,address::clamp_to_edge,filter::linear);
    float2 x=uv*float2(map.get_width(),map.get_height())-.5f,i=floor(x),f=x-i;
    float2 w0=(1-f)*(1-f)*(1-f)/6,w1=(4-6*f*f+3*f*f*f)/6,w2=(1+3*f+3*f*f-3*f*f*f)/6,w3=f*f*f/6;
    float2 g0=w0+w1,g1=w2+w3,h0=i-.5f+w1/g0,h1=i+1.5f+w3/g1;
    return g0.y*(g0.x*map.sample(s,float2(h0.x,h0.y)).rgb+g1.x*map.sample(s,float2(h1.x,h0.y)).rgb)
          +g1.y*(g0.x*map.sample(s,float2(h0.x,h1.y)).rgb+g1.x*map.sample(s,float2(h1.x,h1.y)).rgb);
}
// One row per thread: log luminance and centre weight per sample.
// Half uniform, half Gaussian (sigma 0.2 long edge): keep the whole photograph
// represented while giving its centre twice the weight of the corners.
// The CPU takes their weighted median, so highlights and crushed shadows cannot
// dictate the exposure of the rest of the photograph.
kernel void filmMeter(texture2d<float,access::read> src [[texture(0)]],constant uint& unused [[buffer(0)]],
                      device float2* samples [[buffer(1)]],uint2 pos [[thread_position_in_grid]]) {
    uint w=src.get_width(),h=src.get_height();
    if(pos.x>=h) return;
    float edge=float(max(w,h)),y=(float(pos.x)/float(h)-.5f)*float(h)/edge;
    for(uint x=0;x<w;x++) {
        float u=(float(x)/float(w)-.5f)*float(w)/edge,weight=.5f+.5f*exp(-(u*u+y*y)/(2*.04f));
        float3 c=src.read(uint2(x,pos.x)).rgb;
        float luminance=max(1e-6f,dot(c,float3(.2289746f,.6917385f,.0792869f)));
        samples[pos.x*w+x]=float2(log2(luminance),weight);
    }
}
