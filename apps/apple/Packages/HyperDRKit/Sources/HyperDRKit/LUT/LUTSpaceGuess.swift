import Foundation

extension LUTSpace {
    /// The spaces a LUT's file name declares, as camera makers and grading
    /// tools name their LUTs: "SLog3SGamut3.CineToLC-709", "VLog_to_V709",
    /// "LogC4_Rec709", "Rec709_Kodak2383". A camera Log input feeds Rec. 709
    /// unless the name says HLG or PQ. Nil when the name says nothing, and
    /// the import keeps sRGB in and out.
    static func guess(fileName: String) -> (input: LUTSpace, output: LUTSpace)? {
        let name = String(fileName.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        let log: LUTSpace?
        if name.contains("slog3") {
            log = name.contains("sgamut3") && !name.contains("sgamut3cine") ? .slog3SGamut3 : .slog3SGamut3Cine
        } else if name.contains("vlog") {
            log = .vlogVGamut
        } else if name.contains("flog2") {
            log = .flog2FGamut
        } else if name.contains("logc4") {
            log = .logC4AWG4
        } else if name.contains("logc") {
            log = .logC3AWG3
        } else if name.contains("clog3") || name.contains("canonlog3") {
            log = .clog3CinemaGamut
        } else {
            log = nil
        }
        if let log {
            let output: LUTSpace = name.contains("hlg") ? .hlg : name.contains("pq") || name.contains("st2084") ? .pq : .rec709
            return (log, output)
        }
        return name.contains("rec709") || name.contains("bt709") ? (.rec709, .rec709) : nil
    }
}
