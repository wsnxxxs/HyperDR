import Foundation
import HyperDRKit

/// LUTs shipped inside the app bundle for local testing (`Shared/LUT/Bundled`,
/// ignored by Git: they are third-party files that must not be published).
/// Each launch imports any the library does not hold yet; the library
/// deduplicates by content, so a LUT already imported keeps its spaces.
enum BundledLUTs {
    private static let seededKey = "BundledLUTs.seeded"

    static func install(into library: LUTLibrary, defaults: UserDefaults = .standard) async {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "cube", subdirectory: nil) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else { return }
        let signature = urls.map(\.lastPathComponent).joined(separator: "\n")
        let present = Set(await library.entries().map(\.name))
        guard defaults.string(forKey: seededKey) != signature
            || !urls.allSatisfy({ present.contains($0.lastPathComponent) }) else { return }
        for url in urls where !present.contains(url.lastPathComponent) {
            _ = try? await library.importLUT(url)
        }
        defaults.set(signature, forKey: seededKey)
    }
}
