import Foundation
import Testing
import HyperDRKit

struct DiagnosticCommandTests {
    @Test func shellQuotingAndOnlyUsedPlaceholders() {
        let argv = ["HyperDR", "convert", "photo.ARW", "--output", "out", "--report", "out/report.json", "--note", "a'b $(touch /bad)\nnext", ""]
        let text = DiagnosticCommand.text(argv)
        #expect(text.contains("'a'\\''b $(touch /bad)\nnext' ''"))
        #expect(text.hasSuffix("Placeholders: photo.ARW = the opened photo; out = the output directory; out/report.json = the conversion report"))
        #expect(!text.contains("look.cube"))
        #expect(!text.contains("frame.json"))
        #expect(DiagnosticCommand.quote("abc_./=:,+-09") == "abc_./=:,+-09")
    }
}
