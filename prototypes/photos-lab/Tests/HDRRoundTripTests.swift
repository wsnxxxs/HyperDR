import XCTest
import CoreImage


/// 不碰图库：用合成的 HDR 渐变测试写出与读回。
final class HDRRoundTripTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotosLabTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 256×128 的水平渐变，亮度 0…3（线性，扩展 P3），还有一点颜色变化。
    private func hdrGradient() throws -> CIImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 256, y: 0),
            "inputColor0": CIColor(red: 0.02, green: 0.02, blue: 0.03, colorSpace: space)!,
            "inputColor1": CIColor(red: 3.0, green: 2.6, blue: 2.2, colorSpace: space)!,
        ])!.outputImage!
        return gradient.cropped(to: CGRect(x: 0, y: 0, width: 256, height: 128))
    }

    /// 模拟器上的 ImageIO 不能从 HDR 像素生成增益图，遇到就跳过这些测试。
    private func writeSource() throws -> URL {
        let url = directory.appendingPathComponent("source.heic")
        do {
            try HDREditor.write(try hdrGradient(), variant: .heicISOGainmap, to: url)
        } catch HDRError.finalizeFailed {
            throw XCTSkip("这个环境的 ImageIO 不能生成 ISO 增益图")
        }
        return url
    }

    func testISOGainmapHEICKeepsGainMap() throws {
        let url = try writeSource()
        let report = ImageInspector.inspect(url)
        XCTAssertNil(report.error)
        XCTAssertEqual(report.imageSourceType, "public.heic")
        XCTAssertTrue(report.hasISOGainMap, report.summary)
        XCTAssertGreaterThan(report.headroom ?? 0, 1.5)
    }

    func testISOGainmapJPEGKeepsGainMap() throws {
        _ = try writeSource()
        let url = directory.appendingPathComponent("a.jpg")
        try HDREditor.write(try hdrGradient(), variant: .jpegISOGainmap, to: url)
        let report = ImageInspector.inspect(url)
        XCTAssertEqual(report.imageSourceType, "public.jpeg")
        XCTAssertTrue(report.hasISOGainMap, report.summary)
    }

    func testISOHDRHEICIsTenBit() throws {
        let url = directory.appendingPathComponent("hdr10.heic")
        try HDREditor.write(try hdrGradient(), variant: .heicISOHDR10, to: url)
        let report = ImageInspector.inspect(url)
        XCTAssertEqual(report.bitDepth, 10, report.summary)
        XCTAssertFalse(report.hasAnyGainMap)
    }

    func testCoreImagePQHEICIsTenBit() throws {
        let url = directory.appendingPathComponent("pq.heic")
        try HDREditor.write(try hdrGradient(), variant: .heicCoreImage10PQ, to: url)
        let report = ImageInspector.inspect(url)
        XCTAssertEqual(report.bitDepth, 10, report.summary)
    }

    func testEditBrightensByRoughlyTheRequestedExposure() throws {
        let source = try writeSource()
        let before = try XCTUnwrap(ImageInspector.inspect(source).meanLuminance)
        let edited = directory.appendingPathComponent("edited.heic")
        try HDREditor.write(try HDREditor.edited(from: source, exposure: 0.3), variant: .heicISOGainmap, to: edited)
        let report = ImageInspector.inspect(edited)
        let after = try XCTUnwrap(report.meanLuminance)
        XCTAssertTrue(report.hasISOGainMap)
        // 2^0.3 ≈ 1.231；编解码有损，允许 15% 误差
        XCTAssertEqual(after / before, pow(2, 0.3), accuracy: 0.2)
    }

    func testEditedKeepsGainMapAfterSecondPass() throws {
        let first = try writeSource()
        let second = directory.appendingPathComponent("second.heic")
        try HDREditor.write(try HDREditor.edited(from: first, exposure: 0.3), variant: .heicISOGainmap, to: second)
        XCTAssertTrue(ImageInspector.inspect(second).hasISOGainMap)
    }

    func testCarriedGainMapSurvivesIndependentOfAutoGeneration() throws {
        let source = try writeSource()
        let out = directory.appendingPathComponent("carried.heic")
        try HDREditor.write(try HDREditor.edited(from: source, exposure: 0.3, applyOrientation: false),
                            variant: .heicCarriedGainMap, to: out, gainMapSource: source)
        let report = ImageInspector.inspect(out)
        XCTAssertTrue(report.hasAnyGainMap, report.summary)
        XCTAssertEqual(report.bitDepth, 8)
    }

    func testCarriedGainMapWithoutSourceFails() throws {
        let out = directory.appendingPathComponent("none.heic")
        XCTAssertThrowsError(try HDREditor.write(try hdrGradient(), variant: .heicCarriedGainMap, to: out))
    }

    func testRecipeDataSizeAndFormat() throws {
        let small = HDREditor.recipeData(exposure: 0.3, variant: .heicISOGainmap, paddingBytes: 0)
        let big = HDREditor.recipeData(exposure: 0.3, variant: .heicISOGainmap, paddingBytes: 100 * 1024)
        XCTAssertLessThan(small.count, 512)
        XCTAssertGreaterThan(big.count, 100 * 1024)
        let object = try JSONSerialization.jsonObject(with: big) as? [String: Any]
        XCTAssertEqual(object?["exposureEV"] as? Double, 0.3)
    }

    func testJSONValueRoundTrip() throws {
        let report = ImageInspector.inspect(try writeSource())
        let value = JSONValue.from(report)
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testMissingFileReportsError() {
        let report = ImageInspector.inspect(directory.appendingPathComponent("nope.heic"))
        XCTAssertNotNil(report.error)
    }
}
