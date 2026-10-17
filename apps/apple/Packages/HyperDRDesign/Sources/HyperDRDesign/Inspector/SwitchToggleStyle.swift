import SwiftUI

/// The inspector's on/off switch (CSS `.prefs-switch`): a 40 × 24 track,
/// accent when on, with the label leading and the switch trailing.
///
/// VoiceOver sees a system switch; with keyboard navigation on, the switch
/// takes focus and Space toggles it.
public struct HDRSwitchToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.s3) {
            configuration.label
                .font(.hdr.caption)
            Spacer(minLength: 0)
            SwitchBody(configuration: configuration)
        }
        // One switch named by the label, as a system toggle.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
    }
}

private struct SwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    var body: some View {
        let on = configuration.isOn
        Button {
            withHDRAnimation { configuration.isOn.toggle() }
        } label: {
            Capsule()
                .fill(on ? Color.hdr.accentFill : Color.hdr.controlTrack)
                .overlay { Capsule().strokeBorder(on ? Color.hdr.accentFill : Color.hdr.lineStrong) }
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle()
                        .fill(on ? Color.hdr.accentInk : Color.hdr.inkMuted)
                        .frame(width: 16, height: 16)
                        .padding(4)
                }
                .frame(width: 40, height: 24)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .overlay {
            if focused { Capsule().stroke(Color.hdr.focus, lineWidth: 2).padding(-3) }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

public extension ToggleStyle where Self == HDRSwitchToggleStyle {
    /// `.toggleStyle(.hdrSwitch)`.
    static var hdrSwitch: HDRSwitchToggleStyle { HDRSwitchToggleStyle() }
}
