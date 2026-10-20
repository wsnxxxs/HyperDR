import Foundation

extension DoubleReference {
    public static func smoothStep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = min(1, max(0, (value-low)/(high-low)))
        return t*t*(3-2*t)
    }
    public static func point(_ rgb: RGB, operation: AdjustmentOperation, value: Double, sdr: Bool = false) -> RGB {
        if operation == .contrast ? value == 1 : value == 0 { return rgb }
        let y = luma(rgb), a = value
        func scale(_ target: Double) -> RGB { y > 1e-8 ? rgb*(target/y) : rgb }
        switch operation {
        case .exposure:
            let x = rgb * exp2(value), brightness = luma(x)
            if sdr && value > 0 && brightness > 0.48 {
                return x * ((0.48+0.52 * -expm1(-(brightness-0.48)/0.52))/brightness)
            }
            return x
        case .contrast:
            if y >= 1 || y <= 0 { return rgb }
            let c = value
            let target: Double
            if y <= 0.18 { target = 0.18*pow(y/0.18,c) }
            else {
                let t = (y-0.18)/0.82
                target = 0.18+0.82*(t+(c-1)*t*(1-t)*(1-t))
            }
            return scale(target)
        case .highlights:
            return scale(y > 1 ? 1+(y-1)*exp2(2*a) : y+0.3*a*smoothStep(0.4,1,y)*(1-y))
        case .shadows:
            guard y < 0.5 else { return rgb }
            let t = y/0.5
            return scale(0.5*(t+0.8*a*t*(1-t)*(1-t)))
        case .blacks:
            guard y < 0.1 else { return rgb }
            let target = max(0,y-0.03*a*(1-smoothStep(0,0.1,y)))
            return y > 1e-8 ? scale(target) : rgb + RGB(repeating: target)
        case .warmth, .tint:
            let diagonal = operation == .warmth ? RGB(exp2(0.4*a),1,exp2(-0.4*a))
                                                : RGB(exp2(-0.2*a),exp2(0.4*a),exp2(-0.2*a))
            let changed = rgb*diagonal
            func rawY(_ x: RGB) -> Double { 0.2289746*x.x+0.6917385*x.y+0.0792869*x.z }
            return changed + RGB(repeating: rawY(rgb)-rawY(changed))
        case .vibrance, .saturation:
            let chroma = rgb-RGB(repeating:y)
            let saturation = max(abs(chroma.x),abs(chroma.y),abs(chroma.z))/max(y,1e-6)
            let amount = operation == .vibrance ? 1+a*(1-smoothStep(0.15,1,saturation)) : 1+a
            return RGB(repeating:y)+chroma*amount
        }
    }

    static func matrix(_ x: RGB, _ rows: [RGB]) -> RGB {
        func dot(_ y: RGB) -> Double { x.x*y.x+x.y*y.y+x.z*y.z }
        return RGB(dot(rows[0]),dot(rows[1]),dot(rows[2]))
    }
    static let to709 = [RGB(1.22494018,-0.22494018,0),RGB(-0.04205695,1.04205695,0),RGB(-0.01963755,-0.07863605,1.09827360)]
    static let from709 = [RGB(0.82246197,0.17753803,0),RGB(0.03319420,0.96680580,0),RGB(0.01708263,0.07239741,0.91051996)]
    static let to2020 = [RGB(0.753833,0.198597,0.047570),RGB(0.045744,0.941777,0.012479),RGB(-0.001210,0.017602,0.983608)]
    static let from2020 = [RGB(1.3435783,-0.2821797,-0.0613986),RGB(-0.0652975,1.0757879,-0.0104905),RGB(0.0028218,-0.0195985,1.0167767)]
    static let toCine = [RGB(0.77815155,0.11728624,0.10456221),RGB(0.07226832,0.75994794,0.16778375),RGB(0.02346043,0.06084114,0.91569844)]
    static let fromCine = [RGB(1.30640907,-0.19250497,-0.11390411),RGB(-0.11858463,1.35294405,-0.23435942),RGB(-0.02559149,-0.08496073,1.11055222)]

    public static func encodeLUT(_ source: RGB, space: LUTSpace) -> RGB {
        var x = source
        if space == .sLog3 { x = matrix(x,toCine) }
        else if space == .hlg || space == .pq { x = matrix(x,to2020) }
        else if space != .displayP3 {
            let native = matrix(x,to709), y = min(1,max(0,luma(x)))
            var amount = 1.0
            for c in 0..<3 {
                let delta = native[c]-y
                if delta > 0 { amount = min(amount,(1-y)/delta) }
                if delta < 0 { amount = min(amount,-y/delta) }
            }
            x = matrix(RGB(repeating:y)+min(1,max(0,amount))*(x-RGB(repeating:y)),to709)
        }
        if space == .hlg {
            var display = RGB(max(0,x.x*0.203),max(0,x.y*0.203),max(0,x.z*0.203))
            let y = 0.2627*display.x+0.6780*display.y+0.0593*display.z
            if y <= 0 { return .zero }; if y >= 1 { return RGB(repeating:1) }
            let upper = pow(y,1-1/1.2), peak = max(display.x,display.y,display.z)
            if peak > upper { display = RGB(repeating:y)+(upper-y)/(peak-y)*(display-RGB(repeating:y)) }
            for c in 0..<3 {
                let scene = min(1,display[c]*pow(y,1/1.2-1))
                x[c] = scene <= 1/12 ? sqrt(3*scene) : 0.17883277*log(12*scene-0.28466892)+0.55991073
            }
            return x
        }
        for c in 0..<3 {
            let v = x[c]
            switch space {
            case .sLog3: x[c] = v >= 0.01125 ? (420+261.5*log10((v+0.01)/0.19))/1023 : (v*(171.2102946929-95)/0.01125+95)/1023
            case .pq:
                let p = pow(min(1,max(0,v*0.0203)),2610/16384)
                x[c] = pow((3424/4096+(2413/128)*p)/(1+(2392/128)*p),2523/32)
            case .rec709: x[c] = pow(max(0,v),1/2.4)
            default: x[c] = v <= 0.0031308 ? 12.92*v : 1.055*pow(v,1/2.4)-0.055
            }
        }
        return x
    }

    public static func decodeLUT(_ encoded: RGB, space: LUTSpace) -> RGB {
        var x = encoded
        if space == .hlg {
            for c in 0..<3 {
                let v = min(1,max(0,x[c]))
                x[c] = v <= 0.5 ? v*v/3 : (exp((v-0.55991073)/0.17883277)+0.28466892)/12
            }
            x *= pow(abs(0.2627*x.x+0.6780*x.y+0.0593*x.z),0.2)/0.203
        } else {
            for c in 0..<3 {
                let v = x[c]
                switch space {
                case .sLog3: x[c] = v >= 171.2102946929/1023 ? pow(10,(v*1023-420)/261.5)*0.19-0.01 : (v*1023-95)*0.01125/(171.2102946929-95)
                case .pq:
                    let p = pow(min(1,max(0,v)),32/2523)
                    x[c] = pow(max(p-3424/4096,0)/max(2413/128-(2392/128)*p,1e-6),16384/2610)/0.0203
                case .rec709: x[c] = pow(max(0,v),2.4)
                default: x[c] = v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4)
                }
            }
        }
        if space == .sLog3 { return matrix(x,fromCine) }
        if space == .hlg || space == .pq { return matrix(x,from2020) }
        return space == .displayP3 ? x : matrix(x,from709)
    }

    public static func sampleLUT(_ rgb: RGB, lut: ColorLUT) -> RGB {
        var lo = SIMD3<Int>(), hi = SIMD3<Int>(), fraction = RGB.zero
        for c in 0..<3 {
            let position = min(1,max(0,(rgb[c]-Double(lut.domainMinimum[c]))/Double(lut.domainMaximum[c]-lut.domainMinimum[c])))*Double(lut.size-1)
            lo[c] = Int(floor(position)); hi[c] = min(lo[c]+1,lut.size-1); fraction[c] = position-Double(lo[c])
        }
        func value(_ x: Int, _ y: Int, _ z: Int, _ c: Int) -> Double { Double(lut.values[(z*lut.size+y)*lut.size+x][c]) }
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a+(b-a)*t }
        var result = RGB.zero
        for c in 0..<3 {
            if !lut.is3D { result[c] = lerp(Double(lut.values[lo[c]][c]),Double(lut.values[hi[c]][c]),fraction[c]); continue }
            let lower = lerp(lerp(value(lo.x,lo.y,lo.z,c),value(hi.x,lo.y,lo.z,c),fraction.x),lerp(value(lo.x,hi.y,lo.z,c),value(hi.x,hi.y,lo.z,c),fraction.x),fraction.y)
            let upper = lerp(lerp(value(lo.x,lo.y,hi.z,c),value(hi.x,lo.y,hi.z,c),fraction.x),lerp(value(lo.x,hi.y,hi.z,c),value(hi.x,hi.y,hi.z,c),fraction.x),fraction.y)
            result[c] = lerp(lower,upper,fraction.z)
        }
        return result
    }
    public static func look(_ rgb: RGB, settings: LookAdjustments) -> RGB {
        guard !settings.isIdentity, let lut = settings.lut else { return rgb }
        let mapped = decodeLUT(sampleLUT(encodeLUT(rgb,space:settings.input),lut:lut),space:settings.output)
        let fitted = fitP3(mapped,upper:settings.input.isSDR ? 1 : max(1,mapped.x,mapped.y,mapped.z))
        return rgb+(fitted-rgb)*Double(settings.strength)
    }

    /// Source decomposition has no range limit. HDR-only strength/range operate
    /// downstream so changing them never reselects the SDR base.
    public static func prepare(_ source: RGB, settings: RenderAdjustments, sdr: Bool) -> Split {
        var x = source
        let operations: [(AdjustmentOperation,Float)] = [(.warmth,settings.color.warmth),(.tint,settings.color.tint),
            (.exposure,settings.tone.exposure),(.contrast,settings.tone.contrast),(.highlights,settings.tone.highlights),
            (.shadows,settings.tone.shadows),(.blacks,settings.tone.blacks),(.vibrance,settings.color.vibrance),(.saturation,settings.color.saturation)]
        for (op,value) in operations { x = point(x,operation:op,value:Double(value),sdr:sdr && op == .exposure) }
        x = fitP3(x,upper:max(1,x.x,x.y,x.z))
        if !settings.look.isIdentity && !settings.look.input.isSDR { x = look(x,settings:settings.look) }
        let g = !sdr || (!settings.look.isIdentity && !settings.look.input.isSDR) ? log2(max(1,x.x,x.y,x.z)) : 0
        var base = fitP3(x*exp2(-g))
        if !settings.look.isIdentity && settings.look.input.isSDR { base = look(base,settings:settings.look) }
        return Split(base:base,gain:g)
    }

    public static func softShoulder(_ peak: Double, range: Double, active: Bool) -> Double {
        let cap = exp2(range)
        if !active || peak <= 1 || cap <= 1 { return peak }
        let knee = 1+0.75*(cap-1), width = cap-knee
        return peak <= knee ? peak : knee-width*expm1(-(peak-knee)/width)
    }
    public static func hdrOutput(_ pair: Split, expansion: Double = 0, settings: HDRAdjustments,
                                 range: Double, shoulder: Bool, allowRolloff: Bool) -> Split {
        var base = pair.base
        var gain = max(pair.gain,expansion)*Double(settings.strength)
        let peak = max(base.x,base.y,base.z)*exp2(gain)
        if peak > 0 { gain += log2(max(softShoulder(peak,range:range,active:shoulder)/peak,1e-30)) }
        if allowRolloff && settings.sdrRolloff > 0 {
            let m = max(base.x,base.y,base.z)
            if m > 0.7 {
                let compressed = 0.7-0.3*expm1(-(m-0.7)/0.3)
                let target = m+(compressed-m)*Double(settings.sdrRolloff)
                base *= target/m; gain += log2(m/target)
            }
        }
        if !settings.enabled { gain = 0 }
        return Split(base:base,gain:gain)
    }

    public static func authoredGain(base: RGB, gain: RGB, baseOffset: RGB, alternateOffset: RGB,
                                    strength: Double, range: Double, shoulder: Bool) -> RGB {
        var result = RGB.zero
        for c in 0..<3 {
            let denominator = base[c]+baseOffset[c]
            let neutral = denominator == 0 ? 0 : log2(max((base[c]+alternateOffset[c])/denominator,1e-30))
            result[c] = neutral+(gain[c]-neutral)*strength
        }
        var hdr = reconstruct(base,gain:result,baseOffset:baseOffset,alternateOffset:alternateOffset)
        let peak = max(hdr.x,hdr.y,hdr.z), mapped = softShoulder(peak,range:range,active:shoulder)
        if peak > 0 && mapped != peak {
            hdr *= mapped/peak
            for c in 0..<3 {
                let denominator = base[c]+baseOffset[c]
                result[c] = denominator == 0 ? 0 : log2(max((hdr[c]+alternateOffset[c])/denominator,1e-30))
            }
        }
        return result
    }
}
