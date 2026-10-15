import AVFoundation
import SwiftUI
import AppKit
import Combine

final class DictationStore: ObservableObject {
    static let shared = DictationStore()
    @Published private(set) var items: [Dictation] = []
    private let debouncer = Debouncer()

    private init() { items = Storage.load("dictations.json") ?? [] }

    func add(_ d: Dictation) {
        items.insert(d, at: 0)
        if items.count > 1000 { items = Array(items.prefix(1000)) }
        persist()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let snapshot = items
        debouncer.call { Storage.save(snapshot, as: "dictations.json") }
    }
}

/// Diktat per Hotkey: Tippen = Start/Stopp, Halten = Push-to-Talk.
@MainActor
final class DictationEngine: ObservableObject {
    static let shared = DictationEngine()

    enum State: Equatable { case idle, listening, finishing, done(String), error(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var liveText = ""
    @Published private(set) var committedText = ""
    @Published private(set) var partialText = ""
    @Published private(set) var level: Float = 0

    private var engine: AVAudioEngine?
    private var session: SpeechBackend?
    private var committed: [String] = []
    private var startedAt = Date()
    private var pressStarted: Date?
    private var starting = false
    private lazy var overlay = DictationOverlay()

    private init() {}

    var isListening: Bool { state == .listening }

    // Hotkey-Semantik: kurz tippen schaltet um, lange halten = Push-to-Talk.
    func hotkeyPressed() {
        pressStarted = Date()
        if state == .listening {
            stop()
            pressStarted = nil
        } else if state == .idle || isTerminal {
            start()
        }
    }

    func hotkeyReleased() {
        guard let p = pressStarted else { return }
        pressStarted = nil
        if Date().timeIntervalSince(p) > 0.45, state == .listening {
            stop()
        }
    }

    /// Während des Haltens wurde eine andere Taste gedrückt (z. B. ⌘C) – kein Diktat gemeint.
    func hotkeyCancelled() {
        pressStarted = nil
        if state == .listening, Date().timeIntervalSince(startedAt) < 2 {
            cancel()
        }
    }

    private var isTerminal: Bool {
        if case .done = state { return true }
        if case .error = state { return true }
        return false
    }

    func toggle() {
        state == .listening ? stop() : start()
    }

    func start() {
        guard state != .listening, state != .finishing, !starting else { return }
        starting = true
        Task {
            await beginListening()
            starting = false
        }
    }

    private func beginListening() async {
        guard await Permissions.requestMicrophone() else { fail("Kein Mikrofonzugriff."); return }
        guard await Permissions.requestSpeech() else { fail("Keine Freigabe für Spracherkennung."); return }
        committed = []
        liveText = ""
        committedText = ""
        partialText = ""
        state = .listening
        overlay.show()
        guard let session = await SpeechBackendFactory.make(localeIdentifier: Settings.shared.localeIdentifier,
                                                             status: { [weak self] s in self?.liveText = s }) else {
            fail("Spracherkennung für \(Settings.shared.localeIdentifier) nicht verfügbar."); return
        }
        self.session = session
        liveText = ""
        startedAt = Date()

        session.onPartial = { [weak self] p in self?.updateLive(partial: p) }
        session.onCommitted = { [weak self] t in
            self?.committed.append(t)
            self?.updateLive(partial: "")
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { fail("Kein Eingabegerät."); return }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            session.append(buffer)
            self?.measure(buffer)
        }
        do {
            try await session.start()
            engine.prepare()
            try engine.start()
        } catch {
            fail("Audio konnte nicht gestartet werden.")
            return
        }
        self.engine = engine
        state = .listening
        AppDelegate.shared?.refreshStatusIcon()
    }

    func stop() {
        guard state == .listening, let session = session else { return }
        state = .finishing
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        AppDelegate.shared?.refreshStatusIcon()
        Task { [weak self] in
            await session.stop()
            self?.finish()
        }
    }

    func cancel() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if let s = session { Task { await s.stop() } }
        session = nil
        state = .idle
        overlay.hide()
        AppDelegate.shared?.refreshStatusIcon()
    }

    private func finish() {
        session = nil
        let raw = committed.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Date().timeIntervalSince(startedAt)
        guard !raw.isEmpty else {
            state = .idle
            overlay.hide()
            return
        }
        let settings = Settings.shared
        let result = VoiceCommands.apply(raw, snippets: settings.snippets, prefix: settings.commandPrefix)
        DictationStore.shared.add(Dictation(text: result.text, duration: duration, usedSnippet: result.usedSnippet))

        if settings.pasteAfterDictation, Paster.canPaste {
            Paster.paste(text: result.text)
            state = .done("Eingefügt")
        } else if settings.pasteAfterDictation {
            Paster.write(text: result.text)
            state = .done("Kopiert – zum Einfügen fehlt die Bedienungshilfen-Freigabe")
        } else {
            Paster.write(text: result.text)
            state = .done("Kopiert")
        }
        committedText = result.text
        partialText = ""
        overlay.flashDone()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self = self, case .done = self.state else { return }
            self.state = .idle
            self.overlay.hide()
        }
    }

    private func fail(_ message: String) {
        state = .error(message)
        liveText = message
        overlay.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self = self, case .error = self.state else { return }
            self.state = .idle
            self.overlay.hide()
        }
    }

    private func updateLive(partial: String) {
        committedText = committed.joined(separator: " ")
        partialText = partial
        let all = (committed + [partial]).filter { !$0.isEmpty }
        liveText = all.joined(separator: " ")
    }

    private nonisolated func measure(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        let value = min(1, rms * 8)
        Task { @MainActor in self.level = self.level * 0.6 + value * 0.4 }
    }
}

/// Kleine schwarze Kapsel am unteren Bildschirmrand mit Live-Text.
final class DictationOverlay: NSPanel {
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 180),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = NSHostingView(rootView: DictationOverlayView())
    }

    override var canBecomeKey: Bool { false }

    func show() {
        hideWork?.cancel()
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.minY + 48))
        orderFrontRegardless()
    }

    func flashDone() { show() }

    func hide() { orderOut(nil) }
}

@MainActor struct DictationOverlayView: View {
    @ObservedObject var engine = DictationEngine.shared

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 14) {
                indicator.padding(.top, 3)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.ink))
            .animation(.easeOut(duration: 0.18), value: engine.committedText)
            .animation(.easeOut(duration: 0.12), value: engine.partialText)
        }
        .frame(width: 560, height: 180, alignment: .bottom)
        .padding(.bottom, 0)
    }

    @ViewBuilder private var content: some View {
        switch engine.state {
        case .listening:
            if engine.committedText.isEmpty && engine.partialText.isEmpty {
                Text(engine.liveText.isEmpty ? "Sprich einfach los" : engine.liveText)
                    .font(Theme.font(14)).foregroundColor(Theme.paper.opacity(0.55))
            } else {
                flowing
            }
        case .finishing:
            if engine.committedText.isEmpty && engine.partialText.isEmpty {
                Text("Einen Moment …").font(Theme.font(14)).foregroundColor(Theme.paper.opacity(0.55))
            } else {
                flowing
            }
        case .done(let s):
            VStack(alignment: .leading, spacing: 6) {
                flowing
                Text(s).font(Theme.small).foregroundColor(Theme.paper.opacity(0.55))
            }
        case .error(let s):
            Text(s).font(Theme.font(14)).foregroundColor(Theme.paper)
        case .idle:
            EmptyView()
        }
    }

    /// Bestätigter Text in Weiß, der gerade entstehende Teil leicht abgesetzt – wie ein Fließtext, der wächst.
    private var flowing: some View {
        var text = AttributedString(engine.committedText)
        text.foregroundColor = Theme.paper
        if !engine.partialText.isEmpty {
            var p = AttributedString((engine.committedText.isEmpty ? "" : " ") + engine.partialText)
            p.foregroundColor = Theme.paper.opacity(0.6)
            text.append(p)
        }
        return Text(text)
            .font(Theme.font(15))
            .lineSpacing(3)
            .lineLimit(5)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var indicator: some View {
        switch engine.state {
        case .listening:
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(Theme.paper)
                        .frame(width: 3, height: 4 + CGFloat(engine.level) * CGFloat(12 + i * 3))
                }
            }
            .frame(width: 24, height: 18)
            .animation(.linear(duration: 0.08), value: engine.level)
        case .finishing:
            Circle().strokeBorder(Theme.paper.opacity(0.5), lineWidth: 1).frame(width: 10, height: 10).frame(width: 24, height: 18)
        default:
            Circle().fill(Theme.paper).frame(width: 8, height: 8).frame(width: 24, height: 18)
        }
    }
}
