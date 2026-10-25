import Foundation

extension LUTSpace {
    /// The spaces a LUT's file name declares, as camera makers and grading
    /// tools name their LUTs: "SLog3SGamut3.CineToLC-709", "VLog_to_V709",
    /// "LogC4_Rec709", "Rec709_Kodak2383". A camera Log input feeds Rec. 709
    /// unless the name says HLG or PQ. Nil when the name says nothing, and
    /// the import keeps sRGB in and out.
    static func guess(fileName: String) -> (input: LUTSpace, output: LUTSpace)? {
        let name = String(fileName.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        let separator = name.range(of: "to")
        let inputName = separator.map { String(name[..<$0.lowerBound]) } ?? name
        let outputName = separator.map { String(name[$0.upperBound...]) } ?? name
        let log: LUTSpace?
        if name.contains("slog3") {
            log = name.contains("sgamut3") && !name.contains("sgamut3cine") ? .slog3SGamut3 : .slog3SGamut3Cine
        } else if name.contains("vlog") {
            log = .vlogVGamut
        } else if name.contains("flog2c") {
            log = .flog2cFGamutC
        } else if name.contains("flog2") {
            log = .flog2FGamut
        } else if name.contains("flog") {
            log = .flogFGamut
        } else if name.contains("applelog") {
            log = .appleLogRec2020
        } else if name.contains("nlog") && !name.contains("canonlog") {
            log = .nlogRec2020
        } else if name.contains("dlog") {
            log = .dlogDGamut
        } else if name.contains("clog2") || name.contains("canonlog2") {
            log = .clog2CinemaGamut
        } else if name.contains("davinci") || name.contains("dwg") || name.contains("intermediate") {
            log = .davinciDWG
        } else if name.contains("acescct") {
            log = .acescctAP1
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
            // A declared input may itself name Rec.2020. Prefer the output
            // portion in the common camera-space-to-display-space filenames.
            let output: LUTSpace = outputName.contains("hlg") ? .hlg : outputName.contains("pq") || outputName.contains("st2084") ? .pq : outputName.contains("2020") ? .rec2020 : .rec709
            return (log, output)
        }
        if inputName.contains("2020") {
            return (.rec2020, outputName.contains("709") ? .rec709 : .rec2020)
        }
        if inputName.contains("709") {
            return (.rec709, outputName.contains("2020") ? .rec2020 : .rec709)
        }
        return nil
    }
}
