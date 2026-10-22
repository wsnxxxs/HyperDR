import XCTest
@testable import HyperDR

final class ScopeAnalyzerTests: XCTestCase {
    func testKnownSDRAndHDRBinsAndWaveformColumns() throws {
        let base: [Float] = [0, 0, 0, 1, 1, 1, 0.25, 0.25, 0.25, 1, 1, 1]
        let input = ScopeInput(width: 2, height: 2, base: base, gainWidth: 2, gainHeight: 2,
                               gainChannels: 1, gain: [0, 0, 0, 1], gainMax: 2)
        let result = try XCTUnwrap(ScopeAnalyzer.analyze(input, waveform: true))
        XCTAssertEqual(result.histogram.total, 4)
        var expected = [UInt32](repeating: 0, count: 256)
        for bin in [0, 179, 96, 217] { expected[bin] = 1 }
        XCTAssertEqual(result.histogram.luma, expected)
        XCTAssertEqual(result.histogram.red, expected)
        XCTAssertEqual(result.histogram.green, expected)
        XCTAssertEqual(result.histogram.blue, expected)
        let waveform = try XCTUnwrap(result.waveform)
        XCTAssertEqual(waveform.columns, 2)
        var wave = [UInt32](repeating: 0, count: 512)
        for (row, column) in [(0, 0), (179, 1), (96, 0), (217, 1)] { wave[row * 2 + column] = 1 }
        XCTAssertEqual(waveform.counts, wave)
        XCTAssertEqual(ScopeAnalyzer.position(1), 0.7, accuracy: 1e-6)
        XCTAssertEqual(ScopeAnalyzer.position(4), 0.85, accuracy: 1e-6)
        XCTAssertEqual(ScopeAnalyzer.position(16), 1)
    }

    func testCompactGainUsesGammaOffsetsAndBilinearSampling() throws {
        // At x=1 the half-size gain map interpolates to 0.25; inverse gamma
        // (1/2) makes this 0.5, so the reconstructed middle pixel is 2.
        let input = ScopeInput(width: 4, height: 1, base: [Float](repeating: 0.75, count: 12),
                               gainWidth: 2, gainHeight: 1, gainChannels: 1, gain: [0, 1],
                               gainMax: 4, gainGamma: 2, baseOffset: 0.25, alternateOffset: 2)
        let result = try XCTUnwrap(ScopeAnalyzer.analyze(input, waveform: true))
        XCTAssertEqual(result.histogram.luma[0], 1)
        XCTAssertEqual(result.waveform?.counts[198 * 4 + 1], 1)
        XCTAssertEqual(result.histogram.luma.reduce(0, +), 4)
    }

    func testRGBHDRPlaneAndDisplayP3Luminance() throws {
        let input = ScopeInput(width: 3, height: 1, base: [Float](repeating: 0, count: 9),
                               gainWidth: 3, gainHeight: 1, gainChannels: 3,
                               gain: [1, 0, 0, 0, 1, 0, 0, 0, 16])
        let result = try XCTUnwrap(ScopeAnalyzer.analyze(input, waveform: false))
        XCTAssertNil(result.waveform)
        XCTAssertEqual(result.histogram.red[179], 1)
        XCTAssertEqual(result.histogram.red[0], 2)
        XCTAssertEqual(result.histogram.blue[255], 1)
        let (r, g, b) = ScopeAnalyzer.lumaWeights
        for value in [r, g, b * 16] {
            XCTAssertEqual(result.histogram.luma[ScopeAnalyzer.bin(value, count: 256)], 1)
        }
    }

    func testWaveformAggregatesWideFramesAndMeasure2048Preview() throws {
        let width = 2048, height = 1365
        let input = ScopeInput(width: width, height: height,
                               base: [Float](repeating: 1, count: width * height * 3),
                               gainWidth: 1, gainHeight: 1, gainChannels: 1, gain: [1], gainMax: 2)
        let clock = ContinuousClock(), start = ContinuousClock.now
        let result = try XCTUnwrap(ScopeAnalyzer.analyze(input, waveform: true))
        print("ScopeAnalyzer 2048x1365 CPU: \(clock.now - start)")
        XCTAssertEqual(result.histogram.luma[217], UInt32(width * height))
        XCTAssertEqual(result.waveform?.columns, 512)
        XCTAssertEqual(result.waveform?.counts[217 * 512], UInt32(4 * height))
        XCTAssertEqual(result.waveform?.counts.reduce(0, +), UInt32(width * height))
    }

    func testCancellationStopsStatistics() async {
        let input = ScopeInput(width: 1, height: 1, base: [1, 1, 1], gainWidth: 1, gainHeight: 1,
                               gainChannels: 1, gain: [0])
        let result = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ScopeAnalyzer.analyze(input, waveform: true)
        }.value
        XCTAssertNil(result)
    }
}
