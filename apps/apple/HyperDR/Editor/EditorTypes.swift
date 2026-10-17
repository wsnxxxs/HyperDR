import Foundation
import SwiftUI

/// Whether a photograph is open. Without one the canvas offers the picker and
/// the inspector explains the three steps; editing controls stay out of sight.
enum Workspace: Equatable {
    case empty, editing
}

/// How the canvas presents the photograph.
enum ViewMode: Hashable, CaseIterable {
    case original, edited, compare
}

struct UserFacingError: Error, Equatable, Identifiable, Sendable {
    let id: UUID
    let code: String
    let detail: String?

    init(id: UUID = UUID(), code: String, detail: String? = nil) {
        self.id = id
        self.code = code
        self.detail = detail
    }
}

enum EngineStatus: Equatable {
    case starting, ready(version: String), failed(UserFacingError)
}

struct PixelSize: Equatable {
    var width: Int
    var height: Int
}

enum InputDomain: String {
    case sceneReferred = "scene-referred", sdr = "display-referred-sdr"
    case hdr = "display-referred-hdr", dual = "dual-rendition", unknown
}

struct SourceSummary: Equatable {
    var domain: InputDomain
    var colorName: String
    var degradationReasons: [String]
}

enum DocumentPhase: Equatable {
    case opening, rendering, ready
    // An already opened photo with no drawable frame. Q14 open failures roll
    // back to the previous photo or empty state and publish alert instead.
    case failed(UserFacingError)
}

struct DocumentState: Equatable {
    var name: String
    var formatLabel: String
    var byteCount: Int64
    var pixelSize: PixelSize?
    var phase: DocumentPhase
    var isRefreshing: Bool
    var source: SourceSummary?
    var previewError: UserFacingError?
}

struct DisplayState: Equatable {
    var screenName: String
    var currentHeadroom: Double
    var potentialHeadroom: Double
    var gainWeight: Double?
    var supportsEDR: Bool { potentialHeadroom > 1 }
}

enum ZoomLevel: Equatable {
    case fit, scale(Double)
}

enum PreviewScenario: CaseIterable {
    case empty, opening, firstFrameRendering, editingHDRDisplay, editingSDRDisplay
    case refreshing, previewFailedKeepsFrame, firstFrameFailed, openFailed, engineFailed
}
