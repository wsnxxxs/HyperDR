import Foundation

/// How a "Photos" export reaches the library (p7-adjustments §4.3). The plan
/// only expresses the choice; PhotoKit is P7-3b's work.
public enum LibrarySaveMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// `PHContentEditingOutput`: the library shows the edited photo and the
    /// original can be reverted in Photos.
    case replace
    /// `PHAssetCreationRequest`: a second photo beside the original.
    case newPhoto

    /// `dest.photos.replace` / `.new` in `Localizable.xcstrings`.
    public var labelKey: String {
        switch self {
        case .replace: "dest.photos.replace"
        case .newPhoto: "dest.photos.new"
        }
    }
}

/// Where the open photo came from, which decides what can be done with it.
public enum PhotoLibraryOrigin: String, Sendable, Hashable, Codable {
    /// Picked from the photo library: the asset identifier is known.
    case photoLibrary
    /// Opened from a file: there is no asset to replace.
    case files
}

/// The library permission the export would use. Nothing here asks Photos for
/// anything; the editor model reports what it has.
public enum PhotoLibraryAccess: Sendable, Hashable, Codable {
    case notDetermined
    /// "Add photos only": a new photo is allowed, a replacement is not.
    case addOnly
    /// Limited access: replacements are only possible for an authorized asset.
    case readWrite(canReplaceSelected: Bool)
    case denied

    public var allowsNewPhoto: Bool { self != .denied }

    /// Whether a replacement could be written with this permission alone.
    public var allowsReplacement: Bool {
        switch self {
        case .notDetermined, .readWrite(true): true
        case .addOnly, .readWrite(false), .denied: false
        }
    }
}

/// What the editor model knows about the photo's library home.
public struct ExportLibraryFacts: Sendable, Hashable, Codable {
    public var origin: PhotoLibraryOrigin
    public var access: PhotoLibraryAccess
    /// Empty until a save route has passed Photos Lab (P7-3e).
    public var verifiedModes: Set<LibrarySaveMode>

    public init(origin: PhotoLibraryOrigin = .files, access: PhotoLibraryAccess = .notDetermined,
                verifiedModes: Set<LibrarySaveMode> = PhotoLibrarySaver.verifiedModes) {
        self.origin = origin
        self.access = access
        self.verifiedModes = verifiedModes
    }
}

/// One of the two radio rows under the "Photos" card. Both are always shown
/// (p7-adjustments §4.3): an unavailable mode is disabled with a reason, never
/// hidden, so the user knows the option exists.
public struct LibrarySaveOption: Sendable, Hashable {
    public let mode: LibrarySaveMode
    public let unavailableReason: PhotosUnavailableReason?
    public var isAvailable: Bool { unavailableReason == nil }
    public init(mode: LibrarySaveMode, unavailableReason: PhotosUnavailableReason? = nil) {
        self.mode = mode; self.unavailableReason = unavailableReason
    }
}

/// The "Save to Photos" part of a plan. nil selection means no mode can run
/// (the library is refused outright), and the plan carries a blocker.
public struct LibrarySavePlan: Sendable, Hashable {
    public let options: [LibrarySaveOption]
    public let selected: LibrarySaveMode?

    public init(options: [LibrarySaveOption], selected: LibrarySaveMode?) {
        self.options = options
        self.selected = selected
    }

    public var replace: LibrarySaveOption? { options.first { $0.mode == .replace } }
    public var newPhoto: LibrarySaveOption? { options.first { $0.mode == .newPhoto } }

    /// The rules of p7-adjustments §4.3, in one place.
    ///
    /// - From the library, the photo can be replaced unless a frame was added
    ///   (the card is no longer the same picture) or the permission is limited
    ///   to other assets.
    /// - From a file there is nothing to replace.
    /// - Denied access disables both modes.
    /// - `remembered` wins when it is available; otherwise replacement, which
    ///   leaves no second copy behind; otherwise a new photo.
    public static func plan(facts: ExportLibraryFacts, isFramed: Bool,
                            remembered: LibrarySaveMode?) -> LibrarySavePlan {
        let options = LibrarySaveMode.allCases.map { mode -> LibrarySaveOption in
            let reason: PhotosUnavailableReason?
            if !facts.verifiedModes.contains(mode) { reason = .notVerified }
            else if !facts.access.allowsNewPhoto { reason = .permissionDenied }
            else if mode == .newPhoto { reason = nil }
            else if facts.origin == .files { reason = .fileSource }
            else if isFramed { reason = .framed }
            else if facts.access == .addOnly { reason = .addOnly }
            else if !facts.access.allowsReplacement { reason = .selectedAssetUnavailable }
            else { reason = nil }
            return .init(mode: mode, unavailableReason: reason)
        }
        let available = options.filter(\.isAvailable)
        guard !available.isEmpty else { return .init(options: options, selected: nil) }
        let selected: LibrarySaveMode
        if let remembered, options.contains(where: { $0.mode == remembered && $0.isAvailable }) {
            selected = remembered
        } else if available.contains(where: { $0.mode == .replace }) {
            selected = .replace
        } else {
            selected = .newPhoto
        }
        return LibrarySavePlan(options: options, selected: selected)
    }
}

/// Remembers the save mode the user picked last (p7-adjustments §4.1, §4.3).
/// The editor model owns the implementation and its storage; a plan only reads
/// it, and the caller records the mode after a save.
public protocol ExportPreferenceStore: Sendable {
    func lastLibrarySaveMode() -> LibrarySaveMode?
    func rememberLibrarySaveMode(_ mode: LibrarySaveMode)
}

/// A store for tests and for a caller that keeps no preferences yet.
public final class InMemoryExportPreferences: ExportPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var mode: LibrarySaveMode?

    public init(mode: LibrarySaveMode? = nil) { self.mode = mode }

    public func lastLibrarySaveMode() -> LibrarySaveMode? {
        lock.withLock { mode }
    }

    public func rememberLibrarySaveMode(_ mode: LibrarySaveMode) {
        lock.withLock { self.mode = mode }
    }
}
