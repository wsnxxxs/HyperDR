import Foundation
import HyperDRRecipe
import SwiftUI

/// The words of the generated controls. Every key comes from a declaration
/// (`labelKey`, `helpKey`, `undoKey`, option and group keys), and all of them
/// live in this package's catalogue, so the Mac and iOS apps say the same
/// thing. `scripts/check_apple_i18n.py` derives the same key set from
/// `Adjustments.swift` (M2 §12, approach a).
public enum AdjustmentText {
    public static func label(_ declaration: ParameterDeclaration) -> Text {
        Text(LocalizedStringKey(declaration.labelKey), bundle: .module)
    }

    public static func help(_ declaration: ParameterDeclaration) -> Text {
        Text(LocalizedStringKey(declaration.helpKey), bundle: .module)
    }

    public static func option(_ option: ParameterOption) -> Text {
        Text(LocalizedStringKey(option.labelKey), bundle: .module)
    }

    public static func group(_ group: AdjustmentGroupID) -> Text {
        Text(LocalizedStringKey(group.labelKey), bundle: .module)
    }

    /// Words of the controls themselves, for hosts that draw their own
    /// (the iPhone bar): menus, the Auto key, Reset All.
    public enum Command: Sendable {
        case resetToDefault, setAuto, auto, resetGroup, resetAll, noLUT
    }

    public static func command(_ command: Command) -> Text {
        switch command {
        case .resetToDefault: return Text("design.slider.reset", bundle: .module)
        case .setAuto: return Text("design.slider.setAuto", bundle: .module)
        case .auto: return Text("design.slider.auto", bundle: .module)
        case .resetGroup: return Text("group.reset", bundle: .module)
        case .resetAll: return Text("design.adjust.resetAll", bundle: .module)
        case .noLUT: return Text("look.lut.none", bundle: .module)
        }
    }

    /// The undo action name ("Change Exposure"), for the host's undo manager.
    public static func undoName(_ declaration: ParameterDeclaration, locale: Locale = .current) -> String {
        DesignStrings.string(declaration.undoKey, locale: locale)
    }

    /// The undo action name of a reset ("Reset Light", "Reset All").
    public static func undoName(_ reset: AdjustmentReset, locale: Locale = .current) -> String {
        switch reset {
        case .group(let group):
            return String(format: DesignStrings.string("undo.resetGroup %@", bundle: .module, locale: locale),
                          DesignStrings.string(group.labelKey, locale: locale))
        case .all:
            return DesignStrings.string("undo.resetAll", bundle: .module, locale: locale)
        }
    }

    public static func labelString(_ declaration: ParameterDeclaration, locale: Locale = .current) -> String {
        DesignStrings.string(declaration.labelKey, locale: locale)
    }

    /// The collapsed group's summary (§5.1): up to two changed controls with
    /// their values ("Exposure +0.30 · Contrast +10 · +1"), a switch as on or
    /// off, a choice by its option; the LUT's name for the look group; with
    /// nothing changed, the lens correction for the detail group, else
    /// "No changes".
    public static func summary(_ state: AdjustmentGroupState, locale: Locale = .current) -> String {
        if state.group == .look, let name = state.lutName { return name }
        if state.modified.isEmpty {
            if state.group == .detail, let lens = state.controls.first(where: { $0.kind == .bool }) {
                return describe(lens, locale: locale)
            }
            return DesignStrings.string("group.summary.none", bundle: .module, locale: locale)
        }
        var parts = state.modified.prefix(2).map { describe($0, locale: locale) }
        if state.modified.count > 2 {
            let more = DesignStrings.string("group.summary.more %@", bundle: .module, locale: locale)
            parts.append(String(format: more, "\(state.modified.count - 2)"))
        }
        return parts.joined(separator: " · ")
    }

    private static func describe(_ control: AdjustmentControl, locale: Locale) -> String {
        let label = labelString(control.declaration, locale: locale)
        let item = DesignStrings.string("group.summary.item %@ %@", bundle: .module, locale: locale)
        switch control.kind {
        case .float, .floatOrAuto:
            return String(format: item, label, control.readout(locale: locale))
        case .bool:
            return String(format: (control.isOn ? DesignStrings.string("group.summary.on %@", bundle: .module, locale: locale)
                                  : DesignStrings.string("group.summary.off %@", bundle: .module, locale: locale)), label)
        case .choice:
            guard let option = control.options.first(where: { $0.id == control.selectedOption }) else { return label }
            return String(format: item, label, DesignStrings.string(option.labelKey, locale: locale))
        case .reference:
            return label
        }
    }

    /// Every key the declarations produce: what the catalogue must hold.
    /// Group keys for groups with no parameter (the reserved local group) are left out.
    public static var declaredKeys: Set<String> {
        var keys = Set<String>()
        for declaration in Adjustments.all {
            keys.formUnion([declaration.labelKey, declaration.helpKey, declaration.undoKey])
            keys.formUnion(declaration.options.map(\.labelKey))
        }
        for group in AdjustmentGroupID.displayOrder where !Adjustments.parameters(in: group).isEmpty {
            keys.insert(group.labelKey)
        }
        return keys
    }
}

/// SF Symbols for groups and controls. A control not listed uses its group's.
public enum AdjustmentSymbols {
    public static func group(_ group: AdjustmentGroupID) -> String {
        switch group {
        case .hdr: return "sun.max"
        case .light: return "circle.lefthalf.filled"
        case .color: return "drop"
        case .look: return "camera.filters"
        case .detail: return "camera.aperture"
        case .local: return "scope"
        }
    }

    private struct Entry { let id: String; let symbol: String }

    private static let controls: [String: String] = Dictionary(uniqueKeysWithValues: [
        Entry(id: "hdr.strength", symbol: "sun.max"),
        Entry(id: "hdr.range", symbol: "arrow.up.to.line"),
        Entry(id: "hdr.expansionStart", symbol: "arrow.right.to.line"),
        Entry(id: "hdr.coverage", symbol: "circle.dashed"),
        Entry(id: "hdr.sdrRolloff", symbol: "sun.horizon"),
        Entry(id: "tone.exposure", symbol: "plusminus.circle"),
        Entry(id: "tone.contrast", symbol: "circle.righthalf.filled"),
        Entry(id: "tone.highlights", symbol: "sun.max.circle"),
        Entry(id: "tone.shadows", symbol: "moon.circle"),
        Entry(id: "tone.blacks", symbol: "circle.fill"),
        Entry(id: "develop.temperature", symbol: "thermometer.medium"),
        Entry(id: "color.warmth", symbol: "thermometer.medium"),
        Entry(id: "develop.tint", symbol: "eyedropper.halffull"),
        Entry(id: "color.tint", symbol: "eyedropper.halffull"),
        Entry(id: "color.vibrance", symbol: "drop.halffull"),
        Entry(id: "color.saturation", symbol: "drop.fill"),
        Entry(id: "look.strength", symbol: "camera.filters"),
        Entry(id: "develop.luminanceNR", symbol: "aqi.low"),
        Entry(id: "develop.colorNR", symbol: "circle.hexagongrid"),
        Entry(id: "develop.sharpness", symbol: "triangle"),
    ].map { ($0.id, $0.symbol) })

    public static func control(_ declaration: ParameterDeclaration) -> String {
        controls[declaration.id] ?? group(declaration.group)
    }
}
