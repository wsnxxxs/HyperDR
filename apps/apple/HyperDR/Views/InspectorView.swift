import SwiftUI
import HyperDRDesign

/// The trailing inspector: the scopes on top, then the photograph's facts and
/// input colour, the processing mode and the adjustment groups. Without a
/// photograph it shows the three steps instead.
///
/// Every control is generated from the model's own description of it
/// (`EditControls`), and each row reads only its own value.
struct InspectorView: View {
    let model: EditorModel
    var window = EditorWindowState()

    var body: some View {
        ScrollView {
            InspectorContent(model: model, window: window)
        }
        .background(Color.hdr.surfacePanel)
        // Pinned above the scrolling inspector: the export's status card.
        .safeAreaInset(edge: .top, spacing: 0) {
            ExportStatusHost(model: model, window: window)
                .background(Color.hdr.surfacePanel)
        }
    }
}

/// The inspector's column, without the scroll view around it (which a
/// snapshot cannot size).
struct InspectorContent: View {
    let model: EditorModel
    var window = EditorWindowState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.workspace == .editing, let document = model.document {
                ScopeSection(model: model)
                Divider()
                ExportLockRegion(model: model, window: window) {
                    VStack(alignment: .leading, spacing: 0) {
                        PhotoInfoSection(document: document, model: model)
                        Divider()
                        WorkflowSection(model: model)
                        Divider()
                        AdjustmentSection(model: model)
                        FineTuneGroup(model: model)
                        RegionGroup(model: model)
                        LUTGroup(model: model, window: window)
                        CameraGroup(model: model)
                    }
                }
            } else {
                Welcome()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Photo

/// What M1 knows about the open photograph: the file's own facts, then what
/// the decoder reported with the reference frame. A fact not known yet reads
/// as a dash.
private struct PhotoInfoSection: View {
    let document: DocumentState
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SectionHeading("mac.info.title")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.s4, verticalSpacing: Space.s2) {
                row("mac.info.dimensions", dimensions.map { Text(verbatim: $0) })
                row("mac.info.format", Text(verbatim: document.formatLabel))
                row("mac.info.size", fileSize.map { Text(verbatim: $0) })
                row("mac.info.type", document.source.map { Text($0.domain.label) })
                row("mac.info.color", document.source.map { Text(verbatim: $0.colorName) })
            }
            if let reasons = document.source?.degradationReasons, let sentence = DecodeDegradation.text(reasons) {
                Label {
                    Text(sentence)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.warn)
            }
            InputColorSelector(model: model)
        }
        .padding(20)
    }

    private func row(_ title: LocalizedStringKey, _ value: Text?) -> some View {
        GridRow {
            Text(title)
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
            (value ?? Text(verbatim: "—"))
                .font(Font.hdr.readout)
                .foregroundStyle(Color.hdr.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var dimensions: String? {
        document.pixelSize.map { "\($0.width) × \($0.height)" }
    }

    private var fileSize: String? {
        document.byteCount > 0 ? document.byteCount.formatted(.byteCount(style: .file)) : nil
    }
}

extension InputDomain {
    /// The photograph's kind as the status bar and inspector name it.
    var label: LocalizedStringKey {
        switch self {
        case .sceneReferred: "stage.input.scene"
        case .sdr: "stage.input.sdr"
        case .hdr: "stage.input.hdr"
        case .dual: "stage.input.dual"
        case .unknown: "stage.input.unknown"
        }
    }
}

// MARK: - Empty

private struct Welcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("welcome.title")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.hdr.inkStrong)
            Text("mac.welcome.description")
                .font(Font.hdr.control)
                .foregroundStyle(Color.hdr.inkMuted)
                .lineSpacing(5)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 26) {
                Step(number: "01", title: "welcome.import", note: "welcome.importNote")
                Step(number: "02", title: "welcome.adjust", note: "welcome.adjustNote")
                Step(number: "03", title: "welcome.export", note: "welcome.exportNote")
            }
            .padding(.top, Space.s6)
        }
        .padding(EdgeInsets(top: 28, leading: Layout.panelPadding, bottom: 28, trailing: Layout.panelPadding))
    }

    private struct Step: View {
        var number: String
        var title: LocalizedStringKey
        var note: LocalizedStringKey

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Text(verbatim: number)
                    .font(Font.hdr.mono())
                    .foregroundStyle(Color.hdr.inkMuted)
                    .frame(width: 26, alignment: .leading)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(title)
                        .font(.system(size: TypeScale.Size.control, weight: .medium))
                        .foregroundStyle(Color.hdr.ink)
                    Text(note)
                        .font(Font.hdr.caption)
                        .foregroundStyle(Color.hdr.inkMuted)
                }
            }
        }
    }
}

// MARK: - Input colour

/// Which colour space a file without a colour tag was made in. Selectable
/// only for such files; a tagged file shows the choice resting, and the
/// tooltip says why. Not for RAW.
private struct InputColorSelector: View {
    let model: EditorModel

    var body: some View {
        let input = model.inputColor
        if input.isVisible {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("input.color")
                    .font(Font.hdr.caption)
                    .foregroundStyle(input.isEnabled ? Color.hdr.inkMuted : Color.hdr.inkDisabled)
                ParameterSegmented("input.color", selection: Binding(get: { input.selection },
                                                                    set: { model.selectInputColor($0) }),
                                   choices: input.choices.map {
                                       SegmentedChoice(LocalizedStringKey($0.labelKey), value: $0.id,
                                                       isEnabled: $0.isEnabled)
                                   }, size: .small)
                    .disabled(!input.isEnabled)
                if input.isEnabled {
                    Text("input.color.note")
                        .font(Font.hdr.caption)
                        .foregroundStyle(Color.hdr.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, Space.s2)
            .help(input.disabledReasonKey.map { Text(LocalizedStringKey($0)) } ?? Text(verbatim: ""))
        }
    }
}
