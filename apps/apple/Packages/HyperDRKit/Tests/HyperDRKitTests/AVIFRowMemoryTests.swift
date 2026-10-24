import Testing
@testable import HyperDRKit

struct AVIFRowMemoryTests {
    @Test func smallCellsMirrorTheNativeRowWriter() {
        for (width, height) in [(1, 1), (96, 64), (1024, 1024), (1025, 7),
                                (9504, 6336), (6336, 9504), (12800, 8600), (32768, 8192)] {
            let size = ExportPixelSize(width: width, height: height)
            let cell = ExportMemoryEstimate.avifRowCell(canvas: size)
            let columns = (width + 1023) / 1024, rows = (height + 1023) / 1024
            #expect(cell.width <= 1024 && cell.height <= 1024)
            #expect(cell.width % 64 == 0 && cell.height % 64 == 0)
            #expect(cell.width * columns >= width && cell.height * rows >= height)
        }
    }

    @Test func avifUsesRowsWithoutFullFloatOrYUVCanvases() {
        let size = ExportPixelSize(width: 9504, height: 6336)
        for encoding in [ExportEncoding.avifPq, .avifHlg] {
            var input = ExportMemoryEstimate.Input(source: .init(domain: .sdr, pixelSize: size),
                photoSize: size, canvas: size, encoding: encoding, writer: .libavif,
                writesGainMap: false, isFramed: false, baseBitDepth: 10,
                writeRows: 256, retainedBytes: 0)
            let rows = ExportMemoryEstimate.estimate(input)
            input.allowsRowInput = false
            let whole = ExportMemoryEstimate.estimate(input)
            #expect(rows.encode < whole.encode / 2)
            #expect(rows.render < whole.render / 2)
            // An ImageIO thumbnail can still require a full AVIF decode. This
            // must remain distinct from our one-cell native verification.
            #expect(rows.systemVerify > rows.nativeVerify)
            #expect(rows.systemVerify - rows.decode >= size.pixels * 24)
        }
    }

    @Test func nativeAVIFVerificationIsCellBounded() {
        func estimate(height: Int) -> ExportMemoryEstimate {
            let size = ExportPixelSize(width: 1024, height: height)
            return .estimate(.init(source: .init(domain: .sdr, pixelSize: size), photoSize: size,
                canvas: size, encoding: .avifPq, writer: .libavif, writesGainMap: false,
                isFramed: false, baseBitDepth: 10, writeRows: 64, retainedBytes: 0))
        }
        let short = estimate(height: 1024), tall = estimate(height: 8192)
        #expect(short.nativeVerify - short.decode == tall.nativeVerify - tall.decode)
        #expect(tall.systemVerify - tall.decode > short.systemVerify - short.decode)
    }
}
