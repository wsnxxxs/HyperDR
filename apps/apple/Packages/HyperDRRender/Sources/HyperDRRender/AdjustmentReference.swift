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
            let factor = exp2(value), x = rgb * factor
            if sdr && value > 0 {
                let knee = exp2(-2*value)
                if y > knee {
                    let position = min(1,max(0,(1-y)/(1-knee)))
                    let shoulder = 1-(1-1/factor)*pow(position,factor+1)
                    return rgb * (shoulder/y)
                }
            }
            return x
        case .contrast:
            if y >= 1 || y <= 0 { return rgb }
            let x = pow(y, 1/2.4), pivot = pow(0.18, 1/2.4)
            let amount = log(value) / log(1.6)
            let k = amount * (amount > 0 ? 1.6 : 0.8)
            let target: Double
            if x <= pivot {
                let t = x / pivot
                target = pivot * (t - k*t*t*t*(1-t))
            } else {
                let t = (x-pivot)/(1-pivot)
                target = pivot + (1-pivot)*(t+k*t*(1-t)*(1-t))
            }
            return scale(pow(target, 2.4))
        case .highlights:
            if y > 1 {
                let left = a < 0 ? 1.0 : exp2(-3*a), right = exp2(2*a), x = y-1, t = min(x, 1)
                return scale(1+right*x+(left-right)*(t-t*t*t+0.5*t*t*t*t))
            }
            guard y > 0.15 else { return rgb }
            let t = (y-0.15)/0.85
            let target = 0.15+0.85*t/(t+(1-t)*exp2(-3*a*t))
            return scale(a < 0 ? target+(y-target)*smoothStep(0.8,1,y) : target)
        case .shadows:
            guard y < 0.5 else { return rgb }
            let t = y/0.5
            return scale(0.5*(t+0.8*a*t*(1-t)*(1-t)))
        case .whites:
            guard y > 0 else { return rgb }
            return scale(y*exp2(2*a*y/(y+0.5)))
        case .blacks:
            guard y < 0.5 else { return rgb }
            let encoded = (y <= 0.0031308 ? 12.92*max(0,y) : 1.055*pow(y,1/2.4)-0.055)
            let changed = a > 0
                ? max(0, encoded - 0.1*a*(1-smoothStep(0.1,0.5,encoded)))
                : encoded - 0.12*a*(1-smoothStep(0,0.5,encoded))
            let target = (changed <= 0.04045 ? changed/12.92 : pow((changed+0.055)/1.055,2.4))
            // Lift the floor with neutral light; scaling would amplify shadow chroma/noise.
            if a < 0 { return rgb + RGB(repeating: target-y) }
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
    // Display P3 linear (D65) to each log primary, 8 decimals, the same NPM as toCine
    // (xy primaries, white 0.3127/0.3290). Inverses are the rounded exact inverses.
    // S-Gamut3: Sony Technical Summary, xy 0.730/0.280, 0.140/0.855, 0.100/-0.050.
    static let toSG3 = [RGB(0.67716998,0.22268083,0.10014919),RGB(0.05823254,0.80559897,0.13616849),RGB(0.00574488,0.03981469,0.95444043)]
    static let fromSG3 = [RGB(1.51312381,-0.41331979,-0.09980402),RGB(-0.10860213,1.27979248,-0.17119035),RGB(-0.00457729,-0.05089900,1.05547629)]
    // V-Gamut: Panasonic VARICAM V-Log/V-Gamut, xy 0.730/0.280, 0.165/0.840, 0.100/-0.030.
    static let toVG = [RGB(0.70145111,0.19732955,0.10121935),RGB(0.05979648,0.82841649,0.11178703),RGB(0.00617097,0.04603128,0.94779775)]
    static let fromVG = [RGB(1.45564245,-0.34032783,-0.11531462),RGB(-0.10447649,1.23951197,-0.13503547),RGB(-0.00440341,-0.05798302,1.06238642)]
    // F-Gamut is Rec.2020 (Fujifilm F-Log2 Data Sheet). Eight decimals; HLG/PQ keep the
    // existing six-decimal to2020.
    static let toFGamut = [RGB(0.75383303,0.19859737,0.04756960),RGB(0.04574385,0.94177722,0.01247893),RGB(-0.00121034,0.01760172,0.98360862)]
    static let fromFGamut = [RGB(1.34357825,-0.28217967,-0.06139858),RGB(-0.06529745,1.07578792,-0.01049046),RGB(0.00282179,-0.01959849,1.01677671)]
    // AWG3: ARRI, xy 0.6840/0.3130, 0.2210/0.8480, 0.0861/-0.1020.
    static let toAWG3 = [RGB(0.76001934,0.13248356,0.10749710),RGB(0.00840830,0.80472802,0.18686368),RGB(-0.00135534,0.08556969,0.91578565)]
    static let fromAWG3 = [RGB(1.31782216,-0.20495324,-0.11286893),RGB(-0.01453774,1.27247685,-0.25793911),RGB(0.00330873,-0.11920173,1.11589300)]
    // AWG4: ARRI LogC4 specification, xy 0.7347/0.2653, 0.1424/0.8576, 0.0991/-0.0308.
    static let toAWG4 = [RGB(0.67695999,0.21998630,0.10305371),RGB(0.07251887,0.81542700,0.11205413),RGB(0,0.04142423,0.95857577)]
    static let fromAWG4 = [RGB(1.52050240,-0.40429866,-0.11620373),RGB(-0.13603158,1.26984798,-0.13381640),RGB(0.00587852,-0.05487566,1.04899714)]
    // Cinema Gamut: Canon, xy 0.740/0.270, 0.170/1.140, 0.080/-0.100.
    static let toCinema = [RGB(0.66516377,0.20889950,0.12593674),RGB(0.06595013,0.75819764,0.17585223),RGB(0.01650097,0.16958652,0.81391252)]
    static let fromCinema = [RGB(1.54602980,-0.39137139,-0.15465841),RGB(-0.13366788,1.41972914,-0.28606126),RGB(-0.00349265,-0.28787973,1.29137238)]

    static func logMatrix(_ x: RGB, space: LUTSpace, inverse: Bool) -> RGB {
        switch space {
        case .sLog3: return matrix(x, inverse ? fromCine : toCine)
        case .slog3SGamut3: return matrix(x, inverse ? fromSG3 : toSG3)
        case .vlogVGamut: return matrix(x, inverse ? fromVG : toVG)
        case .flog2FGamut: return matrix(x, inverse ? fromFGamut : toFGamut)
        case .logC3AWG3: return matrix(x, inverse ? fromAWG3 : toAWG3)
        case .logC4AWG4: return matrix(x, inverse ? fromAWG4 : toAWG4)
        case .clog3CinemaGamut: return matrix(x, inverse ? fromCinema : toCinema)
        default: return x
        }
    }

    /// Scene-linear (0.18 = 18% reflectance) to the normalized code. Values below
    /// each white paper's knee, including negatives, use that linear segment so
    /// the log is never fed a non-positive argument.
    static func encodeLog(_ v: Double, space: LUTSpace) -> Double {
        switch space {
        case .sLog3, .slog3SGamut3:
            // Sony Technical Summary for S-Gamut3.Cine/S-Log3 and S-Gamut3/S-Log3. Same curve.
            return v >= 0.01125 ? (420+261.5*log10((v+0.01)/0.19))/1023 : (v*(171.2102946929-95)/0.01125+95)/1023
        case .vlogVGamut:
            // Panasonic VARICAM V-Log/V-Gamut: cut1 0.01, b 0.00873, c 0.241514, d 0.598206.
            return v < 0.01 ? 5.6*v+0.125 : 0.241514*log10(v+0.00873)+0.598206
        case .flog2FGamut:
            // Fujifilm F-Log2 Data Sheet Ver.1.0. cut1 0.000889.
            return v < 0.000889 ? 8.799461*v+0.092864 : 0.245281*log10(5.555556*v+0.064829)+0.384316
        case .logC3AWG3:
            // ARRI Alexa Log C, SUP 3.x, EI 800, linear scene exposure factor.
            return v > 0.010591 ? 0.247190*log10(5.555556*v+0.052272)+0.385537 : 5.367655*v+0.092809
        case .logC4AWG4:
            // ARRI LogC4 specification (Cooper & Brendel, 2022). t is negative; the
            // log is defined for every non-negative scene value, and below t the
            // linear extension is (v-t)/s, which reaches code 0 at t.
            let a = 2231.826309067688, b = 0.9071358748778103, c = 0.09286412512218964
            let s = 0.1135972086105891, t = -0.01805699611991131
            return v >= t ? (log2(a*v+64)-6)/14*b+c : (v-t)/s
        case .clog3CinemaGamut:
            // Canon Log 3 v1.2 (legal-range constants). Reflection is divided by 0.9
            // before the curve, which is what places 18% gray at ~0.343. The negative
            // log is the white paper's negative branch and is defined for every x < 0.
            let x = v/0.9
            if x < -0.014 { return -0.36726845*log10(-x*14.98325+1)+0.12783901 }
            if x <= 0.014 { return 1.9754798*x+0.12512219 }
            return 0.36726845*log10(x*14.98325+1)+0.12240537
        default:
            preconditionFailure("Not a log space")
        }
    }

    static func decodeLog(_ v: Double, space: LUTSpace) -> Double {
        switch space {
        case .sLog3, .slog3SGamut3:
            return v >= 171.2102946929/1023 ? pow(10,(v*1023-420)/261.5)*0.19-0.01 : (v*1023-95)*0.01125/(171.2102946929-95)
        case .vlogVGamut:
            // cut2 0.181 is the code at the knee.
            return v < 0.181 ? (v-0.125)/5.6 : pow(10,(v-0.598206)/0.241514)-0.00873
        case .flog2FGamut:
            // Code at cut1, from the F-Log2 datasheet constants.
            return v < 0.100686685370811 ? (v-0.092864)/8.799461 : (pow(10,(v-0.384316)/0.245281)-0.064829)/5.555556
        case .logC3AWG3:
            let knee = 5.367655*0.010591+0.092809
            return v > knee ? (pow(10,(v-0.385537)/0.247190)-0.052272)/5.555556 : (v-0.092809)/5.367655
        case .logC4AWG4:
            let a = 2231.826309067688, b = 0.9071358748778103, c = 0.09286412512218964
            let s = 0.1135972086105891, t = -0.01805699611991131
            return v >= 0 ? (pow(2,14*((v-c)/b)+6)-64)/a : v*s+t
        case .clog3CinemaGamut:
            let x: Double
            if v < 0.097465473 { x = -(pow(10,(0.12783901-v)/0.36726845)-1)/14.98325 }
            else if v <= 0.15277891 { x = (v-0.12512219)/1.9754798 }
            else { x = (pow(10,(v-0.12240537)/0.36726845)-1)/14.98325 }
            return x*0.9
        default:
            preconditionFailure("Not a log space")
        }
    }

    public static func encodeLUT(_ source: RGB, space: LUTSpace) -> RGB {
        var x = source
        if space.isLog { x = logMatrix(x,space:space,inverse:false) }
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
            if space.isLog { x[c] = encodeLog(v,space:space); continue }
            switch space {
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
                if space.isLog { x[c] = decodeLog(v,space:space); continue }
                switch space {
                case .pq:
                    let p = pow(min(1,max(0,v)),32/2523)
                    x[c] = pow(max(p-3424/4096,0)/max(2413/128-(2392/128)*p,1e-6),16384/2610)/0.0203
                case .rec709: x[c] = pow(max(0,v),2.4)
                default: x[c] = v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4)
                }
            }
        }
        if space.isLog { return logMatrix(x,space:space,inverse:true) }
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
        let upper = settings.input.isSDR && settings.output.isSDR ? 1 : max(1,mapped.x,mapped.y,mapped.z)
        let fitted = fitP3(mapped,upper:upper)
        return rgb+(fitted-rgb)*Double(settings.strength)
    }

    /// Source decomposition has no range limit. HDR-only strength/range operate
    /// downstream so changing them never reselects the SDR base.
    /// `grain` places the film's grain; without it the film is grainless. An automatic
    /// film exposure reads as zero here: pass the metered value in `settings`.
    public static func prepare(_ source: RGB, settings: RenderAdjustments, sdr: Bool, grain: FilmGrainSite? = nil, baseline: RGB? = nil) -> Split {
        let weight = !settings.look.isIdentity ? settings.look.strength : settings.film.isIdentity ? 0 : settings.film.strength
        if weight > 0 && weight < 1 {
            var full = settings
            if !full.look.isIdentity { full.look.strength = 1 } else { full.film.strength = 1 }
            let styled = prepare(source, settings: full, sdr: sdr, grain: grain)
            var plain = settings; plain.look.lut = nil; plain.film.stock = nil
            let original = prepare(baseline ?? source, settings: plain, sdr: sdr)
            let w = Double(weight)
            let base = original.base + (styled.base-original.base)*w
            if styled.gains == original.gains { return Split(base: base, gains: original.gains) }
            var gains = RGB.zero
            for c in 0..<3 {
                let a = original.base[c]*exp2(original.gains[c]), b = styled.base[c]*exp2(styled.gains[c])
                gains[c] = base[c] == 0 ? 0 : log2(max((a+(b-a)*w)/base[c],1e-30))
            }
            return Split(base: base, gains: gains)
        }
        let operations: [(AdjustmentOperation,Float)] = [(.warmth,settings.color.warmth),(.tint,settings.color.tint),
            (.exposure,settings.tone.exposure),(.contrast,settings.tone.contrast),(.highlights,settings.tone.highlights),
            (.shadows,settings.tone.shadows),(.whites,settings.tone.whites),(.blacks,settings.tone.blacks)]
        func adjusted(_ whites: Float) -> RGB {
            var x = source
            for (op,value) in operations {
                x = point(x,operation:op,value:Double(op == .whites ? whites : value),sdr:sdr && op == .exposure)
            }
            x = toneCurve(x, curve: settings.tone.curve)
            x = point(x, operation: .vibrance, value: Double(settings.color.vibrance))
            return point(x, operation: .saturation, value: Double(settings.color.saturation))
        }
        var x = adjusted(settings.tone.whites)
        let active = !settings.look.isIdentity
        // A log look keeps linear-P3 negatives through the primary matrix. Fit after
        // the strength mix so the gain split never sees a negative component.
        let logLook = active && settings.look.input.isLog
        if !logLook && settings.film.isIdentity { x = fitP3(x,upper:max(1,x.x,x.y,x.z)) }
        if active && !settings.look.input.isSDR { x = look(x,settings:settings.look) }
        if logLook { x = fitP3(x,upper:max(1,x.x,x.y,x.z)) }
        let filmScene = x
        x = fitP3(x,upper:max(1,x.x,x.y,x.z))
        var g = !sdr || (active && !settings.look.input.isSDR) ? log2(max(1,x.x,x.y,x.z)) : 0
        if sdr, !(active && !settings.look.input.isSDR), settings.tone.whites > 0 {
            var original = adjusted(0)
            original = fitP3(original,upper:max(1,original.x,original.y,original.z))
            g = max(0,log2(max(1,x.x,x.y,x.z)/max(1,original.x,original.y,original.z)))
        }
        var base = fitP3(x*exp2(-g))
        if !settings.film.isIdentity, let stock = settings.film.stock, let film = try? FilmStock.named(stock) {
            let exposed = filmScene*exp2(Double(settings.film.exposure ?? 0))
            base = fitP3(base+(film.apply(exposed,grain:grain)-base)*Double(settings.film.strength))
        }
        if active && settings.look.input.isSDR {
            base = look(base,settings:settings.look)
            if !settings.look.output.isSDR {
                let hdr = base*exp2(g)
                g = log2(max(1,hdr.x,hdr.y,hdr.z))
                base = fitP3(hdr*exp2(-g))
            }
        }
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
        var gains = pair.gains
        for c in 0..<3 { gains[c] = max(gains[c],expansion)*Double(settings.strength) }
        let peak = (0..<3).map { base[$0]*exp2(gains[$0]) }.max()!
        if peak > 0 {
            gains += RGB(repeating: log2(max(softShoulder(peak,range:range,active:shoulder)/peak,1e-30)))
        }
        if allowRolloff && settings.sdrRolloff > 0 {
            let m = max(base.x,base.y,base.z)
            if m > 0.7 {
                let target = m+(0.7+0.3*(1-exp(-(m-0.7)/0.3))-m)*Double(settings.sdrRolloff)
                base *= target/m; gains += RGB(repeating: log2(m/target))
            }
        }
        return Split(base:base,gains:settings.enabled ? gains : .zero)
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
