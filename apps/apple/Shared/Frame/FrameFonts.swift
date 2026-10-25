import CoreText
import Foundation
import Observation
import SwiftUI

/// A typeface for the frame's caption: one of the system's designs, or a
/// font family by name -- installed with the system or imported by the user
/// into `FrameFontLibrary`. The caption view sets every line in it at a fixed
/// size, so the preview and the export's overlay carry the same type.
enum FrameTypeface: Hashable, Codable, Identifiable {
    /// SF Pro.
    case system
    /// New York.
    case serif
    /// SF Pro Rounded.
    case rounded
    /// SF Mono.
    case monospaced
    /// A font family by its family name.
    case family(String)

    var id: String {
        switch self {
        case .system: "system"
        case .serif: "serif"
        case .rounded: "rounded"
        case .monospaced: "monospaced"
        case .family(let name): "family:" + name
        }
    }

    /// The system's own designs, always there.
    static let designs: [FrameTypeface] = [.system, .serif, .rounded, .monospaced]

    /// Families that ship with both macOS and iOS, offered beside the
    /// designs: a few text faces, a few display faces and two scripts for
    /// signatures. A family missing on this system is left out.
    static let curatedFamilies = [
        "Avenir Next", "Helvetica Neue", "Futura", "Gill Sans", "Optima",
        "Georgia", "Baskerville", "Didot", "Bodoni 72", "Palatino",
        "American Typewriter", "Snell Roundhand", "Savoye LET",
    ]

    /// The family's name, nil for a system design.
    var familyName: String? {
        if case .family(let name) = self { name } else { nil }
    }

    /// Whether this system can set the typeface: a design always, a family
    /// when it is installed or imported. A caption in a missing family falls
    /// back to the system face.
    var isAvailable: Bool {
        guard let familyName else { return true }
        return FrameFontLibrary.isInstalled(family: familyName)
    }

    /// The font at `size` points, never scaled by Dynamic Type: the overlay
    /// renders at one point per pixel.
    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .system: .system(size: size, weight: weight)
        case .serif: .system(size: size, weight: weight, design: .serif)
        case .rounded: .system(size: size, weight: weight, design: .rounded)
        case .monospaced: .system(size: size, weight: weight, design: .monospaced)
        case .family(let name):
            isAvailable ? Font.custom(name, fixedSize: size).weight(weight) : .system(size: size, weight: weight)
        }
    }

    // A design is stored by its id, a family as `family:<name>`.
    init(from decoder: any Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        switch id {
        case "system": self = .system
        case "serif": self = .serif
        case "rounded": self = .rounded
        case "monospaced": self = .monospaced
        default:
            guard id.hasPrefix("family:"), id.count > 7 else { self = .system; return }
            self = .family(String(id.dropFirst(7)))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

/// The fonts the user imported for frame captions (.ttf, .otf, .ttc): copied
/// into Application Support/FrameFonts, out of backups, and registered for
/// this process at launch, so the preview and the export find them by family
/// name. Removing a font unregisters it; a caption still naming it falls back
/// to the system face.
@MainActor @Observable final class FrameFontLibrary {
    static let shared = FrameFontLibrary()

    struct Entry: Identifiable, Hashable {
        let url: URL
        /// The families the file holds (a collection may hold several).
        let families: [String]
        var id: URL { url }
    }

    enum ImportError: Error { case unreadable, noFonts }

    private(set) var entries: [Entry] = []
    private let directory: URL
    private var registered = false

    /// Tests pass a directory of their own.
    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "FrameFonts", directoryHint: .isDirectory)
    }

    /// The imported families, sorted, each once.
    var families: [String] {
        Array(Set(entries.flatMap(\.families))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Registers every imported font. Called once at launch; later calls do nothing.
    func registerAll() {
        guard !registered else { return }
        registered = true
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        entries = files.filter { Self.fontExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let families = Self.families(in: url)
                guard !families.isEmpty else { return nil }
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                return Entry(url: url, families: families)
            }
    }

    /// Copies a font file in and registers it. Returns its first family, the
    /// one a caption takes when the font is imported from the frame's controls.
    @discardableResult
    func importFont(from source: URL) throws -> String {
        registerAll()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let families = Self.families(in: source)
        guard let first = families.first else { throw ImportError.noFonts }
        // A family already imported is not imported twice.
        if let existing = entries.first(where: { $0.families == families }) { return existing.families[0] }
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? folder.setResourceValues(resources)
        let target = Self.uniqueURL(in: directory, name: source.lastPathComponent)
        do { try FileManager.default.copyItem(at: source, to: target) } catch { throw ImportError.unreadable }
        // A family the system already has (installed, or the same font under
        // another file name) is not registered again; the copy still lists it.
        if !families.allSatisfy(Self.isInstalled(family:)) {
            CTFontManagerRegisterFontsForURL(target as CFURL, .process, nil)
        }
        entries.append(Entry(url: target, families: families))
        return first
    }

    func remove(_ entry: Entry) {
        CTFontManagerUnregisterFontsForURL(entry.url as CFURL, .process, nil)
        try? FileManager.default.removeItem(at: entry.url)
        entries.removeAll { $0 == entry }
    }

    /// Whether a family can be set: installed with the system or registered.
    nonisolated static func isInstalled(family: String) -> Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor] ?? []
        return !matches.isEmpty
    }

    /// The curated families this system has, then the imported ones.
    func offeredFamilies() -> [String] {
        registerAll()
        let imported = families
        return FrameTypeface.curatedFamilies.filter { !imported.contains($0) && Self.isInstalled(family: $0) } + imported
    }

    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    private nonisolated static func families(in url: URL) -> [String] {
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        var seen: [String] = []
        for descriptor in descriptors {
            if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
               !seen.contains(name) {
                seen.append(name)
            }
        }
        return seen
    }

    private static func uniqueURL(in directory: URL, name: String) -> URL {
        var url = directory.appending(path: name)
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "\(stem) \(index).\(ext)")
            index += 1
        }
        return url
    }
}
