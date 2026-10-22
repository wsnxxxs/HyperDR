import Foundation

extension EditorModel {
    static func preview(_ scenario: PreviewScenario) -> EditorModel {
        let services = FakeEditorServices()
        let photo = EditorPhoto(url: URL(fileURLWithPath: "/fixtures/DSC_0412.ARW"),
            name: "DSC_0412.ARW", formatLabel: "RAW", byteCount: 24_000_000)
        let failure = UserFacingError(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                     code: "metal_unavailable")
        var document = photo.openingDocument
        var alert: UserFacingError?
        var hasFrame = false
        switch scenario {
        case .empty:
            return EditorModel(services: services)
        case .engineFailed:
            services.engineStatus = .failed(UserFacingError(id: failure.id, code: "engine_unavailable"))
            return EditorModel(services: services)
        case .opening:
            break
        case .firstFrameRendering:
            document.phase = .rendering
        case .firstFrameFailed:
            document.phase = .failed(failure)
        case .editingHDRDisplay, .editingSDRDisplay, .refreshing, .previewFailedKeepsFrame, .openFailed:
            hasFrame = true
            document.phase = .ready
            document.pixelSize = PixelSize(width: 6000, height: 4000)
            document.source = SourceSummary(domain: .sceneReferred, colorName: "Display P3", degradationReasons: [])
            services.displayState.gainWeight = 0.6
            if scenario == .editingSDRDisplay {
                services.displayState = DisplayState(screenName: "", currentHeadroom: 1,
                    potentialHeadroom: 1, gainWeight: 0)
            }
            document.isRefreshing = scenario == .refreshing
            if scenario == .previewFailedKeepsFrame {
                document.previewError = UserFacingError(id: failure.id, code: "raw_budget")
            }
            if scenario == .openFailed {
                alert = UserFacingError(id: failure.id, code: "source_unreadable")
            }
        }
        return EditorModel(services: services, document: document, alert: alert,
            photo: hasFrame ? photo : nil, hasReferenceFrame: hasFrame, hasEditedFrame: hasFrame)
    }
}
