import SwiftUI
import HyperDRDesign

/// The camera and lens group (M3 §12.4, raw-states.md §4): which camera and
/// lens made a RAW, whether macOS corrects the lens, and which RAW decoder
/// version developed it. The lens correction is a switch where macOS knows the
/// lens (on by default, one undo step); elsewhere a sentence says why not.
struct CameraGroup: View {
    let model: EditorModel

    @State private var isExpanded: Bool
    @Environment(\.locale) private var locale

    init(model: EditorModel, startsExpanded: Bool = false) {
        self.model = model
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        if let raw = model.document?.source?.raw {
            ParameterGroup("camera.title", systemImage: "camera.aperture",
                           summary: Text(LocalizedStringKey(model.cameraSummaryKey ?? "camera.summary.unsupported")),
                           isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: Space.s3) {
                    FactRow(label: Text("camera.camera"), value: Text(verbatim: model.captureFacts.model ?? "—"),
                            tone: model.captureFacts.model == nil ? .muted : .normal)
                    FactRow(label: Text("camera.lens"), value: Text(verbatim: model.captureFacts.lens ?? "—"),
                            tone: model.captureFacts.lens == nil ? .muted : .normal)
                    if raw.lensCorrectionSupported {
                        HStack {
                            // The switch carries the name for VoiceOver (and reads on/off itself).
                            Text("camera.lensCorrection").font(Font.hdr.control).foregroundStyle(Color.hdr.ink)
                                .accessibilityHidden(true)
                            Spacer(minLength: Space.s3)
                            Toggle("camera.lensCorrection",
                                   isOn: Binding(get: { model.edit.lensCorrection }, set: { model.setLensCorrection($0) }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                        .disabled(model.isEditingLocked)
                    } else {
                        Text("camera.summary.unsupportedNote")
                            .font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    engineRow(decoderVersion: raw.decoderVersion)
                }
                .padding(.top, Space.s3)
            }
        }
    }

    private func engineRow(decoderVersion: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Text("camera.engine")
                .font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                .frame(width: FactRow.labelWidth, alignment: .leading)
            Text(verbatim: Self.engineText(decoderVersion, locale: locale))
                .font(Font.hdr.readout).foregroundStyle(Color.hdr.inkMuted)
            Image(systemName: "info.circle")
                .font(.system(size: TypeScale.Size.caption))
                .foregroundStyle(Color.hdr.inkMuted)
                .help(Text("camera.engine.help"))
                .accessibilityLabel(Text("camera.engine.help"))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// "macOS · decoder 8", or "macOS · decoder 8 · DNG" for a version like "8.dng".
    static func engineText(_ decoderVersion: String, locale: Locale) -> String {
        let isDNG = decoderVersion.hasSuffix(".dng")
        let version = isDNG ? String(decoderVersion.dropLast(4)) : decoderVersion
        return AppStrings.format(isDNG ? "camera.engine.valueDNG %@" : "camera.engine.value %@", locale: locale, version)
    }
}
