import CoreImage
import Foundation
import Metal
import Testing
import HyperDRRecipe
@testable import HyperDRRender

private let filmPipelineNames = ["filmMeter", "graphFilmCells", "graphFilmExposure", "filmBlur"]

private struct FilmPipelineProbe {
    let bits: [UInt32]
    let creations: [String: Int]
}

private extension RenderEngine {
    /// Exercise real dispatches through distinct contexts, with either the
    /// engine's precompiled states or deliberately cold context-local states.
    func filmPipelineProbe(stock: FilmStockID, domain: InputDomain, precompiled: Bool) throws -> FilmPipelineProbe {
        let width = 64, height = 8
        let pixels = (0..<(width * height)).map { index -> SIMD4<Float> in
            let value = Float(index % 127) / 127
            return SIMD4(value * (domain == .sdr ? 1 : 4), value * 0.7 + 0.01, 0.2 + value * 0.3, 1)
        }
        let image = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: Self.workingColorSpace)
        let source = try self.source(image: image, domain: domain)
        var edit = RenderAdjustments()
        edit.film.stock = stock; edit.film.exposure = 0.5
        let lut = try lookupResources(nil), film = try filmResources(edit.film)
        var selected = pipelines
        if !precompiled { for name in filmPipelineNames { selected[name] = nil } }
        var bits: [UInt32] = []
        var creations: [String: Int] = [:]
        for _ in 0..<2 {
            try autoreleasepool {
                guard let command = queue.makeCommandBuffer(),
                      let meter = device.makeBuffer(length: width * height * 8, options: .storageModeShared),
                      let taps = device.makeBuffer(bytes: [SIMD4<Float>(0.25, 0.25, 0.25, 0),
                          SIMD4<Float>(0.5, 0.5, 0.5, 0), SIMD4<Float>(0.25, 0.25, 0.25, 0)],
                          length: 48, options: .storageModeShared) else { throw RenderError.allocationFailed }
                let context = RenderNodeContext(domain: domain, device: device, commandBuffer: command,
                    workingSpace: Self.workingColorSpace, library: library, pipelines: selected)
                let cells = try context.texture(width: width, height: height)
                let exposure = try context.texture(width: width, height: height)
                let blurred = try context.texture(width: width, height: height)
                var unused: UInt32 = 0
                try context.dispatch("filmMeter", width: height, height: 1,
                    textures: [source.texture], buffers: [meter], value: &unused)
                var p = graphUniform(source, edit, size: source.size,
                    region: CGRect(x: 0, y: 0, width: width, height: height))
                try context.dispatch("graphFilmCells", width: width, height: height,
                    textures: [source.texture, cells, lut.texture, film.texture], buffers: [lut.buffer, film.buffer], value: &p)
                try context.dispatch("graphFilmExposure", width: width, height: height,
                    textures: [source.texture, exposure, lut.texture, film.texture], buffers: [lut.buffer, film.buffer], value: &p)
                var blur = FilmBlurUniform(radius: 1, vertical: 0, accumulate: 0, unused: 0)
                try context.dispatch("filmBlur", width: width, height: height,
                    textures: [exposure, blurred], buffers: [taps], value: &blur)
                try finish(command)
#if DEBUG || HYPERDR_FILM_PROFILE
                for name in filmPipelineNames { creations[name, default: 0] += context.diagnosticPipelineCreations[name, default: 0] }
#endif
                for texture in [cells, exposure, blurred] { bits += Self.readTexture(texture).map(\.bitPattern) }
                bits += Array(UnsafeBufferPointer(start: meter.contents().bindMemory(to: Float.self,
                    capacity: width * height * 2), count: width * height * 2)).map(\.bitPattern)
            }
        }
        return FilmPipelineProbe(bits: bits, creations: creations)
    }
}

@Suite(.serialized) struct FilmPipelineReuseTests {
    @Test(arguments: FilmStockID.allCases, [InputDomain.sdr, .hdr])
    func engineStatesAvoidPerContextFilmCompilationAndPreserveBits(stock: FilmStockID, domain: InputDomain) async throws {
        let engine = try RenderEngine()
        let reused = try await engine.filmPipelineProbe(stock: stock, domain: domain, precompiled: true)
        let cold = try await engine.filmPipelineProbe(stock: stock, domain: domain, precompiled: false)
        #expect(!reused.bits.isEmpty && reused.bits == cold.bits)
#if DEBUG || HYPERDR_FILM_PROFILE
        for name in filmPipelineNames {
            #expect(reused.creations[name] == 0, "\(name) was compiled again in a render context")
            #expect(cold.creations[name] == 2, "the cold control must create one state in each context")
        }
#endif
    }
}
