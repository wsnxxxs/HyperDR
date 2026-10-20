import SwiftUI
import HyperDRDesign
import HyperDRKit
import HyperDRRecipe

/// The export panel, a sheet over the editor window (M3 §3, §6, §7): the
/// settings before an export, the progress while it runs, the result or the
/// failure after. It follows the model's phase, so closing it never stops an
/// export and opening it during one shows the progress.
struct ExportSheet: View {
    let model: EditorModel
    let window: EditorWindowState

    @Environment(\.dismiss) private var dismiss
    @State private var sheetWindow: NSWindow?
    /// "Export Again" on a result: the settings, even though the result still matches.
    @State private var wantsSettings = false

    var body: some View {
        let mode = ExportPresentation.PanelMode(
            phase: model.export.phase,
            hasMatchingResult: model.export.result != nil && !model.export.isResultStale,
            wantsSettings: wantsSettings)
        Group {
            switch mode {
            case .settings: ExportSettingsView(model: model, close: close, begin: begin, changeFrame: changeFrame)
            case .progress: ExportProgressView(model: model, close: close)
            case .result: ExportResultView(model: model, close: closeAndClear, begin: begin, again: again)
            case .failure: ExportFailureView(model: model, close: closeAndClear, again: again)
            }
        }
        .onChange(of: model.export.isInFlight) { _, running in if running { wantsSettings = false } }
        .frame(width: mode.width)
        .background(Color.hdr.surfacePanel)
        .background(WindowReader { sheetWindow = $0 })
    }

    private func close() { dismiss() }

    /// The frame panel takes this panel's place and gives it back when it closes.
    private func changeFrame() { window.changeFrameFromExport() }

    /// Done / Close after an outcome: the outcome has been seen, so the
    /// inspector's card goes too.
    private func closeAndClear() {
        model.export.dismissOutcome()
        dismiss()
    }

    private func again() {
        wantsSettings = true
        model.export.dismissOutcome()
    }

    private func begin() {
        ExportFlow.begin(model: model, choosePlace: ExportSavePanel.chooser(on: sheetWindow))
    }
}

// MARK: - Settings

private struct ExportSettingsView: View {
    let model: EditorModel
    let close: () -> Void
    let begin: () -> Void
    let changeFrame: () -> Void

    @Environment(\.locale) private var locale
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Kit's plan, for its memory check, while nothing else blocks.
        let plan = model.export.blockerKey == nil ? model.exportPlan() : nil
        VStack(spacing: 0) {
            Text("export.title")
                .font(Font.hdr.title)
                .foregroundStyle(Color.hdr.inkStrong)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s5)
                .padding(.vertical, Space.s4)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ExportSummaryColumn(model: model, changeFrame: changeFrame)
                    .frame(width: 212)
                Divider()
                settings(plan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer(plan)
        }
    }

    private func settings(_ plan: ExportPlan?) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if model.export.phase == .cancelled {
                InspectorNotice(Text("export.stoppedNotice"), style: .info)
            }
            ForEach(ExportPresentation.groups(for: model.workflow), id: \.titleKey) { group in
                FormatCardGroup(title: Text(LocalizedStringKey(group.titleKey)), items: items(group.ids),
                                selection: selection, columns: group.columns)
            }
            Text(LocalizedStringKey(encodingKey("detail")))
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            // Kit's notes on what this format writes (the peak's ceiling,
            // an SDR version, a transparency fill).
            ForEach(plan?.notices ?? [], id: \.self) { notice in
                InspectorNotice(Text(verbatim: notice.phrase.text(locale: locale)), style: .info)
            }
            colorSetting
            sizeSetting
            if model.exportQuality != nil { ExportQualitySlider(model: model) }
        }
        .padding(Space.s5)
        .disabled(model.isEditingLocked)
    }

    // MARK: Formats

    private var selection: Binding<String> {
        Binding(get: { model.export.encodingID }, set: { id in
            model.selectEncoding(id)
        })
    }

    private func encodingKey(_ part: String) -> String { "enc.\(model.export.encodingID).\(part)" }

    private func items(_ ids: [String]) -> [FormatCardItem<String>] {
        ids.map { id in
            let labelKey = "enc.\(id).label", hintKey = "enc.\(id).hint"
            let name = AppStrings.string(labelKey, locale: locale)
            let reason = model.export.encodingAvailability[id] ?? nil
            return FormatCardItem(
                id: id, name: Text(LocalizedStringKey(labelKey)),
                detail: Text(LocalizedStringKey(hintKey)),
                unavailableReason: reason.map { Text(LocalizedStringKey(ExportPresentation.shortReasonKey($0))) },
                help: reason.map { Text(ExportPresentation.blockerText($0, formatName: name, locale: locale)) })
        }
    }

    // MARK: Colour

    @ViewBuilder private var colorSetting: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("export.color")
                .font(Font.hdr.control)
                .foregroundStyle(Color.hdr.ink)
            if model.workflow == .colorOnly {
                ParameterSegmented("export.color", selection: Binding(get: { model.export.outputGamut },
                                                                     set: { model.setOutputGamut($0) }),
                                   choices: [SegmentedChoice("choice.outputGamut.srgb", value: "srgb"),
                                             SegmentedChoice("choice.outputGamut.p3", value: "p3")],
                                   size: .small)
            } else {
                // An HDR format fixes its gamut: P3 for a gain map, Rec. 2020 for BT.2100.
                Text(LocalizedStringKey(model.export.gamut.labelKey))
                    .font(Font.hdr.body)
                    .foregroundStyle(Color.hdr.inkMuted)
            }
        }
    }

    // MARK: Size

    /// Original size, a common long edge smaller than the photo, or a typed
    /// one (p7-3c-export §1.3 B).
    @ViewBuilder private var sizeSetting: some View {
        let binding = Binding(get: { model.export.longEdge }, set: { model.setExportLongEdge($0) })
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("export.size")
                .font(Font.hdr.control)
                .foregroundStyle(Color.hdr.ink)
            HStack(spacing: Space.s3) {
                Picker(selection: binding) {
                    ForEach(ExportLongEdge.choices(photo: model.exportPhotoLongEdge, current: model.export.longEdge),
                            id: \.self) { edge in
                        if let edge {
                            Text("export.size.pixels \(String(edge))").tag(Int?.some(edge))
                        } else {
                            Text("export.size.original").tag(Int?.none)
                        }
                    }
                } label: {
                    Text("export.size")
                }
                .labelsHidden()
                .fixedSize()
                TextField(value: binding, format: .number.grouping(.never), prompt: Text("export.size.custom")) {
                    Text("export.size.custom")
                }
                .labelsHidden()
                .frame(width: 120)
            }
        }
    }

    // MARK: Footer

    private func footer(_ plan: ExportPlan?) -> some View {
        let blocker = plan?.blockers.first
        return HStack(spacing: Space.s3) {
            if let blocker { planNote(blocker) } else { footerNote }
            Spacer(minLength: Space.s3)
            Button("export.action.cancel", action: close)
                .buttonStyle(.hdrSecondary)
                .keyboardShortcut(.cancelAction)
            Button(LocalizedStringKey(ExportPresentation.primaryActionKey(encoding: model.export.encodingID,
                                                                          asksForPlace: asksForPlace)), action: begin)
                .buttonStyle(.hdrPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(model.export.blockerKey != nil || blocker != nil)
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
    }

    /// Why Kit's plan cannot run, and, when memory is why, the largest long
    /// edge that fits.
    private func planNote(_ blocker: ExportBlockReason) -> some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.hdr.warn)
                .accessibilityHidden(true)
            Text(verbatim: blocker.phrase.text(locale: locale))
                .foregroundStyle(Color.hdr.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let edge = blocker.suggestedLongEdge {
                Button { model.setExportLongEdge(edge) } label: {
                    Text(verbatim: ExportReasonPhrase.useLongEdge(edge).text(locale: locale))
                }
                .buttonStyle(.hdrCompact(.link))
            }
        }
        .font(Font.hdr.caption)
    }

    private var asksForPlace: Bool { model.preferences.value.saveMode == .ask }

    @ViewBuilder private var footerNote: some View {
        if let key = model.export.blockerKey {
            HStack(spacing: Space.s2) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.hdr.warn)
                    .accessibilityHidden(true)
                Text(verbatim: ExportPresentation.blockerText(
                    key, formatName: AppStrings.string("enc.\(model.export.encodingID).label", locale: locale),
                    locale: locale))
                    .foregroundStyle(Color.hdr.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if ExportPresentation.isFolderBlocker(key) {
                    Button("export.footer.openSettings") { openSettings() }
                        .buttonStyle(.hdrCompact(.link))
                }
            }
            .font(Font.hdr.caption)
            .accessibilityElement(children: .combine)
        } else if asksForPlace {
            Text("export.footer.panelFirst").font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
        } else {
            Text("export.footer.folder \(model.preferences.exportFolder.label)")
                .font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
        }
    }
}

// MARK: - Summary

/// The left column: the photo and what the export will make of it.
private struct ExportSummaryColumn: View {
    let model: EditorModel
    let changeFrame: () -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Thumbnail(model.exportSummaryThumbnail.content(showsSpinner: true), width: 172, height: 115)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.document?.name ?? "")
                    .font(.system(size: TypeScale.Size.control, weight: .semibold))
                    .foregroundStyle(Color.hdr.inkStrong)
                    .lineLimit(1).truncationMode(.middle)
                if let size = model.document?.pixelSize {
                    Text(verbatim: "\(size.width) × \(size.height)")
                        .font(Font.hdr.readout).foregroundStyle(Color.hdr.inkMuted)
                }
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                FactRow(label: Text("export.summary.processing"), value: processing)
                FactRow(label: Text("export.color"), value: Text(LocalizedStringKey(model.export.gamut.labelKey)))
                FactRow(label: Text("export.summary.lut"), value: lut, tone: model.lut.spaceIssueKey != nil && model.lut.selection != nil ? .warn : .normal)
                frameRow
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s4)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.hdr.surfaceSunken.opacity(0.5))
        // The picture is kept up to date only while this column is on screen.
        .task { await model.trackExportSummaryThumbnail() }
    }

    /// The frame the export carries, and the way to the frame panel. The
    /// button sits under the value so a long style name or the warning has the
    /// whole column.
    private var frameRow: some View {
        let summary = model.exportFrameSummary
        return VStack(alignment: .leading, spacing: 2) {
            switch summary {
            case .none: FactRow(label: Text("export.summary.frame"), value: Text("export.summary.none"))
            case .style(let style): FactRow(label: Text("export.summary.frame"), value: Text(style.title))
            case .misfit: FactRow(label: Text("export.summary.frame"), value: Text("export.summary.frameMisfit"), tone: .warn)
            }
            Button("export.summary.frameChange", action: changeFrame)
                .buttonStyle(.hdrCompact(.link))
                .accessibilityLabel(Text("export.summary.frameChange.a11y"))
                .padding(.leading, FactRow.labelWidth + Space.s2)
        }
    }

    private var processing: Text {
        if model.workflow == .colorOnly { return Text("export.summary.colorOnly") }
        let source = model.editor.recipe.hdrSource
        if source.usesModel, let option = Adjustments.declaration(Recipe.hdrSourceID)?.options.first(where: { $0.id == source.rawValue }) {
            return Text("export.summary.hdrAI \(AdjustmentText.option(option))")
        }
        return Text("export.summary.hdrManual")
    }

    private var lut: Text {
        guard let selection = model.lut.selection else { return Text("export.summary.none") }
        if model.lut.spaceIssueKey != nil || !model.lut.isEnabled {
            return Text("export.summary.lutInactive \(selection.name)")
        }
        return Text(verbatim: selection.name)
    }
}

// MARK: - Progress

private struct ExportProgressView: View {
    let model: EditorModel
    let close: () -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.s4) {
                header
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let estimate = model.export.estimate(at: model.now())
                    let parts = ExportPresentation.statusParts(phase: model.export.phase, stage: model.export.stageMessage, estimate: estimate)
                    VStack(alignment: .leading, spacing: Space.s3) {
                        summary(estimate)
                        ExportProgressBar(progress: ExportPresentation.progressStyle(isStopping: model.export.isStopping,
                                                                                    estimate: estimate), height: 8)
                        Text(verbatim: ExportPresentation.statusLine(
                            parts, elapsed: model.export.startedAt.map { model.now().timeIntervalSince($0) } ?? 0,
                            locale: locale))
                            .font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                    }
                }
                if let line = model.export.lastLine, !line.isEmpty {
                    Text(verbatim: line)
                        .font(.hdr.mono(11))
                        .foregroundStyle(Color.hdr.ink)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, Space.s2).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.hdr.surfaceSunken, in: .rect(cornerRadius: Radius.sm))
                }
                InspectorNotice(Text("export.progress.lockedNote"), style: .info)
            }
            .padding(Space.s5)
            Divider()
            HStack {
                Button(model.export.isStopping ? "export.progress.stopping" : "export.progress.stop") {
                    model.cancelExport()
                }
                .buttonStyle(.hdrCompact(.stop))
                .disabled(model.export.isStopping)
                .keyboardShortcut(".", modifiers: .command)
                Spacer()
                Button("export.progress.background", action: close)
                    .buttonStyle(.hdrPrimary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Space.s5)
            .padding(.vertical, Space.s3)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.export.isStopping ? "export.progress.stoppingTitle" : "export.progress.title")
                .font(Font.hdr.title).foregroundStyle(Color.hdr.inkStrong)
            Text("export.progress.destination \(ExportPresentation.fileName(for: model)) \(ExportPresentation.folderName(for: model))")
                .font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func summary(_ estimate: ExportEstimate?) -> some View {
        HStack(alignment: .center, spacing: Space.s3) {
            Thumbnail(model.export.thumbnail.content(), width: 72, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ExportPresentation.fileName(for: model))
                    .font(.system(size: TypeScale.Size.control, weight: .semibold))
                    .foregroundStyle(Color.hdr.inkStrong).lineLimit(1).truncationMode(.middle)
                Text(verbatim: meta).font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted).lineLimit(1)
            }
            Spacer(minLength: Space.s3)
            if let percent = ExportPresentation.percent(estimate: estimate, isDone: false) {
                Text(verbatim: ExportPresentation.percentText(percent, locale: locale))
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.hdr.inkStrong)
            }
        }
    }

    /// "HDR JPEG · 6000 × 4000 · Quality 90".
    private var meta: String {
        var pieces = [AppStrings.string("enc.\(model.export.encodingID).label", locale: locale)]
        if let size = model.document?.pixelSize {
            let written = ExportPixelSize(width: size.width, height: size.height).fitted(longEdge: model.export.longEdge)
            pieces.append("\(written.width) × \(written.height)")
        }
        if let quality = model.exportQuality {
            pieces.append(AppStrings.string("export.quality", locale: locale) + " " + Int(quality.rounded()).formatted(.number.locale(locale)))
        }
        return pieces.joined(separator: " · ")
    }
}

// MARK: - Result

/// "Export  DSC04127.JPG": the panel's title with the photo it is about,
/// above the result and the failure.
private struct ExportTitleBar: View {
    let model: EditorModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Text("export.title").font(Font.hdr.title).foregroundStyle(Color.hdr.inkStrong)
                Text(verbatim: model.document?.name ?? "")
                    .font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s5)
            .padding(.vertical, Space.s4)
            Divider()
        }
    }
}

private struct ExportResultView: View {
    let model: EditorModel
    let close: () -> Void
    let begin: () -> Void
    let again: () -> Void

    @Environment(\.locale) private var locale
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let stale = model.export.isResultStale
        VStack(spacing: 0) {
            ExportTitleBar(model: model)
            VStack(alignment: .leading, spacing: Space.s4) {
                if let result = model.export.result {
                    ExportResultCard(thumbnail: model.export.thumbnail.content(), fileName: result.fileName, facts: facts(result),
                                     warnings: DecodeDegradation.text(result.warnings).map { [Text($0)] } ?? [], isStale: stale,
                                     saveRow: saveRow(result),
                                     dragSource: ExportTransfer.dragSource(model: model, version: result.export,
                                                                           thumbnail: model.export.thumbnail,
                                                                           name: result.saved?.fileName ?? result.fileName),
                                     shareAccessory: AnyView(ExportShareButton(model: model, version: result.export,
                                                                               thumbnail: model.export.thumbnail,
                                                                               name: result.saved?.fileName ?? result.fileName)))
                    ExportTransferNotice(model: model)
                }
            }
            .padding(Space.s5)
            Divider()
            HStack {
                Spacer()
                if stale {
                    Button("export.action.close", action: close).buttonStyle(.hdrSecondary).keyboardShortcut(.cancelAction)
                    Button("export.action.exportNew", action: begin).buttonStyle(.hdrPrimary).keyboardShortcut(.defaultAction)
                } else {
                    Button("export.action.again", action: again).buttonStyle(.hdrSecondary)
                    Button("export.action.done", action: close).buttonStyle(.hdrPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, Space.s5)
            .padding(.vertical, Space.s3)
        }
    }

    private func facts(_ result: ExportResult) -> [ExportFact] {
        let facts = ExportPresentation.resultFacts(result, locale: locale)
        var rows = [ExportFact(label: Text("export.result.size"), value: Text(verbatim: facts.size))]
        if let peak = facts.peak {
            rows.append(ExportFact(label: Text("export.result.peak"),
                                   value: Text("export.result.peakValue \(peak.ratio) \(peak.stops)")))
        }
        if facts.isVerified {
            rows.append(ExportFact(label: Text("export.result.check"), value: Text("export.result.verified"), tone: .success))
        }
        rows.append(ExportFact(label: Text("export.result.time"), value: Text(verbatim: facts.time), monospaced: true))
        return rows
    }

    private func saveRow(_ result: ExportResult) -> ExportSaveRow {
        let version = result.export
        if let failure = model.export.saveFailure {
            // The sentence and the button come from one decision: only the fixed
            // folder is fixed in Settings (see `ExportPresentation.saveFailure`).
            let wording = ExportPresentation.saveFailure(failure, mode: model.preferences.value.saveMode, locale: locale)
            return .failed(Text(verbatim: wording.sentence), saveAs: {
                ExportFlow.saveAs(model: model, version: version, choosePlace: ExportSavePanel.chooser(on: NSApp.keyWindow))
            }, openSettings: wording.offersSettings ? { openSettings() } : nil)
        }
        if model.exportSaveStates[version] == .saving || model.export.phase == .saving { return .saving }
        let place = ExportPresentation.savedFolder(result.saved, locale: locale)
        return .saved(Text("export.save.savedTo \(place)"), showInFinder: {
            ExportFlow.showInFinder(model: model, version: version)
        }, canShowInFinder: ExportFlow.canShowInFinder(model: model, version: version))
    }
}

// MARK: - Failure

private struct ExportFailureView: View {
    let model: EditorModel
    let close: () -> Void
    let again: () -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            ExportTitleBar(model: model)
            VStack(alignment: .leading, spacing: Space.s4) {
                if let failure = model.export.failure {
                    let text = ErrorText(failure)
                    ExportFailureCard(title: Text(text.title), message: Text(text.message), detail: text.detail)
                }
                // Out of memory: the largest long edge that fits, then the settings.
                if let edge = model.export.failure?.suggestedLongEdge {
                    Button {
                        model.setExportLongEdge(edge)
                        again()
                    } label: {
                        Text(verbatim: ExportReasonPhrase.useLongEdge(edge).text(locale: locale))
                    }
                    .buttonStyle(.hdrCompact(.link))
                }
            }
            .padding(Space.s5)
            Divider()
            HStack {
                Spacer()
                Button("export.action.again", action: again).buttonStyle(.hdrSecondary)
                Button("export.action.close", action: close).buttonStyle(.hdrPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Space.s5)
            .padding(.vertical, Space.s3)
        }
    }
}

/// The export's quality (the old export's request, until P7-3b): not an
/// edit, so no undo step.
private struct ExportQualitySlider: View {
    let model: EditorModel
    private static let defaultQuality = Double(CustomExportFormat().quality)

    var body: some View {
        ParameterSlider("ctrl.quality.label",
                        value: Binding(get: { model.exportQuality ?? Self.defaultQuality },
                                       set: { model.setExportQuality($0) }),
                        spec: ParameterSpec(range: 0...100, step: 1, defaultValue: Self.defaultQuality,
                                            format: .number(fractionDigits: 0)),
                        help: "ctrl.quality.help",
                        onReset: { model.setExportQuality(Self.defaultQuality) })
    }
}
