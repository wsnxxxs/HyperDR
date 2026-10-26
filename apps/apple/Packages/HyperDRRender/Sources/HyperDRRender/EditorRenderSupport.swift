import Foundation
import Metal
import HyperDRRecipe

/// Ephemeral comparison state; never persisted in Recipe or undo history.
public struct RenderOptions: Hashable, Sendable {
    public var bypassedGroups: Set<ParameterGroup>
    public init(bypassedGroups: Set<ParameterGroup> = []) { self.bypassedGroups = bypassedGroups }
}

extension RenderEngine {
    /// Automatic readouts in Recipe units. AI auto start is deliberately not a
    /// numeric threshold, so no expansionStart entry is returned in AI mode.
    /// `includingSet` also reports what Auto would resolve to for parameters
    /// the recipe sets, with everything else as it is: the editor marks that
    /// as the default on its ruler. Exports record only parameters left on Auto.
    public func resolvedAutomatic(_ source: RenderSource, recipe: Recipe, lut: ColorLUT? = nil,
                                  modelGain: ModelGainPrediction? = nil,
                                  options: RenderOptions = RenderOptions(),
                                  includingSet: Bool = false, includesHDR: Bool = true) throws -> [String:Double] {
        guard source.domain == recipe.inputDomain else { throw RenderError.invalidAdjustment }
        var edit = try RenderAdjustments(recipe:recipe,lut:lut,options:options,includesHDR:includesHDR)
        edit.hdr.modelGain = modelGain
        if includingSet {
            edit.hdr.range = nil
            edit.hdr.expansionStart = nil
            edit.film.exposure = nil
            edit.look.exposure = nil
        }
        let analysis = try self.analysis(source,adjustments:edit)
        let model = try filteredModelGain(source,edit:edit)
        var values: [String:Double] = [:]
        if edit.hdr.range == nil {
            values["hdr.range"] = Double(try graphConfiguration(source,edit,analysis:analysis,modelPeak:model?.peak ?? 0).range)
        }
        if edit.hdr.expansionStart == nil && (edit.hdr.source ?? .defaultSource(for:source.domain)).expands {
            values["hdr.expansionStart"] = Adjustments.automaticExpansionStart
        }
        if edit.usesFilmProcessing && edit.film.exposure == nil {
            values["look.filmExposure"] = Double(try filmMeter(source, stock: edit.film.stock!, antihalation: edit.film.antihalation))
        }
        if !edit.look.isIdentity && edit.look.input.isLog && edit.look.exposure == nil, let lut = edit.look.lut {
            values["look.exposure"] = Double(try lutMeter(source, lut: lut, input: edit.look.input, output: edit.look.output))
        }
        return values
    }
}

public struct RenderMask: @unchecked Sendable {
    public let texture: any MTLTexture
    public let region: CGRect
    public let outputSize: PixelSize
    public init(texture: any MTLTexture, region: CGRect, outputSize: PixelSize) {
        self.texture = texture; self.region = region; self.outputSize = outputSize
    }
}

extension RenderEngine {
    /// R32Float participation in [0,1], top-down in output/ROI coordinates.
    /// Light masks use the luminance immediately before the corresponding node.
    public func effectMask(_ source: RenderSource, recipe: Recipe, parameterID: String,
                           lut: ColorLUT? = nil, modelGain: ModelGainPrediction? = nil,
                           options: RenderOptions = RenderOptions(), size: PixelSize? = nil,
                           region: CGRect? = nil) throws -> RenderMask {
        guard recipe.inputDomain == source.domain, let declaration = Adjustments.declaration(parameterID),
              declaration.allows(source.domain), let mask = declaration.mask,
              let index = ["highlights","shadows","blacks","participation","coverage","gain","gainFull"].firstIndex(of:mask) else {
            throw RenderError.invalidAdjustment
        }
        var edit = try RenderAdjustments(recipe:recipe,lut:lut,options:options)
        edit.hdr.modelGain = modelGain
        let size = size ?? source.size
        try validate(size)
        let region = try validatedRegion(region,size:size)
        let usesModel = (edit.hdr.source ?? .defaultSource(for:source.domain)).usesModel
        let input = try workingInput(source)
        var guide = input, gain = input
        if index == 3 || index == 4 {
            guide = try self.analysis(source,adjustments:usesModel ? RenderAdjustments() : edit).cells
        }
        var gainChannels: UInt32 = 1
        var range = edit.hdr.range ?? 3
        if index >= 5 {
            let planes = try render(source,adjustments:edit,size:size,region:region)
            let pair = try displayPair(planes,source:source)
            gain = pair.gain; gainChannels = UInt32(pair.gainChannelCount)
            range = max(0.5,pair.alternateHeadroom)
        }
        guard let command = queue.makeCommandBuffer() else { throw RenderError.allocationFailed }
        let node = nodeContext(domain:source.domain,buffer:command)
        let output = try node.texture(width:Int(region.width),height:Int(region.height),format:.r32Float)
        var p = graphUniform(source,edit,size:size,region:region,range:range)
        let sourceKind = edit.hdr.source ?? .defaultSource(for:source.domain)
        let inactive = options.bypassedGroups.contains(declaration.group) || (declaration.group == .hdr && !edit.hdr.enabled)
            || (index == 3 && !sourceKind.expands && !usesModel) || (index == 4 && !sourceKind.expands)
        p.mode = SIMD4(UInt32(index),gainChannels,inactive ? 1 : 0,
            (edit.hdr.source ?? .defaultSource(for:source.domain)).usesModel ? (edit.hdr.expansionStart == nil ? 1 : 2) : 0)
        try node.dispatch("effectMask",width:output.width,height:output.height,
            textures:[input,output,gain,guide],value:&p)
        try finish(command)
        return RenderMask(texture:output,region:region,outputSize:size)
    }
}

/// Original photograph facts in Recipe units. Capability keys are parameter IDs,
/// distinct from RAWDevelopment's low-level CIRAWFilter capability predicates.
public struct SourceReport: Sendable {
    public let sourceValues: [String:Double]
    public let capabilities: Set<String>
    public init(sourceValues: [String:Double], capabilities: Set<String>) {
        self.sourceValues = sourceValues; self.capabilities = capabilities
    }
}

extension RenderEngine {
    /// Uses the same cached, unedited fixed-scale analysis as preview and export.
    /// hdr.range reports the source capacity in stops, not an edited output range.
    /// tone.exposure is the RAW file's baseline exposure, not an exposure adjustment.
    public func sourceReport(_ source: RenderSource) throws -> SourceReport {
        var values = source.rawSettings?.sourceValues ?? [:]
        values["hdr.range"] = Double(try analysis(source).sourceHeadroom)
        if let raw = source.rawSettings { values["tone.exposure"] = Double(raw.baselineExposure) }
        let flags = source.rawSettings?.capabilities ?? []
        let supported = Adjustments.all.filter { declaration in
            declaration.allows(source.domain) && (declaration.capability.map { flags.contains($0) } ?? true)
        }
        return SourceReport(sourceValues:values,capabilities:Set(supported.map(\.id)))
    }
}
