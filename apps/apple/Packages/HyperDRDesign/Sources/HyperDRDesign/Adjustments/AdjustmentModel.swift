import CoreGraphics
import Foundation
import HyperDRRecipe

/// The adjustment controls, generated from `Adjustments` (p7-adjustments §2.2,
/// §5): which groups and controls a recipe shows, what each control holds,
/// and the edits a control makes. Plain values, no views: the Mac and iPad
/// inspector (`AdjustmentInspector`) and the iPhone adjustment bar draw from
/// the same model, and nothing here lists a parameter by name.
///
/// Values are read and written through `Recipe`'s API only; `engineValue` is
/// Render's business, not the controls'.

/// The recipe's group enum, named apart from this package's `ParameterGroup` view.
public typealias AdjustmentGroupID = HyperDRRecipe.ParameterGroup

/// What only the source and the renderer know, handed in by the host: the
/// values behind `fromSource` and `auto` defaults, which capabilities hold,
/// and what can be chosen for the reference parameters.
public struct AdjustmentContext: Equatable, Sendable {
    /// `fromSource` defaults as reported for this photo: the RAW white balance,
    /// Apple's noise reduction and sharpness. A control whose value is not
    /// reported yet is shown but disabled.
    public var sourceValues: [String: Double]
    /// What `auto` resolves to now, shown as "Auto · 2.4".
    public var automaticValues: [String: Double]
    /// Capability strings that hold for this source (`ParameterDeclaration.capability`).
    public var capabilities: Set<String>
    /// Options that exist but cannot be chosen now (AI unavailable), by parameter id.
    public var unavailableOptions: [String: Set<String>]
    /// The LUT library, for `look.lut`.
    public var luts: [LUTReference]
    /// The spaces the library records for each LUT, by content hash: choosing
    /// a LUT starts its `look.input` and `look.output` from them.
    public var lookSpaces: [String: AdjustmentLookSpaces]
    /// Models for `hdr.model`: id and display name.
    public var models: [AdjustmentModelChoice]
    /// Each LUT's preview on the open photo, by content hash; the empty key is
    /// the photo with no LUT. A LUT without one shows its colour mark.
    public var lutPreviews: [String: CGImage]

    public init(sourceValues: [String: Double] = [:], automaticValues: [String: Double] = [:],
                capabilities: Set<String> = [], unavailableOptions: [String: Set<String>] = [:],
                luts: [LUTReference] = [], lookSpaces: [String: AdjustmentLookSpaces] = [:],
                models: [AdjustmentModelChoice] = [], lutPreviews: [String: CGImage] = [:]) {
        self.sourceValues = sourceValues
        self.automaticValues = automaticValues
        self.capabilities = capabilities
        self.unavailableOptions = unavailableOptions
        self.luts = luts
        self.lookSpaces = lookSpaces
        self.models = models
        self.lutPreviews = lutPreviews
    }
}

/// A library LUT's input and output spaces, as `look.input` / `look.output`
/// option ids ("srgb", "slog3-sgamut3").
public struct AdjustmentLookSpaces: Equatable, Sendable {
    public var input: String
    public var output: String
    public init(input: String, output: String) {
        self.input = input
        self.output = output
    }
}

public struct AdjustmentModelChoice: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A reset of more than one control, which a host may perform and name itself.
public enum AdjustmentReset: Equatable, Sendable {
    /// ↺ on a group.
    case group(AdjustmentGroupID)
    /// Reset All.
    case all
}

/// One generated control and what it holds in a recipe.
public struct AdjustmentControl: Identifiable, Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        /// A number: stored, the constant default, or the source's value.
        case number(Double)
        /// A `floatOrAuto` parameter following its automatic value, if known.
        case automatic(resolved: Double?)
        /// A `fromSource` value the source has not reported yet.
        case unknown
        case toggle(Bool)
        case choice(String)
        /// A chosen LUT (content hash) or model id; nil for none.
        case reference(String?)
    }

    public let declaration: ParameterDeclaration
    public let value: Value
    /// True when the control holds its default (reset would change nothing).
    public let isDefault: Bool
    /// Options offered in this input domain, in declared order.
    public let options: [ParameterOption]
    /// Offered options that cannot be chosen now.
    public let disabledOptions: Set<String>
    /// The number a reset returns to, when one is known: the constant
    /// default or the source's value. Nil for `auto` and unreported sources.
    public let defaultNumber: Double?
    /// What `auto` resolves to now.
    public let automaticNumber: Double?

    public var id: String { declaration.id }
    public var kind: ParameterKind { declaration.kind }
    public var group: AdjustmentGroupID { declaration.group }

    /// Shown but not usable now: a source value not reported yet.
    public var isAvailable: Bool { value != .unknown }

    public var isAutomatic: Bool {
        if case .automatic = value { return true }
        return false
    }

    /// The number shown, auto resolved included; nil when there is none.
    public var number: Double? {
        switch value {
        case .number(let number): return number
        case .automatic(let resolved): return resolved
        default: return nil
        }
    }

    public var isOn: Bool {
        if case .toggle(let on) = value { return on }
        return false
    }

    public var selectedOption: String? {
        if case .choice(let id) = value { return id }
        return nil
    }

    public var reference: String? {
        if case .reference(let id) = value { return id }
        return nil
    }

    /// A slider for this control: the declared range, step and origin, the
    /// default it resets to, and the readout. A `floatOrAuto` parameter gets
    /// an Auto state one below the range (`sliderValue` uses it). Nil for
    /// kinds that are not sliders.
    public var spec: ParameterSpec? {
        guard kind == .float || kind == .floatOrAuto, let range = declaration.range else { return nil }
        let step = declaration.step ?? (range.upperBound - range.lowerBound) / 100
        let automatic = kind == .floatOrAuto
            ? ParameterAutomatic(value: Self.automaticSentinel(range), resume: automaticNumber, resolved: automaticNumber)
            : nil
        let origin: Double? = declaration.origin == .zero ? min(max(0, range.lowerBound), range.upperBound) : nil
        let defaultValue = defaultNumber ?? automatic?.value ?? origin ?? range.lowerBound
        return ParameterSpec(range: range, step: step, defaultValue: defaultValue, origin: origin,
                             format: AdjustmentFormat.format(declaration.format, step: step), automatic: automatic)
    }

    /// The value a `ParameterSpec`-based slider binds to: the number, or the
    /// Auto sentinel below the range.
    public var sliderValue: Double {
        guard let range = declaration.range else { return 0 }
        switch value {
        case .automatic: return Self.automaticSentinel(range)
        case .number(let number): return number
        default: return defaultNumber ?? range.lowerBound
        }
    }

    static func automaticSentinel(_ range: ClosedRange<Double>) -> Double { range.lowerBound - 1 }

    /// How far the value is from its default, −1…1, for the iPhone ring: the
    /// ring is empty at the default, full at the end of the range in that
    /// direction (positive clockwise). Zero for Auto and non-numeric kinds.
    public var deviation: Double {
        guard let range = declaration.range, case .number(let number) = value else { return 0 }
        let base = defaultNumber ?? (declaration.origin == .zero ? 0 : range.lowerBound)
        let span = number >= base ? range.upperBound - base : base - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((number - base) / span, -1), 1)
    }

    /// The readout: "+0.30", "60%", "Auto · 2.4", "5500".
    public func readout(locale: Locale = .current) -> String {
        guard let spec else { return "" }
        return spec.formatted(sliderValue, locale: locale)
    }
}

/// One group as the inspector shows it.
public struct AdjustmentGroupState: Identifiable, Equatable, Sendable {
    public let group: AdjustmentGroupID
    /// The group's on/off switch in its header (HDR); nil for other groups.
    public let headerToggle: AdjustmentControl?
    /// Visible controls in declared order, the header switch excluded.
    public let controls: [AdjustmentControl]
    /// Controls away from their default, header switch included.
    public let modified: [AdjustmentControl]
    /// The chosen LUT's name (look group).
    public let lutName: String?

    public var id: AdjustmentGroupID { group }
    public var isModified: Bool { !modified.isEmpty }
    /// HDR's group only changes what lies above SDR white (p7-adjustments §1).
    public var affectsHDROnly: Bool { group == .hdr }
    /// The HDR group's switch is off: everything else in it is hidden.
    public var isSwitchedOff: Bool { headerToggle.map { !$0.isOn } ?? false }
}

/// Builds the controls for a recipe and applies their edits.
public struct AdjustmentPanel: Sendable {
    public var context: AdjustmentContext

    public init(context: AdjustmentContext = AdjustmentContext()) {
        self.context = context
    }

    /// Groups shown for this recipe, in display order. A group with nothing
    /// visible (detail for a non-RAW photo, the reserved local group) is left out.
    public func groups(for recipe: Recipe) -> [AdjustmentGroupState] {
        AdjustmentGroupID.displayOrder.compactMap { group(group: $0, in: recipe) }
    }

    public func group(group: AdjustmentGroupID, in recipe: Recipe) -> AdjustmentGroupState? {
        let visible = Adjustments.parameters(in: group).filter { isShown($0, in: recipe) }
        guard !visible.isEmpty else { return nil }
        let all = visible.map { control($0, in: recipe) }
        let header = all.first { Self.isHeaderToggle($0.declaration) }
        // Modified counts every declared parameter that applies to the photo,
        // including those an off switch hides, so a group reset is offered.
        let modified = Adjustments.parameters(in: group)
            .filter { $0.allows(recipe.inputDomain) && isCapable($0) }
            .map { control($0, in: recipe) }
            .filter { !$0.isDefault }
        return AdjustmentGroupState(group: group, headerToggle: header,
                                    controls: all.filter { !Self.isHeaderToggle($0.declaration) },
                                    modified: modified, lutName: group == .look ? recipe.look?.name : nil)
    }

    /// The header switch: the first bool of a group whose other parameters
    /// depend on it (`hdr.enabled`). `look.enabled` depends on a LUT itself,
    /// so it stays a row.
    static func isHeaderToggle(_ declaration: ParameterDeclaration) -> Bool {
        declaration.kind == .bool && declaration.visibleWhen == nil
            && Adjustments.parameters(in: declaration.group).contains { $0.visibleWhen?.references(declaration.id) == true }
    }

    public func control(_ id: String, in recipe: Recipe) -> AdjustmentControl? {
        Adjustments.declaration(id).map { control($0, in: recipe) }
    }

    func isCapable(_ declaration: ParameterDeclaration) -> Bool {
        declaration.capability.map { context.capabilities.contains($0) } ?? true
    }

    func isShown(_ declaration: ParameterDeclaration, in recipe: Recipe) -> Bool {
        Adjustments.isVisible(declaration, in: recipe) && isCapable(declaration)
    }

    public func control(_ declaration: ParameterDeclaration, in recipe: Recipe) -> AdjustmentControl {
        let id = declaration.id
        let domain = recipe.inputDomain
        let stored = recipe.value(for: id)
        let source = context.sourceValues[id]
        let automatic = context.automaticValues[id]
        var defaultNumber: Double?
        switch declaration.defaultValue(in: domain) {
        case .constant(let value): defaultNumber = value.numberValue
        case .fromSource: defaultNumber = source
        case .auto, .byDomain: defaultNumber = nil
        }
        let value: AdjustmentControl.Value
        switch declaration.kind {
        case .float, .floatOrAuto:
            if let number = stored?.numberValue {
                value = .number(number)
            } else if declaration.kind == .floatOrAuto, declaration.default == .auto {
                value = .automatic(resolved: automatic)
            } else if let defaultNumber {
                value = .number(defaultNumber)
            } else {
                value = .unknown
            }
        case .bool:
            value = .toggle(recipe.conditionValue(id)?.boolValue ?? false)
        case .choice:
            value = .choice(recipe.conditionValue(id)?.stringValue ?? declaration.options.first?.id ?? "")
        case .reference:
            value = .reference(recipe.conditionValue(id)?.stringValue)
        }
        var isDefault = recipe.isDefault(id)
        if !isDefault, case .fromSource = declaration.default, let source, stored?.numberValue == source {
            isDefault = true
        }
        return AdjustmentControl(declaration: declaration, value: value, isDefault: isDefault,
                                 options: declaration.options.filter { $0.domains.contains(domain) },
                                 disabledOptions: context.unavailableOptions[id] ?? [],
                                 defaultNumber: defaultNumber, automaticNumber: automatic)
    }

    // MARK: - Edits

    /// A number from a slider, a ruler or typed: snapped to the step and
    /// clamped. A value equal to the default is not stored, so the control
    /// reads as unchanged. A `fromSource` default need not be on the step
    /// grid (5612 K with steps of 50), so a value within half a step of it is
    /// the source's value, and clears the override.
    public func set(_ id: String, number: Double, in recipe: inout Recipe) {
        guard let declaration = Adjustments.declaration(id), let control = control(id, in: recipe),
              let spec = control.spec else { return }
        let snapped = spec.snapped(number)
        if case .fromSource = declaration.default, let source = context.sourceValues[id],
           abs(number - source) < spec.step / 2 || snapped == source {
            recipe.setValue(nil, for: id)
        } else {
            recipe.setValue(.number(snapped), for: id)
        }
    }

    /// The slider binding's write: the Auto sentinel returns to Auto.
    public func set(_ id: String, sliderValue: Double, in recipe: inout Recipe) {
        guard let control = control(id, in: recipe), let spec = control.spec else { return }
        if spec.isAutomatic(sliderValue) {
            setAutomatic(id, in: &recipe)
        } else {
            set(id, number: sliderValue, in: &recipe)
        }
    }

    public func set(_ id: String, isOn: Bool, in recipe: inout Recipe) {
        recipe.setValue(.bool(isOn), for: id)
    }

    /// Chooses an option offered in the photo's domain; others are ignored.
    public func set(_ id: String, option: String, in recipe: inout Recipe) {
        guard let control = control(id, in: recipe), control.options.contains(where: { $0.id == option }),
              !control.disabledOptions.contains(option) else { return }
        recipe.setValue(.string(option), for: id)
    }

    /// Chooses a LUT from the library (`look.lut`) or a model (`hdr.model`);
    /// nil removes the LUT. A LUT's spaces start from what the library
    /// records for it (`AdjustmentContext.lookSpaces`), in the same write, so
    /// the choice is one undo step. A space this photo cannot use (a Log
    /// input outside RAW) goes back to its default instead, so the recipe
    /// never names a space Render would refuse. Removing the LUT leaves the
    /// spaces alone; they are hidden without one.
    public func set(_ id: String, reference: String?, in recipe: inout Recipe) {
        if id == Recipe.lookID {
            recipe.look = reference.flatMap { hash in context.luts.first { $0.contentHash == hash } }
            if let look = recipe.look, let spaces = context.lookSpaces[look.contentHash] {
                setLookSpace(spaces.input, id: "look.input", in: &recipe)
                setLookSpace(spaces.output, id: "look.output", in: &recipe)
            }
        } else {
            recipe.setValue(reference.map(ParameterValue.string), for: id)
        }
    }

    private func setLookSpace(_ space: String, id: String, in recipe: inout Recipe) {
        guard let control = control(id, in: recipe) else { return }
        let offered = control.options.contains { $0.id == space } && !control.disabledOptions.contains(space)
        recipe.setValue(offered ? .string(space) : nil, for: id)
    }

    /// Back to Auto (a `floatOrAuto` parameter whose default is Auto).
    public func setAutomatic(_ id: String, in recipe: inout Recipe) {
        guard let declaration = Adjustments.declaration(id), declaration.kind == .floatOrAuto else { return }
        recipe.setValue(nil, for: id)
    }

    /// One control back to its declared default: constant, source or Auto.
    public func reset(_ id: String, in recipe: inout Recipe) {
        if id == Recipe.lookID {
            recipe.look = nil
        } else {
            recipe.setValue(nil, for: id)
        }
    }

    /// Every parameter of a group back to its default, hidden ones included.
    public func reset(group: AdjustmentGroupID, in recipe: inout Recipe) {
        for declaration in Adjustments.parameters(in: group) { reset(declaration.id, in: &recipe) }
    }

    /// Every declared parameter back to its default. Values for ids this
    /// build does not know are left alone.
    public func resetAll(in recipe: inout Recipe) {
        for group in AdjustmentGroupID.displayOrder { reset(group: group, in: &recipe) }
    }
}

extension ParameterCondition {
    /// Whether the condition reads `id`.
    func references(_ id: String) -> Bool {
        switch self {
        case .isOn(let other), .isSet(let other), .isOneOf(let other, _): return other == id
        case .all(let conditions): return conditions.contains { $0.references(id) }
        }
    }
}

/// Readout formats for the declared `ParameterFormat`s, in the declared units
/// (a percent parameter stores 60 for 60 %).
enum AdjustmentFormat {
    static func format(_ format: HyperDRRecipe.ParameterFormat?, step: Double) -> ParameterFormat {
        let digits = fractionDigits(step)
        switch format {
        case .ev: return .signed(fractionDigits: max(digits, 2))
        case .signed: return .signed(fractionDigits: digits)
        case .percent:
            return ParameterFormat { $0.formatted(.number.precision(.fractionLength(digits)).grouping(.never)) + "%" }
        case .stops: return .number(fractionDigits: max(digits, 1))
        case .kelvin, .integer, nil:
            return ParameterFormat { $0.formatted(.number.precision(.fractionLength(digits)).grouping(.never)) }
        }
    }

    static func fractionDigits(_ step: Double) -> Int { ParameterSpec.fractionDigits(step) }
}
