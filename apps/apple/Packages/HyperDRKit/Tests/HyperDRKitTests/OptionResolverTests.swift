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
        #expect(resolved.settings["highlight_recovery"] == nil)
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

    /// The RAW lens correction reaches the engine's `raw_lens_correction` (on by
    /// default), for the preview, the model gain and the export alike.
    @Test func lensCorrectionReachesEveryKindOfRequest() throws {
        let resolver = try makeResolver()
        let session = makeSession()
        let on = makeRequest()
        let off = makeRequest { $0["lensCorrection"] = .bool(false) }
        #expect(try resolver.resolve(on, session: session).settings["raw_lens_correction"] == .bool(true))
        #expect(try resolver.resolve(off, session: session).settings["raw_lens_correction"] == .bool(false))
        #expect(try resolver.resolveExport(off.options, session: session).settings["raw_lens_correction"] == .bool(false))
        #expect(try resolver.resolveModelGain(off.options, session: session).settings["raw_lens_correction"] == .bool(false))
        // A different export request, so a different history key.
        #expect(try ExportKey(request: resolver.resolveExport(on.options, session: session), frame: nil)
            != ExportKey(request: resolver.resolveExport(off.options, session: session), frame: nil))
    }

    @Test func validatesPreviewOnlyOptions() throws {
        let resolver = try makeResolver()
        #expect(code { _ = try resolver.resolve(makeRequest { $0["external_gain"] = .string("/tmp/gain") },
            session: makeSession()) } == "invalid_options")
        #expect(code { _ = try resolver.resolve(makeRequest { $0["external_gain_report"] = .string("/tmp/report") },
            session: makeSession()) } == "invalid_options")
        #expect(code { _ = try resolver.resolve(makeRequest { $0["highlightRecovery"] = .string("unknown") },
            session: makeSession()) } == nil)
        #expect(code { _ = try resolver.resolve(makeRequest { $0["useModel"] = .string("yes") },
            session: makeSession()) } == "invalid_options")
        #expect(code { _ = try resolver.resolve(makeRequest { $0["modelStrength"] = .number(2) },
            session: makeSession()) } == "invalid_options")
        #expect(code { _ = try resolver.resolve(makeRequest { $0["lutId"] = .string("abc") },
            session: makeSession()) } == "lut_invalid")
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
        #expect(resolved.settings["highlight_recovery"] == nil)
    }
}

// K6: api.py's preparation/validation contract, independent of HTTP routing.
extension OptionResolverTests {
    @Test func apiCommandPreparationIsPureAndKeepsManualModeUntilExplicitlyRequested() throws {
        let resolver = try makeResolver()
        // This source does not exist. Preparing a request must not decode it,
        // create output files, run inference or admit a conversion job.
        let manual = try resolver.resolveExport(EditOptions([
            "useModel": .bool(false), "modelId": .string("stale-unavailable-id"),
            "contrast": .number(1.2)
        ]), session: makeSession())
        let argv = try Engine.commandLine(manual)
        #expect(argv.first == "HyperDR")
        #expect(argv.contains("--contrast"))
        #expect(!argv.contains("--ai-model"))
        #expect(manual.command["model_mode"] == .bool(false))
        #expect(manual.command["input"] == .string(makeSession().sourceURL.path))
        #expect(manual.command["output"] == .string(""))
        #expect(manual.command["report"] == .string(""))
        #expect(manual.settings["preview_max_edge"] == nil)
    }

    @Test func apiModelCommandPreparationPreservesSelectedIDAndEveryPostValue() throws {
        let resolver = try makeResolver()
        let options = EditOptions([
            "useModel": .bool(true), "modelId": .string("research-cnn-v1"),
            "modelStrength": .number(0.65), "hdrStrength": .number(0.4),
            "aiBrightness": .number(0.2), "aiContrast": .number(1.15),
            "aiShadows": .number(-0.25), "aiHighlights": .number(0.35),
            "aiHdrRange": .number(2.2), "aiExpansionStart": .number(0.4)
        ])
        for prepared in [
            try resolver.resolveExport(options, session: makeSession()),
            try resolver.resolve(PreviewRequest(session: makeSession().id, options: options, maxEdge: 960), session: makeSession())
        ] {
            let argv = try Engine.commandLine(prepared)
            for (flag, expected) in ["--ai-model": "research-cnn-v1", "--gain-strength": "0.65",
                "--ai-brightness": "0.2", "--ai-contrast": "1.15", "--ai-shadows": "-0.25",
                "--ai-highlights": "0.35", "--ai-hdr-range": "2.2", "--ai-expansion-start": "0.4"] {
                let index = try #require(argv.firstIndex(of: flag))
                #expect(argv[index + 1] == expected)
            }
            for flag in ["--look", "--contrast", "--vibrance", "--pop", "--headroom-max",
                         "--exposure-bias", "--expansion-start", "--area-coverage", "--exposure", "--headroom"] {
                #expect(!argv.contains(flag))
            }
        }
    }

    @Test func apiColorAndNumericValidationRunsBeforeAnyInference() throws {
        let resolver = try makeResolver()
        let invalid: [[String: JSONValue]] = [
            ["colorGamut": .string("unknown")], ["colorGamut": .number(1)],
            ["clampSrgb": .string("false")], ["clampSrgb": .number(1)],
            ["outputGamut": .string("unknown")], ["quality": .number(90.9)],
            ["contrast": .string("1.2")],
            ["aiHdrRange": .number(2.5), "encoding": .string("hlg")]
        ]
        for values in invalid {
            var options = values
            // Model mode deliberately ignores manual development controls.
            // Their strict validation belongs to the manual path.
            options["useModel"] = .bool(values["contrast"] == nil)
            #expect(code { _ = try resolver.resolveExport(EditOptions(options), session: makeSession()) } == "invalid_options", "export: \(values)")
            #expect(code { _ = try resolver.resolve(PreviewRequest(session: makeSession().id,
                options: EditOptions(options), maxEdge: 960), session: makeSession()) } == "invalid_options", "preview: \(values)")
        }
    }

    @Test func apiAvailabilityUnknownIDAndStrengthErrorsStayDistinct() throws {
        let ready = try makeResolver()
        let unavailable = OptionResolver(schema: try Engine.schema(), knownModels: [:],
            modelsAvailable: false, maxEdgeCeiling: 2048)
        #expect(code { _ = try unavailable.resolveExport(EditOptions(["useModel": .bool(true)]),
            session: makeSession()) } == "model_not_ready")
        #expect(code { _ = try ready.resolveExport(EditOptions(["useModel": .bool(true),
            "modelId": .string("unknown")]), session: makeSession()) } == "model_unknown")
        #expect(code { _ = try ready.resolveExport(EditOptions(["useModel": .bool(true),
            "modelId": .string("research-exif-v1")]), session: makeSession()) } == "model_not_ready")
        for strength in [JSONValue.number(-0.01), .number(1.01), .number(1.5), .string("0.5"), .bool(true), .null] {
            #expect(code { _ = try ready.resolveExport(EditOptions(["useModel": .bool(true),
                "modelStrength": strength]), session: makeSession()) } == "invalid_options")
        }
        for flag in [JSONValue.number(1), .string("true"), .null] {
            #expect(code { _ = try ready.resolveExport(EditOptions(["useModel": flag]),
                session: makeSession()) } == "invalid_options")
        }
        for strength in [0.0, 1.0] {
            let prepared = try ready.resolveExport(EditOptions(["useModel": .bool(true),
                "modelStrength": .number(strength)]), session: makeSession())
            #expect(prepared.settings["gain_strength"] == .number(strength))
        }
    }

    @Test func apiTypedPreviewEdgeClampsAndRegionsRejectInvalidGeometry() throws {
        let resolver = try makeResolver()
        // Unlike the removed HTTP string parser, typed Kit requests clamp the
        // edge. Both bounds and the region-specific ceiling are intentional.
        for (edge, expected) in [(Int.min, 320), (319, 320), (320, 320), (960, 960), (2049, 2048), (Int.max, 2048)] {
            #expect(try resolver.resolve(makeRequest(maxEdge: edge), session: makeSession())
                .settings["preview_max_edge"] == .number(Double(expected)))
        }
        for region in [PreviewRegion(left: -1, top: 0, width: 1, height: 1),
                       PreviewRegion(left: 0, top: -1, width: 1, height: 1),
                       PreviewRegion(left: 0, top: 0, width: 0, height: 1),
                       PreviewRegion(left: 0, top: 0, width: 1, height: 2049)] {
            #expect(code { _ = try resolver.resolve(makeRequest(region: region), session: makeSession()) } == "invalid_options")
        }
    }

    @Test func apiClientPrivateRoutesCannotSelectResourcesOrModels() throws {
        let resolver = try makeResolver()
        let prepared = try resolver.resolveExport(EditOptions([
            "_model_mode": .bool(true), "_model_id": .string("research-exif-v1"),
            "_lut_path": .string("/outside/evil.cube"), "_raw_profile_path": .string("/outside/evil.dcp"),
            "_raw_look_path": .string("/outside/evil.xmp"), "_lens_profile_path": .string("/outside/evil.lcp")
        ]), session: makeSession())
        #expect(prepared.command["model_mode"] == .bool(false))
        let argv = try Engine.commandLine(prepared)
        #expect(!argv.contains { $0.contains("/outside/") })
        #expect(!argv.contains("--ai-model"))
    }
}

extension OptionResolverTests {
    @Test func canonicalSettingsRejectUnknownKeysTypesAndRanges() throws {
        // panel_contract's schema.validate tests target canonical settings,
        // rather than the deliberately narrower panel option vocabulary.
        for settings: [String: JSONValue] in [
            ["contrst": .number(1.1)], ["contrast": .number(5)],
            ["contrast": .string("1.1")], ["look": .string("cinematic")],
            ["verify_output": .string("yes")], ["headroom": .string("maximum")]
        ] {
            #expect(code { _ = try Engine.curve(settings: settings, samples: 4) } == "invalid_options")
        }
        let bytes = try Engine.curve(settings: ["headroom": .string("auto")], samples: 4)
        #expect(try JSONSerialization.jsonObject(with: bytes) is [String: Any])
    }
}
