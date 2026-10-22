// Film emulation (FilmStock.swift is the double reference). Rows match FilmStock.packed():
// matrices are rows of float4; densities carry the base density in w; the two light
// tables are illuminant × sensitivity (printing) and illuminant × observer (viewing).
// levels: slide exposure scale, scanner slope and offset on Y. grain: 3×3 weights
// (centre, edge, corner) and the film format in millimetres.
struct FilmData {
    float4 p3ToReference[3], couplers[3], xyzToP3[3];
    float4 densityMaximum, axes, info, levels, grain;
    float4 filmCurves[256], filmCurvesBeforeCouplers[256], paperCurves[256];
    float4 filmDensity[81], scannedDensity[81], printLight[81], scanLight[81];
    float4 grainVariance[256];
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
// Unit normal noise per pixel and channel; FilmStock.grainNoise computes the same bits.
float filmNoise(int x,int y,uint c) {
    uint h=filmHash(as_type<uint>(x)+filmHash(as_type<uint>(y)+filmHash(c+0x9e3779b9u)));
    float u1=float(h>>8)*0x1p-24f+0x1p-25f,u2=float(filmHash(h)>>8)*0x1p-24f;
    return sqrt(-2*log(u1))*cos(2*M_PI_F*u2);
}
// Linear film exposure of a scene colour: the spectral upsampling's chromaticity table
// scaled by X+Y+Z (and a slide's scanner correction).
float3 filmRaw(float3 rgb,const device FilmData& d,texture2d<float,access::read> lut) {
    float3 xyz=filmRows(d.p3ToReference,rgb);
    float s=xyz.x+xyz.y+xyz.z,x=xyz.x/max(s,1e-10f),y=xyz.y/max(s,1e-10f);
    float2 tc=clamp(float2((1-x)*(1-x),y/max(1-x,1e-10f)),0.f,1.f);
    return filmSpectral(lut,tc,int(d.info.w))*s*d.levels.x;
}
// From film exposure on: development, grain, print and viewing.
// grain: amount, 1/pixel area (µm⁻²); pixel: output coordinates in the full render.
float3 filmFromRaw(float3 raw,const device FilmData& d,float2 grain,int2 pixel) {
    float3 logE=filmLog10(raw);
    float3 density=filmCurve(logE,d.axes.x,d.axes.y,d.filmCurves);
    float3 silver=d.info.x!=0 ? d.densityMaximum.xyz-density : density;
    logE-=silver.r*d.couplers[0].xyz+silver.g*d.couplers[1].xyz+silver.b*d.couplers[2].xyz;
    density=filmCurve(logE,d.axes.x,d.axes.y,d.filmCurvesBeforeCouplers);
    if(grain.x>0) {
        float3 variance=filmCurve(density/d.densityMaximum.xyz*255.f,0.f,255.f,d.grainVariance);
        for(uint c=0;c<3;c++) {
            float noise=0;
            for(int dy=-1;dy<=1;dy++) for(int dx=-1;dx<=1;dx++)
                noise+=d.grain[abs(dx)+abs(dy)]*filmNoise(pixel.x+dx,pixel.y+dy,c);
            density[c]=max(0.f,density[c]+grain.x*sqrt(max(variance[c],0.f)*grain.y)*noise);
        }
    }
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
// Back-reflection halation on the analysis cells: each cell's mean film exposure,
// convolved with the stock's sum of Gaussians (weights from FilmStock.halationKernel,
// (2r+1)² row-major, mirrored at the edges). Glow is low-frequency, so the render
// samples this map bilinearly.
kernel void filmHalation(texture2d<float,access::read> raw [[texture(0)]],texture2d<float,access::write> glow [[texture(1)]],
                         constant int& radius [[buffer(0)]],device const float* weights [[buffer(1)]],
                         uint2 pos [[thread_position_in_grid]]) {
    int w=raw.get_width(),h=raw.get_height();
    if(int(pos.x)>=w || int(pos.y)>=h) return;
    float3 sum=0;
    for(int dy=-radius;dy<=radius;dy++) {
        int y=int(pos.y)+dy;y=y<0 ? -y : y>=h ? 2*(h-1)-y : y;y=clamp(y,0,h-1);
        for(int dx=-radius;dx<=radius;dx++) {
            int x=int(pos.x)+dx;x=x<0 ? -x : x>=w ? 2*(w-1)-x : x;x=clamp(x,0,w-1);
            sum+=weights[(dy+radius)*(2*radius+1)+dx+radius]*raw.read(uint2(x,y)).rgb;
        }
    }
    glow.write(float4(sum,0),pos);
}
// One row per thread: centre-weighted (Gaussian, sigma 0.2 of the long edge) sums of
// luminance and weight, for RenderEngine.filmMeter.
kernel void filmMeter(texture2d<float,access::read> src [[texture(0)]],constant uint& unused [[buffer(0)]],
                      device float2* rows [[buffer(1)]],uint2 pos [[thread_position_in_grid]]) {
    uint w=src.get_width(),h=src.get_height();
    if(pos.x>=h) return;
    float edge=float(max(w,h)),y=(float(pos.x)/float(h)-.5f)*float(h)/edge;
    float2 sum=0;
    for(uint x=0;x<w;x++) {
        float u=(float(x)/float(w)-.5f)*float(w)/edge,weight=exp(-(u*u+y*y)/(2*.04f));
        float3 c=src.read(uint2(x,pos.x)).rgb;
        sum+=float2(weight*max(0.f,dot(c,float3(.2289746f,.6917385f,.0792869f))),weight);
    }
    rows[pos.x]=sum;
}
