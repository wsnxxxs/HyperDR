import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// A section's tile in the dock's ring row (controls-polish §8.1): a rounded
/// square rather than a ring, since it opens a page instead of choosing a
/// value. A dot marks a section with changes.
struct SectionTile: View {
    let kind: AdjustmentSections.Kind
    let marked: Bool
    let open: () -> Void

    /// The sections a group holds, in its declared order.
    static func sections(in state: AdjustmentGroupState) -> [AdjustmentSections.Kind] {
        state.controls.compactMap { AdjustmentSections.section(anchoredBy: $0.id) }
    }

    static func isModified(_ kind: AdjustmentSections.Kind, in state: AdjustmentGroupState) -> Bool {
        state.controls.contains { AdjustmentSections.kind(of: $0.id) == kind && !$0.isDefault }
    }

    var body: some View {
        Button(action: open) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.14))
                    }
                    .overlay {
                        Image(systemName: DockSectionPane.symbol(kind))
                            .font(.system(size: 16))
                            .foregroundStyle(Color.secondary)
                    }
                    .overlay(alignment: .topTrailing) {
                        if marked { Circle().fill(Color.hdr.accent).frame(width: 6, height: 6).padding(5) }
                    }
                    .frame(width: 44, height: 44)
                DockSectionPane.title(kind)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            .frame(width: 62)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(DockSectionPane.title(kind))
        .accessibilityValue(marked ? Text("ipad.page.changed") : Text(verbatim: ""))
        .accessibilityHint(Text("ios.section.openHint"))
    }
}

/// A section's page on the iPhone's dock (controls-polish §8): the dock rises
/// to hold it and the photo above shrinks but stays whole. ‹ goes back to the
/// rings, as does any tab. The curve is the shared curve section; the mixer
/// and the grading keep the dock's own way, rings and the ruler.
struct DockSectionPane: View {
    @Binding var recipe: Recipe
    let panel: AdjustmentPanel
    let kind: AdjustmentSections.Kind
    var axis: Axis = .horizontal
    var onEditingChanged: (ParameterDeclaration, Bool) -> Void = { _, _ in }
    let back: () -> Void

    @State private var attribute = MixerAttribute.hue
    @State private var band = MixerBand.red
    @State private var zone = WheelZone.midtones
    /// The grading ring the ruler sets.
    @State private var gradeRing = GradeRing.luminance
    @State private var typing = false
    @State private var hueDraft = ""
    @State private var saturationDraft = ""
    @Environment(\.mixerPicking) private var mixerPicking

    enum GradeRing: Hashable { case luminance, blending, balance }

    static func symbol(_ kind: AdjustmentSections.Kind) -> String {
        switch kind {
        case .curves: "chart.xyaxis.line"
        case .mixer: "paintpalette"
        case .grading: "circle.circle"
        }
    }

    static func title(_ kind: AdjustmentSections.Kind) -> Text {
        switch kind {
        case .curves: Text("ios.section.curve")
        case .mixer: Text("ios.section.mixer")
        case .grading: Text("ios.section.grading")
        }
    }

    var body: some View {
        VStack(spacing: Space.s2) {
            header
            switch kind {
            case .curves: curvePage
            case .mixer: mixerPage
            case .grading:
                if axis == .vertical {
                    // The column on the right is short: the page scrolls.
                    ScrollView(.vertical, showsIndicators: false) { gradingPage }
                        .scrollBounceBehavior(.basedOnSize)
                } else {
                    gradingPage
                }
            }
        }
        // The curve reads from the top; the rings keep the ruler at the foot, as on the other tabs.
        .frame(maxHeight: .infinity, alignment: kind == .curves ? .top : .bottom)
        .padding(.horizontal, axis == .horizontal ? Space.s4 : 0)
        .onChange(of: attribute) { _, now in mixerPicking?.setAttribute(now) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Space.s2) {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.backward").font(.system(size: 15, weight: .semibold))
                    Self.title(kind).font(.headline)
                }
                .frame(minHeight: 36)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("ios.section.back"))
            .accessibilityValue(Self.title(kind))
            Spacer(minLength: 0)
            if kind == .mixer, let mixerPicking {
                PickToolButton.mixer(isActive: mixerPicking.isActive, size: 36) {
                    mixerPicking.setAttribute(attribute)
                    mixerPicking.toggle()
                }
            }
            if kind != .curves, isModified {
                Button(action: resetSection) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondary)
                .accessibilityLabel(Text(kind == .mixer ? "ios.section.resetMixer" : "ios.section.resetGrading"))
            }
        }
        .frame(minHeight: 36)
    }

    private var sectionIDs: [String] {
        switch kind {
        case .curves: []
        case .mixer: MixerBand.allCases.flatMap { band in MixerAttribute.allCases.map(band.id) }
        case .grading: WheelZone.allCases.flatMap { [$0.hueID, $0.saturationID, $0.luminanceID] }
            + [WheelZone.blendingID, WheelZone.balanceID]
        }
    }

    private var isModified: Bool { sectionIDs.contains { !(panel.control($0, in: recipe)?.isDefault ?? true) } }

    private func resetSection() {
        var edited = recipe
        for id in sectionIDs { panel.reset(id, in: &edited) }
        recipe = edited
    }

    // MARK: Curve

    @ViewBuilder private var curvePage: some View {
        // The section's anchor, the luminance curve.
        if let control = panel.groups(for: recipe).flatMap(\.controls)
            .first(where: { AdjustmentSections.section(anchoredBy: $0.id) == .curves }) {
            ScrollView(.vertical, showsIndicators: false) {
                ToneCurveSection(recipe: $recipe, control: control, panel: panel, style: .touch, showsTitle: false,
                                 onEditingChanged: onEditingChanged)
                    .environment(\.sectionPlotSide, axis == .horizontal ? 220 : 260)
                    .environment(\.sectionControls, PadGroupControls.sectionControls(tint: Color.hdr.accent))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: Mixer

    private var mixerPage: some View {
        let current = panel.control(band.id(attribute), in: recipe)
        return VStack(spacing: Space.s2) {
            PadSegments(options: MixerAttribute.allCases.map { PadSegments.Option(value: $0, label: $0.title) },
                        selection: attribute) { attribute = $0 }
                .frame(maxWidth: 420)
            if axis == .horizontal {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s2) { bandRings }
                        .padding(.horizontal, Space.s2)
                }
                .scrollClipDisabled()
            } else {
                // Standing on the right: two rows of four.
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(62), spacing: Space.s2), count: 4), spacing: Space.s2) {
                    bandRings
                }
            }
            if let current {
                readout(band.title + Text(verbatim: " · ") + attribute.title, current)
                ruler(current)
            }
        }
    }

    private var bandRings: some View {
        ForEach(MixerBand.allCases) { option in
            if let control = panel.control(option.id(attribute), in: recipe) {
                AdjustmentRing(control: control, isCurrent: option == band, tint: option.swatch,
                               title: option.title, swatch: option.swatch)
                    .onTapGesture { withAnimation(.smooth(duration: 0.2)) { band = option } }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { panel.reset(control.id, in: &recipe) })
            }
        }
    }

    // MARK: Grading

    private var gradingPage: some View {
        let ringControl = panel.control(gradeID(gradeRing), in: recipe)
        return VStack(spacing: Space.s2) {
            PadSegments(options: WheelZone.allCases.map { PadSegments.Option(value: $0, label: $0.title) },
                        selection: zone) { zone = $0 }
                .frame(maxWidth: 420)
            let wheelSide: CGFloat = axis == .horizontal ? 156 : 140
            // Beside the wheel: a row under the canvas, a column in the right-hand dock.
            let ringLayout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: Space.s1)) : AnyLayout(VStackLayout(spacing: 2))
            let rings = ringLayout {
                ForEach([GradeRing.luminance, .blending, .balance], id: \.self) { ring in
                    if let control = panel.control(gradeID(ring), in: recipe) {
                        AdjustmentRing(control: control, isCurrent: ring == gradeRing, tint: Color.hdr.accent,
                                       title: ring == .luminance ? MixerAttribute.luminance.title : nil)
                            .onTapGesture { withAnimation(.smooth(duration: 0.2)) { gradeRing = ring } }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { panel.reset(control.id, in: &recipe) })
                    }
                }
            }
            HStack(alignment: .center, spacing: Space.s3) {
                VStack(spacing: 2) {
                    GradingZoneWheel(recipe: $recipe, panel: panel, zone: zone, style: .touch,
                                     onEditingChanged: onEditingChanged)
                        .frame(width: wheelSide, height: wheelSide)
                    wheelReadout
                }
                rings.frame(maxWidth: .infinity)
            }
            if let ringControl {
                readout(gradeRing == .luminance ? zone.title + Text(verbatim: " · ") + MixerAttribute.luminance.title
                                                : AdjustmentText.label(ringControl.declaration), ringControl)
                ruler(ringControl)
            }
        }
        .alert(zone.title, isPresented: $typing) {
            TextField(text: $hueDraft) { MixerAttribute.hue.title }.keyboardType(.numbersAndPunctuation)
            TextField(text: $saturationDraft) { MixerAttribute.saturation.title }.keyboardType(.numbersAndPunctuation)
            Button(role: .cancel) {} label: { Text("ios.adjust.cancel") }
            Button {
                var edited = recipe
                if let hue = Double(hueDraft.replacingOccurrences(of: "°", with: "")) {
                    panel.set(zone.hueID, number: hue, in: &edited)
                }
                if let saturation = Double(saturationDraft) { panel.set(zone.saturationID, number: saturation, in: &edited) }
                recipe = edited
            } label: {
                Text("ios.adjust.apply")
            }
        }
    }

    private func gradeID(_ ring: GradeRing) -> String {
        switch ring {
        case .luminance: zone.luminanceID
        case .blending: WheelZone.blendingID
        case .balance: WheelZone.balanceID
        }
    }

    private func number(_ id: String) -> Double {
        if case .number(let value)? = panel.control(id, in: recipe)?.value { return value }
        return 0
    }

    /// "215° · 55": the wheel's hue and saturation; tapping types them.
    private var wheelReadout: some View {
        let hue = number(zone.hueID), saturation = number(zone.saturationID)
        return Button {
            hueDraft = String(Int(hue.rounded()))
            saturationDraft = String(Int(saturation.rounded()))
            typing = true
        } label: {
            HStack(spacing: 5) {
                Circle().fill(GradingZoneWheel.colour(hue: hue, saturation: saturation)).frame(width: 7, height: 7)
                Text(verbatim: "\(Int(hue.rounded()))° · \(Int(saturation.rounded()))")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(saturation == 0 ? Color.secondary : Color.primary)
            }
            .frame(minHeight: 28)
            .padding(.horizontal, Space.s2)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("ios.adjust.typeHint"))
    }

    // MARK: Shared

    private func readout(_ title: Text, _ control: AdjustmentControl) -> some View {
        HStack(spacing: Space.s2) {
            title.font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            Text(verbatim: control.readout())
                .font(.footnote.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
        .frame(minHeight: 24)
    }

    private func ruler(_ control: AdjustmentControl) -> some View {
        AdjustmentRuler(control: control,
                        write: { panel.set(control.id, number: $0, in: &recipe) },
                        reset: { panel.reset(control.id, in: &recipe) },
                        onEditingChanged: { onEditingChanged(control.declaration, $0) })
            .id(control.id)
            .frame(height: 40)
    }
}
