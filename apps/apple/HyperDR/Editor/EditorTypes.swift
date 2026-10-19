import Foundation
import HyperDREngine
import SwiftUI

/// Whether a photograph is open. Without one the canvas offers the picker and
/// the inspector explains the three steps; editing controls stay out of sight.
nonisolated enum Workspace: Equatable {
    case empty, editing
}

/// How the canvas presents the photograph.
nonisolated enum ViewMode: Hashable, CaseIterable {
    case original, edited, compare
}

nonisolated struct UserFacingError: Error, Equatable, Identifiable, Sendable {
    let id: UUID
    let code: String
    let detail: String?
    let variant: String?

    init(id: UUID = UUID(), code: String, detail: String? = nil, variant: String? = nil) {
        self.id = id
        self.code = code
        self.detail = detail
        self.variant = variant
    }
}

nonisolated enum EngineStatus: Equatable {
    case starting, ready(version: String), failed(UserFacingError)
}

nonisolated struct PixelSize: Equatable, Sendable {
    var width: Int
    var height: Int
}

nonisolated enum InputDomain: String {
    case sceneReferred = "scene-referred", sdr = "display-referred-sdr"
    case hdr = "display-referred-hdr", dual = "dual-rendition", unknown
}

nonisolated struct SourceSummary: Equatable {
    var domain: InputDomain
    var colorName: String
    var degradationReasons: [String]
    /// Where the colour description came from, as the engine names it
    /// (`icc`, `cicp`, `png-srgb`, `assumed`, …); `assumed` means the file
    /// states none and the input colour choice applies.
    var colorSource: String? = nil
    var raw: RawCapabilities? = nil
}

extension SourceSummary {
    init(_ metadata: PreviewMetadata) {
        self.init(domain: InputDomain(rawValue: metadata.inputDomain) ?? .unknown,
                  colorName: metadata.sourceColor.name,
                  degradationReasons: metadata.degradationReasons,
                  colorSource: metadata.sourceColor.source, raw: metadata.raw)
    }
}

nonisolated enum DocumentPhase: Equatable {
    case opening, rendering, ready
    // An already opened photo with no drawable frame. Q14 open failures roll
    // back to the previous photo or empty state and publish alert instead.
    case failed(UserFacingError)
}

nonisolated struct DocumentState: Equatable {
    var name: String
    var formatLabel: String
    var byteCount: Int64
    var pixelSize: PixelSize?
    var phase: DocumentPhase
    var isRefreshing: Bool
    var source: SourceSummary?
    var previewError: UserFacingError?
    var isPreparingCameraSupport = false
    /// An open that is not a RAW has had no first frame for 1.5 s (raw-states §9):
    /// the canvas offers to cancel it. Like `isPreparingCameraSupport`, it is
    /// cleared when the first frame arrives and is never both at once.
    var isOpeningSlowly = false
}

nonisolated struct DisplayState: Equatable {
    var screenName: String
    var currentHeadroom: Double
    var potentialHeadroom: Double
    var gainWeight: Double?
    var supportsEDR: Bool { potentialHeadroom > 1 }
}

nonisolated enum ZoomLevel: Equatable {
    case fit, scale(Double)
}

nonisolated enum PreviewScenario: CaseIterable {
    case empty, opening, firstFrameRendering, editingHDRDisplay, editingSDRDisplay
    case refreshing, previewFailedKeepsFrame, firstFrameFailed, openFailed, engineFailed
}
