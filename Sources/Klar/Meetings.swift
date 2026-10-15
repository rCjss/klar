import AVFoundation
import ScreenCaptureKit
import AppKit
import Combine

final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()
    @Published private(set) var items: [MeetingTranscript] = []
    private let debouncer = Debouncer(delay: 1.0)

    private init() { items = Storage.load("meetings.json") ?? [] }

    func upsert(_ m: MeetingTranscript) {
        if let i = items.firstIndex(where: { $0.id == m.id }) { items[i] = m } else { items.insert(m, at: 0) }
        persist()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func setSummary(_ id: UUID, _ summary: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].summary = summary
        persist()
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
        persist()
    }

    private func persist() {
        let snapshot = items
        debouncer.call { Storage.save(snapshot, as: "meetings.json") }
    }
}

/// Transkribiert Systemton (andere Teilnehmer) und Mikrofon (ich) getrennt
/// und führt beides zeitlich sortiert zusammen.
/// Leitet Systemton-Samples an die Spracherkennung weiter (läuft auf der Audio-Queue).
final class SystemAudioSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let session: SpeechBackend
    let queue = DispatchQueue(label: "klar.meeting.audio")
    var onError: ((Error) -> Void)?
    init(session: SpeechBackend) { self.session = session }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = AudioUtil.pcmBuffer(from: sampleBuffer) else { return }
        session.append(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error) }
}

@MainActor
final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()

    @Published private(set) var isRunning = false
    @Published private(set) var current: MeetingTranscript?
    @Published private(set) var liveMe = ""
    @Published private(set) var liveOthers = ""
    @Published private(set) var errorMessage: String?
    @Published var lastFinishedID: UUID?

    private var stream: SCStream?
    private var sink: SystemAudioSink?
    private var engine: AVAudioEngine?
    private var meSession: SpeechBackend?
    private var othersSession: SpeechBackend?
    private var startedAt = Date()

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
        errorMessage = nil
        Task { await begin() }
    }

    private func begin() async {
        guard await Permissions.requestMicrophone() else { errorMessage = "Kein Mikrofonzugriff."; return }
        guard await Permissions.requestSpeech() else { errorMessage = "Keine Freigabe für Spracherkennung."; return }
        guard Permissions.requestScreen() else {
            errorMessage = "Bildschirmaufnahme-Freigabe fehlt (für Systemton)."; return
        }
        let locale = Settings.shared.localeIdentifier
        guard let me = await SpeechBackendFactory.make(localeIdentifier: locale),
              let others = await SpeechBackendFactory.make(localeIdentifier: locale) else {
            errorMessage = "Spracherkennung nicht verfügbar."; return
        }
        meSession = me
        othersSession = others
        startedAt = Date()
        var transcript = MeetingTranscript(title: "Meeting " + Format.dateTime.string(from: Date()))
        current = transcript
        MeetingStore.shared.upsert(transcript)

        me.onPartial = { [weak self] p in self?.liveMe = p }
        others.onPartial = { [weak self] p in self?.liveOthers = p }
        me.onCommitted = { [weak self] t in self?.append(speaker: "Ich", text: t) }
        others.onCommitted = { [weak self] t in self?.append(speaker: "Andere", text: t) }

        // Systemton über ScreenCaptureKit
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { errorMessage = "Kein Display gefunden."; return }
            let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 1
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false
            let sink = SystemAudioSink(session: others)
            sink.onError = { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = "Systemton-Erfassung beendet: \(error.localizedDescription)"
                    self?.stop()
                }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: sink)
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            try await stream.startCapture()
            self.sink = sink
            self.stream = stream
        } catch {
            errorMessage = "Systemton konnte nicht erfasst werden: \(error.localizedDescription)"
            return
        }

        // Mikrofon
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in me.append(buffer) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            errorMessage = "Mikrofon konnte nicht gestartet werden."
            try? await stream?.stopCapture()
            return
        }
        self.engine = engine
        do {
            try await me.start()
            try await others.start()
        } catch {
            errorMessage = "Spracherkennung konnte nicht gestartet werden: \(error.localizedDescription)"
            engine.stop()
            try? await stream?.stopCapture()
            return
        }
        isRunning = true
        transcript.startedAt = startedAt
        current = transcript
        AppDelegate.shared?.refreshStatusIcon()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let s = stream
        stream = nil
        sink = nil
        Task { try? await s?.stopCapture() }
        let me = meSession, others = othersSession
        Task { [weak self] in
            await me?.stop()
            await others?.stop()
            guard let self = self else { return }
            self.meSession = nil
            self.othersSession = nil
            self.liveMe = ""
            self.liveOthers = ""
            var finished: MeetingTranscript?
            if var t = self.current {
                t.endedAt = Date()
                self.current = t
                MeetingStore.shared.upsert(t)
                finished = t
            }
            self.current = nil
            AppDelegate.shared?.refreshStatusIcon()
            if let f = finished, Settings.shared.autoSummarize, !f.lines.isEmpty {
                self.lastFinishedID = f.id
                Task { await Summarizer.shared.summarize(f.id) }
            }
        }
    }

    private func append(speaker: String, text: String) {
        guard var t = current else { return }
        t.lines.append(TranscriptLine(time: Date().timeIntervalSince(startedAt), speaker: speaker, text: text))
        t.lines.sort { $0.time < $1.time }
        current = t
        MeetingStore.shared.upsert(t)
    }

}
