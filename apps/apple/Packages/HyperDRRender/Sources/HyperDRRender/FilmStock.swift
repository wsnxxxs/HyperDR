import Foundation
import Synchronization
import Metal

/// Option ids of Recipe's `look.film`, one bundled resource each, in its menu order.
public enum FilmStockID: String, CaseIterable, Hashable, Sendable {
    case portra400, gold200, velvia100, kodachrome64
    case vision3500T = "vision3-500t"
}

/// Film emulation. The film exposes the scene before the HDR split (highlights reach
/// its shoulder) and its print becomes the SDR base; the gain is retained (L1).
public struct FilmAdjustments: Hashable, Sendable {
    public var stock: FilmStockID?
    public var strength: Float = RenderParameter.defaultNumber("look.filmStrength")
    /// The film's exposure compensation in stops; nil meters the original photo
    /// (`RenderEngine.filmMeter`). It adds to the light edits, which act on the scene.
    public var exposure: Float? = nil
    /// Scales the grain's standard deviation; 1 is the stock's own grain on a 35 mm frame.
    public var grain: Float = RenderParameter.defaultNumber("look.filmGrain")
    /// Scales the back-reflection halation; 1 is the stock's own.
    public var halation: Float = RenderParameter.defaultNumber("look.filmHalation")
    /// Off removes the antihalation layer (as CineStill does to Vision3), spektrafilm's
    /// 'no' strengths for the film's use.
    public var antihalation: Bool = RenderParameter.defaultBool("look.filmAntihalation")
    public init() {}
    public var isIdentity: Bool { stock == nil || strength == 0 }
    /// Analysis integrates cells, where grain averages out: it never invalidates them.
    var withoutGrain: FilmAdjustments { var value = self; value.grain = 0; return value }

    /// Output pixels a region of a render of `size` reads beyond its edges: the reach of
    /// the in-emulsion scatter. Sources cropped for a region (export tiles, detail
    /// regions) must cover this halo too.
    public func sourceHalo(size: PixelSize) -> Int {
        guard !isIdentity, let stock, let data = try? FilmStock.named(stock) else { return 0 }
        return data.scatterComponents(longEdge: max(size.width, size.height)).map { FilmStock.taps($0, truncate: FilmStock.scatterTruncate).radius }.max() ?? 0
    }
}

/// One separable Gaussian of a spatial effect: per-channel weight and sigma in pixels.
public struct FilmBlurComponent: Sendable {
    public var weight: SIMD3<Double>
    public var sigma: SIMD3<Double>
}

/// Where grain is drawn: an output pixel in the full render's coordinates. The noise is a
/// hash of these coordinates, so regions and stripes of one render agree.
public struct FilmGrainSite: Sendable {
    public var x: Int, y: Int
    /// The render's long edge in pixels: a 35 mm frame spans it.
    public var longEdge: Int
    public var amount: Double
    public init(x: Int, y: Int, longEdge: Int, amount: Double) {
        self.x = x; self.y = y; self.longEdge = longEdge; self.amount = amount
    }
}

/// A spektrafilm stock converted by `scripts/convert_spektrafilm_stocks.py`
/// (CC BY-SA 4.0, Andrea Volpato). The script resolves spectral upsampling,
/// illuminants, neutral print filters and curve fits; this type evaluates the
/// film per pixel: exposure through the film's sensitivities, development with
/// DIR couplers, printing through the enlarger onto paper (negatives), and
/// viewing the print or slide under its illuminant, with the scanner's black and
/// white levels. Grain follows spektrafilm's particle model through its variance and
/// 0.65-pixel blur. The spatial effects of exposure, in-emulsion scatter and
/// back-reflection halation, are separable Gaussians (`scatter`, `halationComponents`).
/// All inputs and outputs are linear Display P3.
public struct FilmStock: Sendable {
    public let id: FilmStockID
    public let name: String
    public let attribution: String
    let resource: FilmResource
    let spectralLUT: [SIMD3<Double>]

    /// Loads a stock on first use and keeps it.
    public static func named(_ id: FilmStockID) throws -> FilmStock {
        try cache.withLock { stocks in
            if let stock = stocks[id] { return stock }
            guard let json = Bundle.module.url(forResource: id.rawValue, withExtension: "json", subdirectory: "Film"),
                  let table = Bundle.module.url(forResource: id.rawValue, withExtension: "spectral", subdirectory: "Film")
            else { throw RenderError.invalidAdjustment }
            let stock = try FilmStock(id: id, data: Data(contentsOf: json), spectral: Data(contentsOf: table))
            stocks[id] = stock
            return stock
        }
    }

    private static let cache = Mutex<[FilmStockID: FilmStock]>([:])

    /// `spectral` is the chromaticity table: size × size × 3 little-endian float16.
    init(id: FilmStockID, data: Data, spectral bytes: Data) throws {
        let resource = try JSONDecoder().decode(FilmResource.self, from: data)
        let lut = resource.filming.spectralLUT
        guard resource.schema == "hyperdr.film/v1", resource.id == id.rawValue,
              bytes.count == lut.size * lut.size * 6,
              Self.isUniformCurve(resource.filming.logExposure, resource.filming.densityCurves),
              Self.isUniformCurve(resource.filming.logExposure, resource.filming.densityCurvesBeforeCouplers),
              resource.printing.map({ Self.isUniformCurve($0.logExposure, $0.densityCurves) }) ?? true,
              resource.filming.channelDensity.count == Self.wavelengths, resource.scanning.illuminant.count == Self.wavelengths,
              resource.filming.grain.varianceArea.count == Self.curveSamples, resource.scanning.levels.count == 2
        else { throw RenderError.invalidAdjustment }
        let floats = bytes.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }.map { Float(Float16(bitPattern: UInt16(littleEndian: $0))) }
        self.id = id
        self.name = resource.name
        self.attribution = resource.attribution
        self.resource = resource
        self.spectralLUT = stride(from: 0, to: floats.count, by: 3).map {
            SIMD3(Double(floats[$0]), Double(floats[$0 + 1]), Double(floats[$0 + 2]))
        }
    }

    public var isReversal: Bool { resource.printing == nil }

    // MARK: - Double reference

    public typealias RGB = SIMD3<Double>

    /// The full film, print and viewing chain for one linear-P3 colour.
    /// `halation` is the halation map's film exposure at this pixel and its per-channel
    /// strength; without it there is no halation.
    public func apply(_ rgb: RGB, grain site: FilmGrainSite? = nil, halation: (glow: RGB, strength: RGB)? = nil) -> RGB {
        var raw = filmRaw(rgb)
        if let halation { raw = (raw + halation.strength * halation.glow) / (1 + halation.strength) }
        return fromRaw(raw, grain: site)
    }

    /// From film exposure on: development, grain, print and viewing.
    public func fromRaw(_ raw: RGB, grain site: FilmGrainSite? = nil) -> RGB {
        let film = resource.filming
        var density = develop(logExposure: Self.log10(raw))
        if let site, site.amount > 0 { density = addGrain(density, at: site) }
        var dye = film.channelDensity, base = film.baseDensity
        if let paper = resource.printing {
            let transmitted = spectralTransmission(density, dye: film.channelDensity, base: film.baseDensity)
            var raw = RGB.zero
            for wavelength in transmitted.indices { raw += transmitted[wavelength] * paper.illuminant[wavelength] * Self.vector(paper.sensitivity[wavelength]) }
            raw *= paper.exposureScale
            density = Self.interpolate(Self.log10(raw), axis: paper.logExposure, table: paper.densityCurves)
            dye = paper.channelDensity; base = paper.baseDensity
        }
        let scan = resource.scanning
        let transmitted = spectralTransmission(density, dye: dye, base: base)
        var xyz = RGB.zero
        for wavelength in transmitted.indices { xyz += transmitted[wavelength] * scan.illuminant[wavelength] * Self.vector(scan.observer[wavelength]) }
        xyz = Self.exp10(Self.log10(xyz))
        let y = xyz.y, levelled = min(max(scan.levels[0] * y + scan.levels[1], 0), 1)
        xyz *= levelled / (y + 1e-10)
        return Self.multiply(scan.xyzToP3, xyz)
    }

    /// log10 film exposure: Hanatos 2025 upsampling, looked up by chromaticity
    /// (Mitchell–Netravali, reflected edges, as spektrafilm) and scaled by X+Y+Z.
    func filmExposure(_ rgb: RGB) -> RGB { Self.log10(filmRaw(rgb)) }

    /// Linear film exposure, before halation.
    public func filmRaw(_ rgb: RGB) -> RGB {
        let xyz = Self.multiply(resource.filming.p3ToReference, rgb)
        let sum = xyz.x + xyz.y + xyz.z
        let x = xyz.x / max(sum, 1e-10), y = xyz.y / max(sum, 1e-10)
        let tx = min(max((1 - x) * (1 - x), 0), 1), ty = min(max(y / max(1 - x, 1e-10), 0), 1)
        return sampleSpectralLUT(tx, ty) * sum * resource.filming.exposureScale
    }

    /// Per-channel halation strength for these settings; zero without halation.
    public func halationStrength(_ settings: FilmAdjustments) -> RGB {
        let halation = resource.filming.halation
        return Self.vector(settings.antihalation ? halation.strength : halation.strengthRemoved) * Double(settings.halation)
    }

    /// Micrometres per pixel of a render whose long edge spans the 35 mm frame.
    func pitch(longEdge: Int) -> Double {
        resource.filming.grain.filmFormatMillimetres * 1000 / Double(max(longEdge, 1))
    }

    /// Back-reflection halation on a grid of this long edge: `bounces` Gaussians of sigma
    /// sigma·√k, weighted decay^(k-1) and normalised. `widening` adds a variance in
    /// pixels² per channel (negative narrows, down to a tenth of a pixel).
    public func halationComponents(longEdge: Int, widening: RGB = .zero) -> [FilmBlurComponent] {
        let halation = resource.filming.halation
        let sigma = halation.sigmaMicrons / pitch(longEdge: longEdge)
        let decay = (0..<halation.bounces).map { Foundation.pow(halation.decay, Double($0)) }
        let total = decay.reduce(0, +)
        return decay.indices.map { k in
            let variance = sigma * sigma * Double(k + 1) + widening
            return FilmBlurComponent(weight: RGB(repeating: decay[k] / total), sigma: pointwiseMax(variance, RGB(repeating: 0.01)).squareRoot())
        }
    }

    /// Halation on the analysis cells, whose long edge is `cells`. Its glow feeds on the
    /// scattered exposure, so it widens by the scatter's variance; the render samples it
    /// with a cubic B-spline (variance 1/3 cell²) from cells that average their pixels
    /// (1/12), so it narrows by those.
    func halationMapComponents(cells: Int) -> [FilmBlurComponent] {
        halationComponents(longEdge: cells, widening: scatterVariance(longEdge: cells) - RGB(repeating: 1.0 / 3 + 1.0 / 12))
    }

    /// In-emulsion scatter on a render of this long edge, spektrafilm's energy-preserving
    /// mixture: (1 - tail weight) × a Gaussian core plus tail weight × an exponential
    /// tail (its three-Gaussian fit), blended with the identity by the scatter amount.
    public func scatterComponents(longEdge: Int) -> [FilmBlurComponent] {
        let scatter = resource.filming.scatter, pitch = pitch(longEdge: longEdge)
        let amount = scatter.amount, tail = Self.vector(scatter.tailWeight)
        guard amount > 0 else { return [] }
        var components = [FilmBlurComponent(weight: amount * (1 - tail), sigma: Self.vector(scatter.coreMicrons) / pitch)]
        for fit in scatter.tailFit {
            components.append(FilmBlurComponent(weight: amount * tail * fit[0], sigma: fit[1] * Self.vector(scatter.tailMicrons) / pitch))
        }
        if amount < 1 { components.append(FilmBlurComponent(weight: RGB(repeating: 1 - amount), sigma: .zero)) }
        return components
    }

    /// The scatter's variance per axis in pixels², which widens what it feeds (halation).
    func scatterVariance(longEdge: Int) -> RGB {
        scatterComponents(longEdge: longEdge).reduce(.zero) { $0 + $1.weight * $1.sigma * $1.sigma }
    }

    /// spektrafilm truncates its scatter FIR at three sigma; halation is untruncated
    /// there (a recursive filter), five sigma here.
    static let scatterTruncate = 3.0, halationTruncate = 5.0

    /// One axis of a component: Int(truncate·sigma + 0.5) taps each side per channel
    /// (zero beyond a channel's own), normalised per channel, times the weight when
    /// `weighted` (the first of the two passes).
    static func taps(_ component: FilmBlurComponent, truncate: Double, weighted: Bool = false) -> (radius: Int, taps: [RGB]) {
        let radii = (0..<3).map { Int(truncate * max(component.sigma[$0], 1e-6) + 0.5) }
        let radius = radii.max()!
        var taps = [RGB](repeating: .zero, count: 2 * radius + 1)
        for c in 0..<3 {
            let s = max(component.sigma[c], 1e-6)
            let g = (-radii[c]...radii[c]).map { Foundation.exp(-0.5 * Double($0 * $0) / (s * s)) }
            let sum = g.reduce(0, +)
            for (i, value) in g.enumerated() { taps[radius - radii[c] + i][c] = value / sum * (weighted ? component.weight[c] : 1) }
        }
        return (radius, taps)
    }

    /// scipy.ndimage's 'reflect' edges: (d c b a | a b c d | d c b a).
    static func reflect(_ i: Int, _ n: Int) -> Int {
        let period = 2 * n, j = ((i % period) + period) % period
        return j < n ? j : period - 1 - j
    }

    /// The sum of the components' separable blurs of a row-major field.
    static func blur(_ field: [RGB], width: Int, height: Int, components: [FilmBlurComponent], truncate: Double) -> [RGB] {
        var result = [RGB](repeating: .zero, count: field.count)
        for component in components {
            let (radius, horizontal) = taps(component, truncate: truncate, weighted: true), vertical = taps(component, truncate: truncate).taps
            var pass = [RGB](repeating: .zero, count: field.count)
            for y in 0..<height { for x in 0..<width {
                var sum = RGB.zero
                for k in -radius...radius { sum += horizontal[k + radius] * field[y * width + reflect(x + k, width)] }
                pass[y * width + x] = sum
            } }
            for y in 0..<height { for x in 0..<width {
                var sum = RGB.zero
                for k in -radius...radius { sum += vertical[k + radius] * pass[reflect(y + k, height) * width + x] }
                result[y * width + x] += sum
            } }
        }
        return result
    }

    /// In-emulsion scatter of a field of film exposure, rendered at this long edge.
    public func scatter(_ raw: [RGB], width: Int, height: Int, longEdge: Int) -> [RGB] {
        Self.blur(raw, width: width, height: height, components: scatterComponents(longEdge: longEdge), truncate: Self.scatterTruncate)
    }

    /// Developed density plus grain: per channel, the variance of the sublayer particle
    /// model at this density and pixel area, times blurred unit noise.
    func addGrain(_ density: RGB, at site: FilmGrainSite) -> RGB {
        let film = resource.filming, inverseArea = Self.inverseArea(longEdge: site.longEdge, film: film)
        let weights = Self.grainWeights(film.grain.blur)
        var result = density
        for c in 0..<3 {
            let variance = Self.interpolate(SIMD3(repeating: density[c] / film.densityMaximum[c] * 255),
                                            axis: [0, 255, 256], table: film.grain.varianceArea)[c]
            var noise = 0.0
            for dy in -1...1 { for dx in -1...1 {
                noise += weights[abs(dx) + abs(dy)] * Double(Self.grainNoise(site.x + dx, site.y + dy, c))
            } }
            result[c] = max(0, density[c] + site.amount * (max(variance, 0) * inverseArea).squareRoot() * noise)
        }
        return result
    }

    static func inverseArea(longEdge: Int, film: FilmResource.Filming) -> Double {
        let pitch = film.grain.filmFormatMillimetres * 1000 / Double(max(longEdge, 1))
        return 1 / (pitch * pitch)
    }

    /// A 3×3 Gaussian (centre, edge, corner weights), scaled so the blurred noise keeps
    /// the standard deviation of spektrafilm's 5×5 kernel (truncated at 3 sigma).
    static func grainWeights(_ sigma: Double) -> [Double] {
        func taps(_ radius: Int) -> [Double] {
            let w = (-radius...radius).map { Foundation.exp(-Double($0 * $0) / (2 * sigma * sigma)) }
            let sum = w.reduce(0, +); return w.map { $0 / sum }
        }
        func energy(_ w: [Double]) -> Double { let e = w.map { $0 * $0 }.reduce(0, +); return e * e }
        let three = taps(1), amplitude = (energy(taps(2)) / energy(three)).squareRoot()
        return [three[1] * three[1] * amplitude, three[0] * three[1] * amplitude, three[0] * three[0] * amplitude]
    }

    /// Unit normal noise from a hash of pixel and channel (Box–Muller on lowbias32).
    /// Film.metal computes the same bits.
    static func grainNoise(_ x: Int, _ y: Int, _ channel: Int) -> Float {
        func hash(_ value: UInt32) -> UInt32 {
            var v = value
            v ^= v >> 16; v = v &* 0x7feb352d; v ^= v >> 15; v = v &* 0x846ca68b; v ^= v >> 16
            return v
        }
        let h = hash(UInt32(bitPattern: Int32(truncatingIfNeeded: x)) &+ hash(UInt32(bitPattern: Int32(truncatingIfNeeded: y)) &+ hash(UInt32(channel) &+ 0x9e3779b9)))
        let u1 = Float(h >> 8) * 0x1p-24 + 0x1p-25, u2 = Float(hash(h) >> 8) * 0x1p-24
        return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * Float.pi * u2)
    }

    /// Density curves, then DIR couplers: developed density inhibits the exposure
    /// of its own and the other layers, read through the curves before couplers.
    func develop(logExposure: RGB) -> RGB {
        let film = resource.filming
        let density = Self.interpolate(logExposure, axis: film.logExposure, table: film.densityCurves)
        let silver = film.type == "positive" ? Self.vector(film.densityMaximum) - density : density
        var inhibited = logExposure
        for donor in 0..<3 { for receiver in 0..<3 { inhibited[receiver] -= silver[donor] * film.couplers[donor][receiver] } }
        return Self.interpolate(inhibited, axis: film.logExposure, table: film.densityCurvesBeforeCouplers)
    }

    private func spectralTransmission(_ density: RGB, dye: [[Double]], base: [Double]) -> [Double] {
        dye.indices.map { wavelength in
            Foundation.exp(-2.302585092994046 * ((density * Self.vector(dye[wavelength])).sum() + base[wavelength]))
        }
    }

    private func sampleSpectralLUT(_ x: Double, _ y: Double) -> RGB {
        let size = resource.filming.spectralLUT.size
        func cell(_ coordinate: Double) -> (Int, Double) {
            let c = min(max(coordinate * Double(size - 1), 0), Double(size - 1))
            if c >= Double(size - 1) { return (size - 2, 1) }
            return (Int(c.rounded(.down)), c - c.rounded(.down))
        }
        func reflect(_ i: Int) -> Int { i < 0 ? -i : i >= size ? 2 * (size - 1) - i : i }
        let (xb, xf) = cell(x), (yb, yf) = cell(y)
        var sum = RGB.zero, weights = 0.0
        for i in 0..<4 {
            for j in 0..<4 {
                let w = Self.mitchell(xf + 1 - Double(i)) * Self.mitchell(yf + 1 - Double(j))
                sum += w * spectralLUT[reflect(xb - 1 + i) * size + reflect(yb - 1 + j)]
                weights += w
            }
        }
        return weights != 0 ? sum / weights : sum
    }

    static func mitchell(_ t: Double) -> Double {
        let x = abs(t), b = 1.0 / 3, c = 1.0 / 3
        if x < 1 { return ((12 - 9 * b - 6 * c) * x * x * x + (-18 + 12 * b + 6 * c) * x * x + (6 - 2 * b)) / 6 }
        if x < 2 { return ((-b - 6 * c) * x * x * x + (6 * b + 30 * c) * x * x + (-12 * b - 48 * c) * x + (8 * b + 24 * c)) / 6 }
        return 0
    }

    /// Per-channel linear interpolation on a uniform axis, clamped at both ends.
    static func interpolate(_ value: RGB, axis: [Double], table: [[Double]]) -> RGB {
        let low = axis[0], high = axis[1], count = Int(axis[2])
        var result = RGB.zero
        for c in 0..<3 {
            let t = min(max((value[c] - low) / (high - low) * Double(count - 1), 0), Double(count - 1))
            let i = min(Int(t.rounded(.down)), count - 2), f = t - Double(i)
            result[c] = table[i][c] * (1 - f) + table[i + 1][c] * f
        }
        return result
    }

    /// spektrafilm's log10(max(x, 0) + 1e-10).
    static func log10(_ x: RGB) -> RGB { RGB(Foundation.log10(max(x.x, 0) + 1e-10), Foundation.log10(max(x.y, 0) + 1e-10), Foundation.log10(max(x.z, 0) + 1e-10)) }
    static func exp10(_ x: RGB) -> RGB { RGB(Foundation.pow(10, x.x), Foundation.pow(10, x.y), Foundation.pow(10, x.z)) }
    static func vector(_ v: [Double]) -> RGB { RGB(v[0], v[1], v[2]) }
    static func multiply(_ m: [[Double]], _ v: RGB) -> RGB {
        RGB((vector(m[0]) * v).sum(), (vector(m[1]) * v).sum(), (vector(m[2]) * v).sum())
    }

    // MARK: - GPU tables

    /// Float4 rows in the layout of `FilmData` in Film.metal.
    func packed() -> [SIMD4<Float>] {
        let film = resource.filming, scan = resource.scanning
        func row(_ v: [Double], _ w: Double = 0) -> SIMD4<Float> { SIMD4(Float(v[0]), Float(v[1]), Float(v[2]), Float(w)) }
        func row(_ v: RGB, _ w: Double = 0) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), Float(w)) }
        let paperAxis = resource.printing?.logExposure ?? film.logExposure
        var rows: [SIMD4<Float>] = film.p3ToReference.map { row($0) } + film.couplers.map { row($0) }
            + scan.xyzToP3.map { row($0) }
        rows.append(row(film.densityMaximum))
        rows.append(SIMD4(Float(film.logExposure[0]), Float(film.logExposure[1]), Float(paperAxis[0]), Float(paperAxis[1])))
        rows.append(SIMD4(film.type == "positive" ? 1 : 0, resource.printing == nil ? 0 : 1,
                          Float(resource.printing?.exposureScale ?? 1), Float(film.spectralLUT.size)))
        let weights = Self.grainWeights(film.grain.blur)
        rows.append(SIMD4(Float(film.exposureScale), Float(scan.levels[0]), Float(scan.levels[1]), 0))
        rows.append(SIMD4(Float(weights[0]), Float(weights[1]), Float(weights[2]), Float(film.grain.filmFormatMillimetres)))
        rows += film.densityCurves.map { row($0) } + film.densityCurvesBeforeCouplers.map { row($0) }
        rows += (resource.printing?.densityCurves ?? film.densityCurves).map { row($0) }
        rows += film.channelDensity.indices.map { row(film.channelDensity[$0], film.baseDensity[$0]) }
        let scanned = resource.printing.map { ($0.channelDensity, $0.baseDensity) } ?? (film.channelDensity, film.baseDensity)
        rows += scanned.0.indices.map { row(scanned.0[$0], scanned.1[$0]) }
        rows += film.channelDensity.indices.map { wavelength in
            guard let paper = resource.printing else { return .zero }
            return row(paper.illuminant[wavelength] * Self.vector(paper.sensitivity[wavelength]))
        }
        rows += scan.illuminant.indices.map { row(scan.illuminant[$0] * Self.vector(scan.observer[$0])) }
        rows += film.grain.varianceArea.map { row($0) }
        return rows
    }

    static let curveSamples = 256, wavelengths = 81

    private static func isUniformCurve(_ axis: [Double], _ table: [[Double]]) -> Bool {
        axis.count == 3 && Int(axis[2]) == curveSamples && table.count == curveSamples && axis[0] < axis[1]
    }

    func spectralTexture(_ device: any MTLDevice) throws -> any MTLTexture {
        let size = resource.filming.spectralLUT.size
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: size, height: size, mipmapped: false)
        descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.allocationFailed }
        // Texel (x, y) holds spektrafilm's lut[x][y]: the first index is the column.
        var texels = [SIMD4<Float>](repeating: .zero, count: size * size)
        for i in 0..<size { for j in 0..<size {
            let v = spectralLUT[i * size + j]
            texels[j * size + i] = SIMD4(Float(v.x), Float(v.y), Float(v.z), 0)
        } }
        texels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                                                  withBytes: $0.baseAddress!, bytesPerRow: size * 16) }
        return texture
    }
}

struct FilmResource: Decodable, Sendable {
    struct SpectralLUT: Decodable, Sendable { let size: Int }
    struct Halation: Decodable, Sendable {
        let sigmaMicrons, decay: Double
        let bounces: Int
        let strength, strengthRemoved: [Double]
    }
    struct Scatter: Decodable, Sendable {
        let amount: Double
        let coreMicrons, tailMicrons, tailWeight: [Double]
        /// Amplitude and sigma over decay of the exponential tail's Gaussians.
        let tailFit: [[Double]]
    }
    struct Grain: Decodable, Sendable {
        /// Density variance × pixel area (µm²), 256 samples from zero to each channel's maximum.
        let varianceArea: [[Double]]
        /// Gaussian blur in pixels.
        let blur: Double
        let filmFormatMillimetres: Double
    }
    struct Filming: Decodable, Sendable {
        let type: String
        let p3ToReference: [[Double]]
        let spectralLUT: SpectralLUT
        /// First value, last value and sample count of a uniform log10 exposure axis.
        let logExposure: [Double]
        let densityCurves, densityCurvesBeforeCouplers, couplers: [[Double]]
        let densityMaximum: [Double]
        let channelDensity: [[Double]]
        let baseDensity: [Double]
        /// The scanner's correction of a slide's exposure (1 for negatives).
        let exposureScale: Double
        let grain: Grain
        let halation: Halation
        let scatter: Scatter
    }
    struct Printing: Decodable, Sendable {
        let illuminant: [Double]
        let sensitivity: [[Double]]
        let exposureScale: Double
        let logExposure: [Double]
        let densityCurves, channelDensity: [[Double]]
        let baseDensity: [Double]
    }
    struct Scanning: Decodable, Sendable {
        let illuminant: [Double]
        let observer, xyzToP3: [[Double]]
        /// Slope and offset of the scanner's black and white levels on Y.
        let levels: [Double]
    }
    let schema, id, name, attribution: String
    let filming: Filming
    let printing: Printing?
    let scanning: Scanning
}
