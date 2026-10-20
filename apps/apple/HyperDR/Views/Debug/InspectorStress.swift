#if DEBUG
import AppKit
import SwiftUI
import HyperDRDesign
import HyperDRRecipe

// S12 inspector performance spike (batch 3 F4). Debug builds only: Developer ▸
// Inspector Stress, or `-HDRInspectorStress run` to run every binding, print
// the report and quit. Findings: docs/spikes/S12-inspector-performance.md.
//
// Forty sliders in six groups, bound four ways:
//   A  every value in one dictionary on one @Observable store;
//   B  one @Observable value object per control;
//   C  the control's own @State, sent to the model from .onChange (the model
//      value is not observed by the view);
//   D  an AppKit row (NSSlider + labels) inside NSViewRepresentable.
// Every value change writes the editor's recipe, as the inspector does.
//
// Drags are synthesized mouse events posted to this app's own event queue for
// the stress window (never system-wide), from a background thread at 120 Hz,
// so they go through each control's real tracking path and queue up when the
// main thread falls behind, as a real drag does.

// MARK: - Parameters

struct StressParameter: Identifiable, Sendable {
    let id: String
    let title: String
    let range: ClosedRange<Double>
    let initial: Double
}

struct StressGroup: Identifiable, Sendable {
    let id: String
    let parameters: [StressParameter]
}

enum StressBinding: String, CaseIterable, Identifiable, Sendable {
    case dictionary = "A", perControl = "B", localState = "C", appKit = "D"
    var id: String { rawValue }
    var summary: String {
        switch self {
        case .dictionary: "A · one @Observable dictionary"
        case .perControl: "B · @Observable value per control"
        case .localState: "C · local @State + unobserved send"
        case .appKit: "D · NSSlider in NSViewRepresentable"
        }
    }
}

enum StressCatalog {
    /// 40 parameters in the inspector's six groups (sizes as in the web panel).
    static let groups: [StressGroup] = {
        let sizes = [("Light", 8), ("Highlights", 8), ("Color", 8), ("Detail", 6), ("Region", 5), ("Look", 5)]
        var index = 0
        return sizes.map { name, count in
            StressGroup(id: name, parameters: (0..<count).map { _ in
                defer { index += 1 }
                let signed = index % 3 == 0
                return StressParameter(id: String(format: "p%02d", index), title: "Parameter \(index + 1)",
                                       range: signed ? -2...2 : 0...1, initial: signed ? 0 : 0.5)
            })
        }
    }()
    static let parameters = groups.flatMap(\.parameters)
}

// MARK: - Probe

/// Counters and the send path, deliberately not observable.
@MainActor final class StressProbe {
    let model: EditorModel
    var rowBodies = 0
    var headerBodies = 0
    var adjustCalls = 0
    var lastSend: (key: String, value: Double, time: TimeInterval)?
    /// Slider rectangles in window coordinates, by parameter.
    var sliderRects: [String: () -> CGRect?] = [:]

    init(model: EditorModel) { self.model = model }

    /// `-HDRInspectorStressSink none` leaves the model out, to separate the
    /// views' cost from `adjust`'s.
    static let sendsToModel = UserDefaults.standard.string(forKey: "HDRInspectorStressSink") != "none"

    func send(_ key: String, _ value: Double) {
        adjustCalls += 1
        lastSend = (key, value, ProcessInfo.processInfo.systemUptime)
        // Every parameter stands in for one recipe value, so the editor and
        // its render pacing see the drag as the inspector's would.
        if Self.sendsToModel {
            var recipe = model.editor.recipe
            recipe.setValue(.number(value), for: "tone.exposure")
            model.editor.setRecipe(recipe)
        }
    }

    func reset() {
        rowBodies = 0; headerBodies = 0; adjustCalls = 0; lastSend = nil
    }
}

/// Converts a SwiftUI `.global` rectangle to window coordinates (bottom-left
/// origin). Measured on macOS 26: `.global` starts at the top of the window
/// frame, title bar included, not at the top of the content view.
@MainActor private func windowRect(_ global: CGRect, in window: NSWindow?) -> CGRect? {
    guard let window else { return nil }
    return CGRect(x: global.minX, y: window.frame.height - global.maxY, width: global.width, height: global.height)
}

// MARK: - A: one observable dictionary

@MainActor @Observable final class StressDictionaryStore {
    var values: [String: Double]
    init() { values = Dictionary(uniqueKeysWithValues: StressCatalog.parameters.map { ($0.id, $0.initial) }) }
}

private struct DictionaryRow: View {
    let parameter: StressParameter
    let store: StressDictionaryStore
    let probe: StressProbe

    var body: some View {
        let _ = probe.rowBodies += 1
        StressRowLayout(parameter: parameter, probe: probe,
                        value: Binding(get: { store.values[parameter.id] ?? parameter.initial },
                                       set: { store.values[parameter.id] = $0; probe.send(parameter.id, $0) }))
    }
}

// MARK: - B: one observable per control

@MainActor @Observable final class StressValue {
    var value: Double
    init(_ value: Double) { self.value = value }
}

private struct ValueObjectRow: View {
    let parameter: StressParameter
    let value: StressValue
    let probe: StressProbe

    var body: some View {
        let _ = probe.rowBodies += 1
        StressRowLayout(parameter: parameter, probe: probe,
                        value: Binding(get: { value.value }, set: { value.value = $0; probe.send(parameter.id, $0) }))
    }
}

// MARK: - C: local state, unobserved send

private struct LocalStateRow: View {
    let parameter: StressParameter
    let probe: StressProbe
    @State private var value: Double

    init(parameter: StressParameter, probe: StressProbe) {
        self.parameter = parameter
        self.probe = probe
        _value = State(initialValue: parameter.initial)
    }

    var body: some View {
        let _ = probe.rowBodies += 1
        StressRowLayout(parameter: parameter, probe: probe, value: $value)
            .onChange(of: value) { _, new in probe.send(parameter.id, new) }
    }
}

/// The inspector's slider row (ParameterSlider): title, readout, slider.
private struct StressRowLayout: View {
    let parameter: StressParameter
    let probe: StressProbe
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack {
                Text(verbatim: parameter.title).font(Font.hdr.control).foregroundStyle(Color.hdr.ink)
                Spacer()
                Text(verbatim: value.formatted(.number.precision(.fractionLength(2))))
                    .font(Font.hdr.readout).foregroundStyle(Color.hdr.inkMuted)
            }
            Slider(value: $value, in: parameter.range)
                .labelsHidden()
                .controlSize(.small)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                    probe.sliderRects[parameter.id] = { windowRect(rect, in: StressWindow.shared.window) }
                }
        }
    }
}

// MARK: - D: AppKit row

private struct AppKitRow: NSViewRepresentable {
    let parameter: StressParameter
    let probe: StressProbe

    func makeNSView(context: Context) -> StressAppKitRow {
        let row = StressAppKitRow(parameter: parameter, probe: probe)
        probe.sliderRects[parameter.id] = { [weak row] in
            guard let slider = row?.slider, slider.window != nil else { return nil }
            return slider.convert(slider.bounds, to: nil)
        }
        return row
    }

    func updateNSView(_ view: StressAppKitRow, context: Context) {
        probe.rowBodies += 1
    }
}

final class StressAppKitRow: NSView {
    let slider: NSSlider
    private let readout: NSTextField
    private let parameter: StressParameter
    private let probe: StressProbe

    init(parameter: StressParameter, probe: StressProbe) {
        self.parameter = parameter
        self.probe = probe
        slider = NSSlider(value: parameter.initial, minValue: parameter.range.lowerBound,
                          maxValue: parameter.range.upperBound, target: nil, action: nil)
        readout = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: parameter.title)
        title.font = .systemFont(ofSize: 12)
        readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .right
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        for view in [title, readout, slider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.topAnchor.constraint(equalTo: topAnchor),
            readout.trailingAnchor.constraint(equalTo: trailingAnchor),
            readout.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        show(parameter.initial)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 40) }

    @objc private func changed() {
        show(slider.doubleValue)
        probe.send(parameter.id, slider.doubleValue)
    }

    private func show(_ value: Double) {
        readout.stringValue = value.formatted(.number.precision(.fractionLength(2)))
    }
}

// MARK: - Inspector

/// The 40-slider inspector for one binding. Plain ScrollView + VStack, as the
/// real inspector, so every row is built even when scrolled out of view.
private struct StressInspector: View {
    let binding: StressBinding
    let probe: StressProbe
    @State private var dictionary = StressDictionaryStore()
    @State private var values = Dictionary(uniqueKeysWithValues:
        StressCatalog.parameters.map { ($0.id, StressValue($0.initial)) })

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                StressHeader(model: probe.model, probe: probe)
                ForEach(StressCatalog.groups) { group in
                    Divider()
                    VStack(alignment: .leading, spacing: Space.s4) {
                        Text(verbatim: group.id).font(Font.hdr.heading).foregroundStyle(Color.hdr.inkStrong)
                        ForEach(group.parameters) { row($0) }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color.hdr.surfacePanel)
    }

    @ViewBuilder private func row(_ parameter: StressParameter) -> some View {
        switch binding {
        case .dictionary: DictionaryRow(parameter: parameter, store: dictionary, probe: probe)
        case .perControl: ValueObjectRow(parameter: parameter, value: values[parameter.id]!, probe: probe)
        case .localState: LocalStateRow(parameter: parameter, probe: probe)
        case .appKit: AppKitRow(parameter: parameter, probe: probe).frame(height: 40)
        }
    }
}

/// Something that observes the model, as the status bar and canvas overlays
/// do: every `adjust` toggles `isRefreshing`.
private struct StressHeader: View {
    let model: EditorModel
    let probe: StressProbe

    var body: some View {
        let _ = probe.headerBodies += 1
        HStack {
            Text(verbatim: "Inspector stress").font(Font.hdr.heading)
            Spacer()
            Text(verbatim: model.document?.isRefreshing == true ? "refreshing" : "idle")
                .font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
        }
        .padding(20)
    }
}

// MARK: - Window and controls

@MainActor @Observable final class StressState {
    var binding: StressBinding = .dictionary
    var report = ""
    var isRunning = false
}

private struct StressRoot: View {
    let state: StressState
    let probe: StressProbe

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(selection: Bindable(state).binding) {
                    ForEach(StressBinding.allCases) { Text(verbatim: $0.summary).tag($0) }
                } label: { EmptyView() }
                .labelsHidden()
                Button { Task { await StressRunner.run(state: state, probe: probe) } } label: { Text(verbatim: "Run all") }
                    .disabled(state.isRunning)
            }
            .padding(Space.s3)
            Divider()
            StressInspector(binding: state.binding, probe: probe)
                .id(state.binding)
            if !state.report.isEmpty {
                Divider()
                ScrollView {
                    Text(verbatim: state.report).font(Font.hdr.mono(11)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Space.s3)
                }
                .frame(height: 180)
            }
        }
        .frame(width: 380, height: 860)
    }
}

/// The stress window, opened from the Developer menu. Built directly with
/// AppKit so the spike needs no scene in HyperDRApp.
@MainActor final class StressWindow {
    static let shared = StressWindow()
    private(set) var window: NSWindow?
    let state = StressState()
    private(set) lazy var probe = StressProbe(model: EditorModel.preview(.editingHDRDisplay))

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: StressRoot(state: state, probe: probe)))
            window.title = "Inspector Stress (S12)"
            window.styleMask.remove(.resizable)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// `-HDRInspectorStress run`: run every binding, print the report, quit.
    static func runIfRequested() {
        guard UserDefaults.standard.string(forKey: "HDRInspectorStress") == "run" else { return }
        let stress = StressWindow.shared
        stress.show()
        Task {
            try? await Task.sleep(for: .seconds(1))
            await StressRunner.run(state: stress.state, probe: stress.probe)
            print(stress.state.report)
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Measurement

struct StressResult: Codable {
    var binding: String
    var drags = 0
    var eventsPosted = 0
    /// Wall time the posting thread took for all drags; longer than the
    /// nominal drag time when posting is held back by the main thread.
    var postingSeconds = 0.0
    var adjustCalls = 0
    var rowBodies = 0
    var headerBodies = 0
    var seconds = 0.0
    var mainBusySeconds = 0.0
    var frames = 0
    var hitches = 0
    var hitchSeconds = 0.0
    var maxFrameInterval = 0.0
    var frameBudget = 0.0
    var settleLags: [Double] = []

    var eventRate: Double { postingSeconds == 0 ? 0 : Double(eventsPosted) / postingSeconds }
    var deliveredRatio: Double { eventsPosted == 0 ? 0 : Double(adjustCalls) / Double(eventsPosted) }
    var busyPerAdjustMs: Double { adjustCalls == 0 ? 0 : mainBusySeconds / Double(adjustCalls) * 1000 }
    var busyFraction: Double { seconds == 0 ? 0 : mainBusySeconds / seconds }
    var hitchRatio: Double { seconds == 0 ? 0 : hitchSeconds * 1000 / seconds }   // ms per s
    var rowBodiesPerAdjust: Double { adjustCalls == 0 ? 0 : Double(rowBodies) / Double(adjustCalls) }
    var maxSettleLagMs: Double { (settleLags.max() ?? 0) * 1000 }
}

/// Display-link frame pacing and main-thread busy time while recording.
@MainActor final class StressMeter: NSObject {
    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var lastTick: CFTimeInterval?
    private var awake: CFAbsoluteTime?
    private(set) var recording = false
    var result = StressResult(binding: "")

    func attach(to view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.runLoop(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func detach() {
        link?.invalidate(); link = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    func start() { lastTick = nil; awake = CFAbsoluteTimeGetCurrent(); recording = true }
    func stop() { recording = false }

    private func runLoop(_ activity: CFRunLoopActivity) {
        guard recording else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if activity == .afterWaiting {
            awake = now
        } else if let awake {
            result.mainBusySeconds += now - awake
            self.awake = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard recording else { return }
        let budget = link.targetTimestamp - link.timestamp
        if budget > 0 { result.frameBudget = budget }
        if let last = lastTick {
            let interval = link.timestamp - last
            result.frames += 1
            result.maxFrameInterval = max(result.maxFrameInterval, interval)
            if budget > 0, interval > budget * 1.5 {
                result.hitches += 1
                result.hitchSeconds += interval - budget
            }
        }
        lastTick = link.timestamp
    }
}

/// Posts this app's own mouse events from a background thread.
nonisolated private struct EventPoster: @unchecked Sendable {
    private typealias PostEvent = @convention(c) (AnyObject, Selector, NSEvent, Bool) -> Void
    private let app: AnyObject
    private let post: PostEvent
    private let selector = NSSelectorFromString("postEvent:atStart:")

    @MainActor init() {
        app = NSApp
        // -[NSApplication postEvent:atStart:] is documented as callable from
        // any thread; Swift only sees it as main-actor isolated.
        post = unsafeBitCast(class_getMethodImplementation(NSApplication.self, selector), to: PostEvent.self)
    }

    /// Drags start → end → halfway back, then releases. Returns when the last
    /// drag event (a new value) was posted.
    func drag(window: Int, from start: CGPoint, to end: CGPoint, steps: Int, interval: TimeInterval) -> TimeInterval {
        func event(_ type: NSEvent.EventType, _ point: CGPoint) {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
            post(app, selector, event, false)
        }
        event(.leftMouseDown, start)
        var last = CGPoint.zero, lastPosted = 0.0
        for step in 1...steps {
            Thread.sleep(forTimeInterval: interval)
            let t = Double(step) / Double(steps)
            // Across and halfway back, as when hunting for a value.
            let u = t < 2.0 / 3 ? t * 1.5 : 1 - (t - 2.0 / 3) * 1.5
            last = CGPoint(x: start.x + (end.x - start.x) * u, y: start.y)
            event(.leftMouseDragged, last)
            lastPosted = ProcessInfo.processInfo.systemUptime
        }
        Thread.sleep(forTimeInterval: interval)
        event(.leftMouseUp, last)
        return lastPosted
    }
}

@MainActor enum StressRunner {
    /// Sliders dragged per binding: the first eight wholly inside the window.
    static func dragged(_ probe: StressProbe, in window: NSWindow) -> [String] {
        let visible = CGRect(origin: .zero, size: window.contentLayoutRect.size)
        return StressCatalog.parameters.map(\.id)
            .filter { key in probe.sliderRects[key]?().map { visible.contains($0) } ?? false }
            .prefix(8).map { $0 }
    }
    static let rate = 120.0
    static let dragSeconds = 1.5

    static func run(state: StressState, probe: StressProbe) async {
        guard let window = StressWindow.shared.window, let content = window.contentView else { return }
        state.isRunning = true
        defer { state.isRunning = false }
        var results: [StressResult] = []
        let poster = EventPoster()
        // `-HDRInspectorStressOnly B` runs one binding (one Instruments trace each).
        let only = UserDefaults.standard.string(forKey: "HDRInspectorStressOnly")
        for binding in StressBinding.allCases where only == nil || only == binding.rawValue {
            log("binding \(binding.rawValue)")
            state.binding = binding
            try? await Task.sleep(for: .milliseconds(800))
            probe.reset()
            let meter = StressMeter()
            meter.result.binding = binding.rawValue
            meter.attach(to: content)
            let begin = ProcessInfo.processInfo.systemUptime
            meter.start()
            for key in dragged(probe, in: window) {
                guard let rect = probe.sliderRects[key]?() else { log("no rect for \(key)"); continue }
                log("drag \(key) at \(rect)")
                let start = CGPoint(x: rect.minX + rect.width * 0.08, y: rect.midY)
                let end = CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.midY)
                let steps = Int(rate * dragSeconds)
                let number = window.windowNumber, interval = 1 / rate
                let postStart = ProcessInfo.processInfo.systemUptime
                let posted = await withCheckedContinuation { (done: CheckedContinuation<TimeInterval, Never>) in
                    Thread.detachNewThread {
                        done.resume(returning: poster.drag(window: number, from: start, to: end, steps: steps, interval: interval))
                    }
                }
                meter.result.postingSeconds += posted - postStart
                meter.result.eventsPosted += steps
                meter.result.drags += 1
                // How long the last drag event took to reach the model.
                while probe.lastSend.map({ $0.time < posted }) ?? true,
                      ProcessInfo.processInfo.systemUptime - posted < 2 {
                    try? await Task.sleep(for: .milliseconds(2))
                }
                if let last = probe.lastSend { meter.result.settleLags.append(max(0, last.time - posted)) }
                try? await Task.sleep(for: .milliseconds(150))
            }
            meter.stop()
            meter.detach()
            meter.result.seconds = ProcessInfo.processInfo.systemUptime - begin
            meter.result.adjustCalls = probe.adjustCalls
            meter.result.rowBodies = probe.rowBodies
            meter.result.headerBodies = probe.headerBodies
            results.append(meter.result)
            state.report = table(results)
        }
        state.binding = .dictionary
        state.report = table(results) + "\n" + json(results)
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[S12] \(message)\n".utf8))
    }

    static func table(_ results: [StressResult]) -> String {
        var lines = ["binding  posted  rate(Hz)  adjusts  delivered  rowBodies/adj  busy/adj(ms)  busy%  frames  hitches  hitch(ms/s)  maxFrame(ms)  maxSettle(ms)"]
        for r in results {
            lines.append(String(format: "%-7@  %6d  %8.0f  %7d  %8.0f%%  %13.1f  %12.2f  %4.0f%%  %6d  %7d  %11.1f  %12.1f  %13.1f",
                                r.binding, r.eventsPosted, r.eventRate, r.adjustCalls, r.deliveredRatio * 100, r.rowBodiesPerAdjust,
                                r.busyPerAdjustMs, r.busyFraction * 100, r.frames, r.hitches, r.hitchRatio,
                                r.maxFrameInterval * 1000, r.maxSettleLagMs))
        }
        if let budget = results.first?.frameBudget, budget > 0 {
            lines.append(String(format: "frame budget %.2f ms (%.0f Hz); events %0.f Hz nominal; adjust %@", budget * 1000, 1 / budget, rate,
                                StressProbe.sendsToModel ? "on" : "off"))
        }
        return lines.joined(separator: "\n")
    }

    static func json(_ results: [StressResult]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(results)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
#endif
