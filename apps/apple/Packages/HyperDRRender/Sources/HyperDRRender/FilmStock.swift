import Foundation
import Accelerate
import Synchronization
import Metal

/// Option ids of Recipe's `look.film`, one bundled resource each, in its menu order.
public enum FilmStockID: String, CaseIterable, Hashable, Sendable {
    case portra160, portra400, portra800
    case portra800Push1 = "portra800-push1", portra800Push2 = "portra800-push2"
    case ektar100, gold200, ultramax400, pro400h, c200, xtra400
    case velvia100, provia100f, kodachrome64, ektachrome100
    case vision350D = "vision3-50d", vision3250D = "vision3-250d"
    case vision3200T = "vision3-200t", vision3500T = "vision3-500t", verita200d
}

/// Film emulation. The film exposes the scene before the HDR split (highlights reach
/// its shoulder) and its print becomes the SDR base. Captured highlight luminance
/// is preserved separately from the print's tone compression.
public struct FilmAdjustments: Hashable, Sendable {
    public var stock: FilmStockID?
    public var strength: Float = RenderParameter.defaultNumber("look.filmStrength")
    /// The film's exposure compensation in stops; nil meters the original photo
    /// (`RenderEngine.filmMeter`). It adds to the light edits, which act on the scene.
    public var exposure: Float? = nil
    /// Off removes the antihalation layer (as CineStill does to Vision3), spektrafilm's
    /// 'no' strengths for the film's use.
    public var antihalation: Bool = RenderParameter.defaultBool("look.filmAntihalation")
    public init() {}
    public var isIdentity: Bool { stock == nil || strength == 0 }
    /// Output pixels a region of a render of `size` reads beyond its edges: the reach of
    /// the in-emulsion scatter. Sources cropped for a region (export tiles, detail
    /// regions) must cover this halo too. This is the conservative reach of the
    /// selected stock, independent of its colour strength. RenderAdjustments filters
    /// it to zero when neither stock colour nor stock effects are being rendered.
    public func sourceHalo(size: PixelSize) -> Int {
        guard let stock, let data = try? FilmStock.named(stock) else { return 0 }
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
/// white levels. Grain follows spektrafilm's sublayer particle model (`addGrain`). The spatial effects of exposure, in-emulsion scatter and
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
              resource.filming.grain.layers.count == 3, resource.filming.grain.layers.allSatisfy({ $0.varianceArea.count == Self.curveSamples }),
              resource.filming.grain.layers.allSatisfy({ $0.thirdCumulantArea2.count == Self.curveSamples }), resource.scanning.levels.count == 2
        else { throw RenderError.invalidAdjustment }
        var words = bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [UInt16] in
            buffer.bindMemory(to: UInt16.self).map { UInt16(littleEndian: $0) }
        }
        // Xcode also compiles Swift packages for x86_64 in Release, where
        // Swift's Float16 is unavailable. Use the same vImage path as model gain.
        var floats = [Float](repeating: 0, count: words.count)
        let status = words.withUnsafeMutableBytes { input in
            floats.withUnsafeMutableBytes { output in
                var source = vImage_Buffer(data: input.baseAddress!, height: 1,
                    width: vImagePixelCount(input.count / 2), rowBytes: input.count)
                var destination = vImage_Buffer(data: output.baseAddress!, height: 1,
                    width: source.width, rowBytes: output.count)
                return vImageConvert_Planar16FtoPlanarF(&source, &destination, vImage_Flags(kvImageNoFlags))
            }
        }
        guard status == kvImageNoError else { throw RenderError.invalidAdjustment }
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

    /// Apply the same restrained green balance to still negatives sharing Portra
    /// Endura. This rendering choice leaves their physical calibration separate.
    var greenBalance: Double { resource.print == "kodak_portra_endura" ? 0.7 : 0 }

    /// The stock rendition, with a gentle shared-paper green balance. Physical
    /// grain/halation are added as an RGB delta after the colour correction.
    public func apply(_ rgb: RGB, grain site: FilmGrainSite? = nil, halation: (glow: RGB, strength: RGB)? = nil) -> RGB {
        renderFromRaw(filmRaw(rgb), reference: rgb, grain: site, halation: halation)
    }

    /// Reuses a scattered exposure; reference is the edited scene at this pixel.
    public func renderFromRaw(_ raw: RGB, reference: RGB, grain site: FilmGrainSite? = nil,
                              halation: (glow: RGB, strength: RGB)? = nil) -> RGB {
        let exposed = halation.map { (raw + $0.strength * $0.glow) / (1 + $0.strength) } ?? raw
        let completed = DoubleReference.fitP3(fromRaw(exposed, grain: site))
        let amount = greenBalance > 0 ? greenBalance * Self.greenWeight(reference) : 0
        guard amount > 0 else { return completed }
        let physical = (site?.amount ?? 0) > 0 || halation != nil
        let plain = physical ? DoubleReference.fitP3(fromRaw(raw)) : completed
        let balanced = Self.balanceGreens(plain, reference: reference, amount: amount)
        return balanced == plain ? completed : DoubleReference.fitP3(balanced + (completed - plain))
    }

    /// Smooth membership, including green dominance, protects true yellows and
    /// the surrounding palette. Neutral colours and cyan/blue never enter it.
    static func greenWeight(_ reference: RGB) -> Double {
        let lab = DoubleReference.oklab(reference / max(1, DoubleReference.luma(reference)))
        var hue = atan2(lab.z, lab.y) * 180 / Double.pi
        if hue < 0 { hue += 360 }
        let relative = hypot(lab.y, lab.z) / max(0.001, lab.x)
        let dominance = (reference.y - max(reference.x, reference.z)) / max(1e-6, reference.max())
        return DoubleReference.smoothStep(100, 116, hue) * (1 - DoubleReference.smoothStep(165, 185, hue))
            * DoubleReference.smoothStep(0, 0.08, dominance) * DoubleReference.smoothStep(0.015, 0.06, relative)
    }

    /// Only relieve a material yellowward shift in greens. Keep 30% of that
    /// shift, all mild warmth, luminance and relative chroma. A radial P3 fit
    /// reduces chroma only where the gentler hue needs room in the gamut.
    static func balanceGreens(_ scanned: RGB, reference: RGB, amount: Double) -> RGB {
        let source = DoubleReference.oklab(reference / max(1, DoubleReference.luma(reference)))
        let colour = DoubleReference.oklab(scanned)
        let hue = atan2(colour.z, colour.y)
        let delta = atan2(sin(atan2(source.z, source.y) - hue), cos(atan2(source.z, source.y) - hue))
        let turn = amount * max(0, delta) * DoubleReference.smoothStep(2 * Double.pi / 180, 6 * Double.pi / 180, delta)
        guard turn > 1e-9 else { return scanned }
        let y = DoubleReference.luma(scanned)
        guard y > 1e-8 && y < 1 else { return scanned }
        let chroma = hypot(colour.y, colour.z)
        let a = chroma * cos(hue + turn), b = chroma * sin(hue + turn)
        func candidate(_ strength: Double) -> RGB {
            DoubleReference.preserveLuminance(DoubleReference.oklabRGB(RGB(colour.x, a * strength, b * strength)), target: y)
        }
        func fits(_ rgb: RGB) -> Bool { rgb.min() >= 0 && rgb.max() <= 1 }
        let full = candidate(1)
        if fits(full) { return full }
        var low = 0.0, high = 1.0, best = RGB(repeating: y)
        for _ in 0..<16 {
            let mid = (low + high) / 2, rgb = candidate(mid)
            if fits(rgb) { low = mid; best = rgb } else { high = mid }
        }
        return best
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

    /// Per-channel stock halation strength, scaled by the independent effect amount.
    public func halationStrength(_ settings: FilmAdjustments, amount: Float = 1) -> RGB {
        let halation = resource.filming.halation
        return Self.vector(settings.antihalation ? halation.strength : halation.strengthRemoved) * Double(amount)
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

    /// Developed density plus grain, spektrafilm's sublayer particle model. Per channel,
    /// each sublayer has a density variance and third cumulant (Poisson particle counts)
    /// at this density and pixel area, and a kernel: its dye clouds (micrometres) then the
    /// scan's blur (pixels), both sampled as spektrafilm's FIR blurs. One field of hashed
    /// noise goes through the sublayers' kernels mixed by variance, scaled to the variance
    /// and bent (Cornish–Fisher, solved exactly) to the third moment that the separately
    /// blurred sublayers would have. Film.metal computes the same.
    func addGrain(_ density: RGB, at site: FilmGrainSite) -> RGB {
        let grain = resource.filming.grain, area = Foundation.pow(pitch(longEdge: site.longEdge), 2)
        let kernel = grainKernel(longEdge: site.longEdge)
        let t = RGB((0..<3).map { density[$0] / resource.filming.densityMaximum[$0] * 255 })
        let axis = [0.0, 255, 256]
        let variance = grain.layers.map { pointwiseMax(Self.interpolate(t, axis: axis, table: $0.varianceArea), .zero) / area }
        let third = grain.layers.map { pointwiseMax(Self.interpolate(t, axis: axis, table: $0.thirdCumulantArea2), .zero) / (area * area) }
        let total = variance.reduce(.zero, +)
        var result = density
        for c in 0..<3 where total[c] > 0 {
            // The mixed kernel is a variance-weighted sum of separable Gaussians, so its sums
            // of squares and cubes follow from the sublayers' cross sums.
            let a = (0..<3).map { variance[$0][c] / total[c] }
            var target2 = 0.0, target3 = 0.0, energy2 = 0.0, energy3 = 0.0
            for l in 0..<3 {
                target2 += variance[l][c] * kernel.target2[l][c]
                target3 += third[l][c] * kernel.target3[l][c]
                for m in 0..<3 {
                    energy2 += a[l] * a[m] * kernel.square[l][m][c]
                    for n in 0..<3 { energy3 += a[l] * a[m] * a[n] * kernel.cube[l][m][n][c] }
                }
            }
            func weight(_ dx: Int, _ dy: Int) -> Double {
                (0..<3).reduce(0) { $0 + a[$1] * kernel.taps[$1][abs(dx)][c] * kernel.taps[$1][abs(dy)][c] }
            }
            let scale = (target2 / energy2).squareRoot(), bend = Self.cornishFisher(target3 / (scale * scale * scale * energy3))
            var noise = 0.0
            for dy in -kernel.radius...kernel.radius { for dx in -kernel.radius...kernel.radius {
                let z = Double(Self.grainNoise(site.x + dx, site.y + dy)[c])
                noise += weight(dx, dy) * (z + bend * (z * z - 1))
            } }
            result[c] = max(-grain.densityMinimum[c], density[c] + site.amount * scale * noise / (1 + 2 * bend * bend).squareRoot())
        }
        return result
    }

    /// The sublayers' grain kernels for a render of this long edge, which only the pixel
    /// pitch sets: per sublayer, one side of its dye clouds convolved with the scan
    /// (centre first, per channel), cut where no tap reaches 5 % of its centre; the 2D
    /// cross sums of two and of three sublayers' cut kernels, squared (a product of
    /// separable kernels sums to the square of its axis); each sublayer's whole kernel's
    /// sums of squares and cubes, which set the grain's variance and third moment (the cut
    /// kernel is rescaled to them); and the reach.
    func grainKernel(longEdge: Int) -> GrainKernel {
        let key = GrainKernelKey(stock: id, longEdge: longEdge)
        if let kernel = Self.grainKernels.withLock({ $0[key] }) { return kernel }
        let grain = resource.filming.grain, pitch = pitch(longEdge: longEdge), scan = Self.sampledGaussian(grain.blur)
        var whole = [[RGB]](), radius = 0
        for layer in grain.layers {
            var side = [RGB](repeating: .zero, count: Self.grainRadius + 1)
            for c in 0..<3 {
                let g = Self.foldedConvolution(Self.sampledGaussian(layer.dyeCloudMicrons[c] / pitch), scan)
                for k in g.indices { side[k][c] = g[k] }
                radius = max(radius, g.lastIndex { $0 >= 0.05 * g[0] } ?? 0)
            }
            whole.append(side)
        }
        let taps = whole.map { side in side.indices.map { $0 <= radius ? side[$0] : .zero } }
        func sums(_ l: Int, _ power: Double) -> RGB {
            let sum = whole[l].indices.reduce(RGB.zero) { total, k in
                total + (k == 0 ? 1 : 2) * RGB((0..<3).map { Foundation.pow(whole[l][k][$0], power) })
            }
            return sum * sum
        }
        func axis(_ layers: [Int]) -> RGB {
            let sum = (0...Self.grainRadius).reduce(RGB.zero) { total, k in
                total + (k == 0 ? 1 : 2) * layers.reduce(RGB(repeating: 1)) { $0 * taps[$1][k] }
            }
            return sum * sum
        }
        let square = (0..<3).map { l in (0..<3).map { m in axis([l, m]) } }
        let cube = (0..<3).map { l in (0..<3).map { m in (0..<3).map { n in axis([l, m, n]) } } }
        let kernel = GrainKernel(taps: taps, square: square, cube: cube, target2: (0..<3).map { sums($0, 2) },
                                 target3: (0..<3).map { sums($0, 3) }, radius: radius)
        Self.grainKernels.withLock { if $0.count > 64 { $0.removeAll() }; $0[key] = kernel }
        return kernel
    }

    typealias GrainKernel = (taps: [[RGB]], square: [[RGB]], cube: [[[RGB]]], target2: [RGB], target3: [RGB], radius: Int)
    private struct GrainKernelKey: Hashable { let stock: FilmStockID; let longEdge: Int }
    private static let grainKernels = Mutex<[GrainKernelKey: GrainKernel]>([:])

    /// `grainKernel` in the rows Film.metal's `filmGrain` reads: taps (3 × 7), squares
    /// (3 × 3), cubes (3 × 3 × 3), whole squares (3), whole cubes (3), reach.
    func packedGrainKernel(longEdge: Int) -> [SIMD4<Float>] {
        let kernel = grainKernel(longEdge: longEdge)
        func row(_ v: RGB) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), 0) }
        return kernel.taps.flatMap { $0.map(row) } + kernel.square.flatMap { $0.map(row) }
            + kernel.cube.flatMap { $0.flatMap { $0.map(row) } } + kernel.target2.map(row) + kernel.target3.map(row)
            + [SIMD4(Float(kernel.radius), 0, 0, 0)]
    }

    /// a such that z + a(z² - 1), z standard normal, has this skewness (at most 2.5):
    /// (6a + 8a³) / (1 + 2a²)^1.5, by Newton's method from the small-skew a = skew / 6.
    static func cornishFisher(_ skew: Double) -> Double {
        let target = min(max(skew, 0), 2.5)
        var a = target / 6
        for _ in 0..<4 {
            let q = 1 + 2 * a * a, root = q.squareRoot(), n = 6 * a + 8 * a * a * a
            a -= (n / (q * root) - target) / (((6 + 24 * a * a) * q - n * 6 * a) / (q * q * root))
        }
        return a
    }

    /// The grain kernel's reach in pixels, at most.
    static let grainRadius = 6

    /// A Gaussian sampled at whole pixels out to Int(3 sigma + 0.5) and normalised, as
    /// spektrafilm's FIR blurs; one side, centre first.
    static func sampledGaussian(_ sigma: Double) -> [Double] {
        let radius = Int(3 * max(sigma, 1e-6) + 0.5)
        let g = (0...radius).map { Foundation.exp(-0.5 * Double($0 * $0) / (sigma * sigma)) }
        let sum = g[0] + 2 * g[1...].reduce(0, +)
        return g.map { $0 / sum }
    }

    /// Two symmetric kernels (one side each) convolved, truncated at `grainRadius`:
    /// a sublayer's dye clouds, then the scan.
    static func foldedConvolution(_ a: [Double], _ b: [Double]) -> [Double] {
        func at(_ k: [Double], _ i: Int) -> Double { abs(i) < k.count ? k[abs(i)] : 0 }
        return (0...grainRadius).map { i in
            (-(a.count - 1)...(a.count - 1)).reduce(0) { $0 + at(a, $1) * at(b, i - $1) }
        }
    }

    static func inverseArea(longEdge: Int, film: FilmResource.Filming) -> Double {
        let pitch = film.grain.filmFormatMillimetres * 1000 / Double(max(longEdge, 1))
        return 1 / (pitch * pitch)
    }

    /// Unit normal noise of a pixel's three channels from one hash of its position:
    /// Box–Muller's cosine and sine for red and green, a second draw for blue (lowbias32
    /// hashes). Film.metal computes the same bits.
    static func grainNoise(_ x: Int, _ y: Int) -> SIMD3<Float> {
        func hash(_ value: UInt32) -> UInt32 {
            var v = value
            v ^= v >> 16; v = v &* 0x7feb352d; v ^= v >> 15; v = v &* 0x846ca68b; v ^= v >> 16
            return v
        }
        func uniform(_ h: UInt32) -> Float { Float(h >> 8) * 0x1p-24 }
        let h0 = hash(UInt32(bitPattern: Int32(truncatingIfNeeded: x)) &+ hash(UInt32(bitPattern: Int32(truncatingIfNeeded: y)) &+ 0x9e3779b9))
        let h1 = hash(h0), h2 = hash(h1), h3 = hash(h2)
        let r = (-2 * Foundation.log(uniform(h0) + 0x1p-25)).squareRoot(), angle = 2 * Float.pi * uniform(h1)
        let blue = (-2 * Foundation.log(uniform(h2) + 0x1p-25)).squareRoot() * Foundation.cos(2 * Float.pi * uniform(h3))
        return SIMD3(r * Foundation.cos(angle), r * Foundation.sin(angle), blue)
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
        rows.append(SIMD4(Float(film.exposureScale), Float(scan.levels[0]), Float(scan.levels[1]), 0))
        rows.append(row(film.grain.densityMinimum, film.grain.blur))
        rows.append(SIMD4(Float(film.grain.filmFormatMillimetres), Float(greenBalance), 0, 0))
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
        for layer in film.grain.layers { rows += layer.varianceArea.map { row($0) } }
        for layer in film.grain.layers { rows += layer.thirdCumulantArea2.map { row($0) } }
        rows += film.grain.layers.map { row($0.dyeCloudMicrons) }
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
    struct GrainLayer: Decodable, Sendable {
        /// Density variance × pixel area (µm²), 256 samples from zero to each channel's maximum.
        let varianceArea: [[Double]]
        /// Third cumulant of density × pixel area² (µm⁴), as `varianceArea`.
        let thirdCumulantArea2: [[Double]]
        /// Sigma of the sublayer's dye clouds per channel.
        let dyeCloudMicrons: [Double]
    }
    struct Grain: Decodable, Sendable {
        /// Sublayers, fastest first.
        let layers: [GrainLayer]
        /// The scan's Gaussian blur in pixels.
        let blur: Double
        /// Particles develop on top of this density: grain never goes below its negative.
        let densityMinimum: [Double]
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
    let print: String?
    let filming: Filming
    let printing: Printing?
    let scanning: Scanning
}
