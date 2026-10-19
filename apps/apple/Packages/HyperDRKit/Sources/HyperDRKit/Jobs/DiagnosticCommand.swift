import Foundation

/// Fixed English developer diagnostics; no user paths or localized text.
public enum DiagnosticCommand {
    public static func text(_ argv: [String]) -> String {
        guard !argv.isEmpty else { return "Equivalent CLI command: unavailable" }
        let input = argv.dropFirst(2).first ?? ""
        let candidates = [(input, "the opened photo"), ("out", "the output directory"),
            ("out/report.json", "the conversion report"), ("look.cube", "the LUT in use"),
            ("frame.json", "the frame spec"), ("gain.png", "the external gain map"),
            ("gain-report.json", "the external gain report")]
        let legend = candidates.filter { !$0.0.isEmpty && argv.contains($0.0) }
            .map { $0.0 + " = " + $0.1 }.joined(separator: "; ")
        return "Equivalent CLI command (current edits; paths are placeholders):\n"
            + argv.map(quote).joined(separator: " ") + "\nPlaceholders: " + legend
    }

    /// POSIX shell single quotes, including empty strings and embedded quotes.
    public static func quote(_ argument: String) -> String {
        let safe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./=:,+-"
        if !argument.isEmpty && argument.allSatisfy({ safe.contains($0) }) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
