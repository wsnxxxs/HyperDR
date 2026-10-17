import Foundation
import HyperDREngine
import Testing
@testable import HyperDRKit

private func makeResolver() throws -> OptionResolver {
    OptionResolver(schema: try Engine.schema(),
        knownModels: ["research-cnn-v1": true, "research-exif-v1": false],
        maxEdgeCeiling: 2048)
}

private func makeSession() -> PhotoSession {
    PhotoSession(id: SessionID(rawValue: String(repeating: "a", count: 32)),
        sourceURL: URL(fileURLWithPath: "/tmp/fake-source.jpg"),
        displayName: "fake-source.jpg", byteCount: 1, sha256: "digest", format: .jpeg)
}

private func makeRequest(_ mutate: (inout [String: JSONValue]) -> Void = { _ in },
                         maxEdge: Int = 960, region: PreviewRegion? = nil) -> PreviewRequest {
    var values = EditDefaults.initial(encoding: "adaptive", sourceDomain: nil, unadjusted: nil).values
    mutate(&values)
    return PreviewRequest(session: makeSession().id, options: EditOptions(values),
        maxEdge: maxEdge, region: region)
}

private func code(_ body: () throws -> Void) -> String? {
    do { try body(); return nil }
    catch let error as HyperDRError { return error.code }
    catch { return "other" }
}

@Suite struct OptionResolverTests {
    @Test func resolvesDefaultsEdgeRegionAndAdapter() throws {
        let resolver = try makeResolver()
        let region = PreviewRegion(left: 10, top: 20, width: 64, height: 32, center: true)
        let request = makeRequest(maxEdge: 9999, region: region)
        let resolved = try resolver.resolve(request, session: makeSession())
        #expect(resolved.adapter == "panel-v1")
        #expect(resolved.settings["highlight_recovery"] == .string("blend"))
        #expect(resolved.settings["preview_max_edge"] == .number(2048))
        #expect(resolved.command["input"] == .string("/tmp/fake-source.jpg"))
        #expect(resolved.command["output"] == .string(""))
        #expect(resolved.command["report"] == .string(""))
        let regionValue = try #require(resolved.command["region"])
        guard case .object(let object) = regionValue else {
            Issue.record("region is not an object")
            return
        }
        #expect(object["left"] == .number(10))
        #expect(object["top"] == .number(20))
        #expect(object["width"] == .number(64))
        #expect(object["height"] == .number(32))
        #expect(object["center"] == .bool(true))
    }

    @Test func validatesPreviewOnlyOptions() throws {
        let resolver = try makeResolver()
        #expect(code { _ = try resolver.resolve(makeRequest { $0["external_gain"] = .string("/tmp/gain") },
            session: makeSession()) } == "invalid_options")
        #expect(code { _ = try resolver.resolve(makeRequest { $0["external_gain_report"] = .string("/tmp/report") },
            session: makeSession()) } == "invalid_options")
        #expect(code { _ = try resolver.resolve(makeRequest { $0["highlightRecovery"] = .string("unknown") },
            session: makeSession()) } == "invalid_options")
        #expect(code { _ = try resolver.resolve(makeRequest { $0["useModel"] = .string("yes") },
            session: makeSession()) } == "invalid_options")
        #expect(code { _ = try resolver.resolve(makeRequest { $0["modelStrength"] = .number(2) },
            session: makeSession()) } == "invalid_options")
        #expect(code { _ = try resolver.resolve(makeRequest { $0["lutId"] = .string("abc") },
            session: makeSession()) } == "invalid_options")
        let invalidRegion = makeRequest(region: PreviewRegion(left: 0, top: 0, width: 0, height: 10))
        #expect(code { _ = try resolver.resolve(invalidRegion, session: makeSession()) } == "invalid_options")
    }

    @Test func stripsClientPrivateKeys() throws {
        let resolver = try makeResolver()
        let resolved = try resolver.resolve(makeRequest {
            $0["_lut_path"] = .string("/tmp/evil.cube")
            $0["_model_mode"] = .bool(true)
        }, session: makeSession())
        #expect(resolved.command["_lut_path"] == nil)
        #expect(resolved.command["model_mode"] == .bool(false))
    }

    @Test func validatesAndRoutesModelRequests() throws {
        let resolver = try makeResolver()
        let request = makeRequest {
            $0["useModel"] = .bool(true)
            $0["modelId"] = .string("research-cnn-v1")
            $0["modelStrength"] = .number(0.5)
        }
        let resolved = try resolver.resolve(request, session: makeSession())
        #expect(resolved.command["model_mode"] == .bool(true))
        #expect(resolved.command["model_id"] == .string("research-cnn-v1"))
        #expect(resolved.settings["gain_strength"] == .number(0.5))

        #expect(code { _ = try resolver.resolve(makeRequest {
            $0["useModel"] = .bool(true); $0["modelId"] = .string("unknown")
        }, session: makeSession()) } == "model_unknown")
        #expect(code { _ = try resolver.resolve(makeRequest {
            $0["useModel"] = .bool(true); $0["modelId"] = .string("research-exif-v1")
        }, session: makeSession()) } == "model_not_ready")
        // A stale modelId is ignored when model mode is off, matching api.py.
        _ = try resolver.resolve(makeRequest { $0["modelId"] = .string("unknown") }, session: makeSession())
    }

    @Test func emptyModelIdUsesTheBuildDefault() throws {
        let resolver = try makeResolver()
        let resolved = try resolver.resolve(makeRequest {
            $0["useModel"] = .bool(true)
            $0["modelId"] = .string("")
        }, session: makeSession())
        #expect(resolved.command["model_id"] == .string("research-cnn-v1"))
    }

    @Test func detailRegionForcesTheCeilingEdge() throws {
        let resolver = try makeResolver()
        let region = PreviewRegion(left: 1, top: 2, width: 32, height: 16)
        let resolved = try resolver.resolve(makeRequest(maxEdge: 960, region: region),
            session: makeSession())
        #expect(resolved.settings["preview_max_edge"] == .number(2048))
    }

    @Test func unreadableModelTableIsNotReadyRatherThanUnknown() throws {
        let resolver = OptionResolver(schema: try Engine.schema(), knownModels: [:],
            modelsAvailable: false, maxEdgeCeiling: 2048)
        let request = makeRequest { $0["useModel"] = .bool(true) }
        #expect(code { _ = try resolver.resolve(request, session: makeSession()) }
            == "model_not_ready")
    }

    @Test func previewEdgeUsesTheRequestedTierBelowTheCeiling() throws {
        let resolver = try makeResolver()
        let request = makeRequest(maxEdge: 960)
        let resolved = try resolver.resolve(request, session: makeSession())
        #expect(resolved.settings["preview_max_edge"] == .number(960))
    }

    @Test func emptyHighlightRecoveryFallsBackToBlend() throws {
        let resolver = try makeResolver()
        let resolved = try resolver.resolve(makeRequest {
            $0["highlightRecovery"] = .string("")
        }, session: makeSession())
        #expect(resolved.settings["highlight_recovery"] == .string("blend"))
    }
}
