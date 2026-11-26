import AVFoundation
import Speech
import UIKit

/// Ein Diktat: Mikrofon → Erkennung (Apple oder lokales Modell) → Text.
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    enum Phase: Equatable { case idle, preparing, listening, finishing, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    /// Bestätigter Text des laufenden bzw. letzten Diktats.
    @Published private(set) var text = ""
    /// Vorläufiger Text (Apple) oder „…“, solange ein Abschnitt erkannt wird (lokale Modelle).
    @Published private(set) var partial = ""
    @Published private(set) var status = ""
    @Published private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private var backend: Backend?
    private var engineLabel = ""

    var isActive: Bool { phase == .preparing || phase == .listening || phase == .finishing }

    func toggle() {
        switch phase {
        case .listening: stop()
        case .preparing, .finishing: break
        default: Task { await start() }
        }
    }

    func start() async {
        guard !isActive else { return }
        phase = .preparing
        text = ""
        partial = ""
        status = ""

        guard await Self.requestMicrophone() else {
            fail("Kein Mikrofonzugriff. Bitte in den iPhone-Einstellungen unter Klar erlauben.")
            return
        }
        let settings = AppSettings.shared
        let language = settings.language
        engineLabel = settings.engineLabel

        let backend: Backend
        if let model = settings.localModel {
            guard model.supports(languageCode: language.code) else {
                fail("\(model.label) kennt kein \(language.name). Bitte ein Whisper-Modell wählen.")
                return
            }
            let store = LocalModels.store
            if !store.isDownloaded(model) {
                status = "Sprachmodell wird geladen …"
                let watch = store.$progress.sink { [weak self] p in
                    Task { @MainActor in self?.status = "Sprachmodell wird geladen … \(Int(p * 100)) %" }
                }
                let ok = await store.ensure(model)
                watch.cancel()
                guard ok else { fail(store.error ?? "Sprachmodell konnte nicht geladen werden."); return }
                status = ""
            }
            backend = LocalBackend(modelPath: store.path(of: model), language: language.code)
        } else {
            guard await Self.requestSpeech() else {
                fail("Keine Freigabe für die Spracherkennung. Bitte in den iPhone-Einstellungen unter Klar erlauben.")
                return
            }
            guard let apple = AppleBackend(localeIdentifier: language.id) else {
                fail("Apples Spracherkennung für \(language.name) ist nicht verfügbar.")
                return
            }
            backend = apple
        }
        backend.onCommitted = { [weak self] t in self?.commit(t) }
        backend.onPartial = { [weak self] t in self?.partial = t }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.noInput }
            input.removeTap(onBus: 0)
            let sink = backend
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                sink.append(buffer)
                let level = Self.rms(buffer)
                Task { @MainActor in self?.level = level }
            }
            engine.prepare()
            try engine.start()
            try backend.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            fail("Mikrofon lässt sich nicht starten: \(error.localizedDescription)")
            return
        }
        self.backend = backend
        phase = .listening
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        guard phase == .listening || phase == .preparing, let backend else {
            if phase == .preparing { phase = .idle }
            return
        }
        phase = .finishing
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        level = 0
        UIApplication.shared.isIdleTimerDisabled = false
        backend.finish { [weak self] in
            guard let self else { return }
            self.backend = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.partial = ""
            self.phase = .done
            let final = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !final.isEmpty else { self.status = "Nichts erkannt."; return }
            History.shared.add(final, engine: self.engineLabel)
            if AppSettings.shared.copyAfterDictation {
                UIPasteboard.general.string = final
                self.status = "Kopiert."
            }
        }
    }

    /// Text des letzten Diktats ersetzen (z. B. nach dem Bearbeiten).
    func clear() {
        guard !isActive else { return }
        text = ""
        partial = ""
        status = ""
        phase = .idle
    }

    private func commit(_ t: String) {
        let piece = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        text = text.isEmpty ? piece : text + " " + piece
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        status = ""
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }

    private static func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    private static func requestSpeech() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    enum DictationError: LocalizedError {
        case noInput
        var errorDescription: String? { "Kein Mikrofon gefunden." }
    }
}

// MARK: - Erkennung

/// Gemeinsame Schnittstelle für Apples Erkennung und die lokalen Modelle.
@MainActor
protocol Backend: AnyObject, Sendable {
    var onPartial: (@MainActor (String) -> Void)? { get set }
    var onCommitted: (@MainActor (String) -> Void)? { get set }
    func start() throws
    nonisolated func append(_ buffer: AVAudioPCMBuffer)
    func finish(_ done: @escaping @MainActor () -> Void)
}

/// Apples Spracherkennung, wenn möglich auf dem Gerät. Zeigt den Text schon beim Sprechen.
@MainActor
final class AppleBackend: Backend {
    var onPartial: (@MainActor (String) -> Void)?
    var onCommitted: (@MainActor (String) -> Void)?

    private let recognizer: SFSpeechRecognizer
    nonisolated(unsafe) private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishing: (@MainActor () -> Void)?
    nonisolated private let lock = NSLock()

    init?(localeIdentifier: String) {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), r.isAvailable else { return nil }
        recognizer = r
    }

    func start() throws { begin() }

    /// Apple beendet eine Erkennung nach etwa einer Minute; dann geht es nahtlos mit einer neuen weiter.
    private func begin() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        lock.withLock { self.request = request }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in self?.handle(text: text, isFinal: isFinal, failed: error != nil) }
        }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        if let text, !isFinal { onPartial?(text) }
        guard isFinal || failed else { return }
        if let text, !text.isEmpty { onCommitted?(text) }
        onPartial?("")
        task = nil
        if let done = finishing {
            finishing = nil
            done()
        } else {
            begin()
        }
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request }?.append(buffer)
    }

    func finish(_ done: @escaping @MainActor () -> Void) {
        guard task != nil else { done(); return }
        finishing = done
        lock.withLock { request }?.endAudio()
        // Falls Apple nicht antwortet: nach einigen Sekunden trotzdem abschließen.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, let pending = self.finishing else { return }
            self.finishing = nil
            self.task?.cancel()
            self.task = nil
            pending()
        }
    }
}

/// Lokales Modell (Whisper oder Parakeet). Teilt den Ton an Sprechpausen und erkennt jeden Abschnitt.
@MainActor
final class LocalBackend: Backend {
    var onPartial: (@MainActor (String) -> Void)?
    var onCommitted: (@MainActor (String) -> Void)?

    private let modelPath: String
    private let language: String
    nonisolated private let audio = AudioState()
    private var pending = 0
    private var finishing: (@MainActor () -> Void)?
    private var idleWatch: Task<Void, Never>?

    /// Wird vom Audio-Thread benutzt – immer unter `lock`.
    private final class AudioState: @unchecked Sendable {
        let lock = NSLock()
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechSegmenter.rate),
                                   channels: 1, interleaved: false)!
        let segmenter = SpeechSegmenter()
        var active = false
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        var lastAppend = Date()
        var deliver: (@Sendable ([Float]) -> Void)?
    }

    init(modelPath: String, language: String) {
        self.modelPath = modelPath
        self.language = language
    }

    func start() throws {
        let path = modelPath, language = language
        // Modell schon laden, damit der erste Abschnitt nicht darauf wartet.
        RecognizerHost.shared.warmUp(modelPath: path)
        audio.lock.withLock {
            audio.active = true
            audio.lastAppend = Date()
            audio.deliver = { [weak self] segment in
                Task { @MainActor in self?.recognize(segment, path: path, language: language) }
            }
        }
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.closeIdleSegment()
            }
        }
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        audio.lock.lock()
        defer { audio.lock.unlock() }
        guard audio.active, buffer.frameLength > 0, let mono = convert(buffer), let data = mono.floatChannelData?[0] else { return }
        audio.lastAppend = Date()
        let samples = UnsafeBufferPointer(start: data, count: Int(mono.frameLength))
        for segment in audio.segmenter.append(samples) { audio.deliver?(segment) }
    }

    /// In 16 kHz Mono umwandeln. Nur unter `audio.lock` aufrufen.
    private nonisolated func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = audio.target
        if buffer.format == target { return buffer }
        if audio.converter == nil || audio.inputFormat != buffer.format {
            audio.converter = AVAudioConverter(from: buffer.format, to: target)
            audio.inputFormat = buffer.format
        }
        guard let converter = audio.converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    private func closeIdleSegment() {
        audio.lock.withLock {
            guard audio.active,
                  let segment = audio.segmenter.closeIfIdle(Date().timeIntervalSince(audio.lastAppend)) else { return }
            audio.deliver?(segment)
        }
    }

    private func recognize(_ segment: [Float], path: String, language: String) {
        pending += 1
        onPartial?("…")
        RecognizerHost.shared.transcribe(segment, modelPath: path, language: language) { [weak self] text in
            guard let self else { return }
            self.pending -= 1
            let cleaned = HallucinationFilter.clean(text ?? "")
            if !cleaned.isEmpty { self.onCommitted?(cleaned) }
            if self.pending == 0 { self.onPartial?("") }
            if text == nil { self.onPartial?("Erkennung fehlgeschlagen") }
            if self.pending == 0, let done = self.finishing {
                self.finishing = nil
                done()
            }
        }
    }

    func finish(_ done: @escaping @MainActor () -> Void) {
        idleWatch?.cancel()
        idleWatch = nil
        let last: [Float]? = audio.lock.withLock {
            audio.active = false
            audio.converter = nil
            audio.deliver = nil
            return audio.segmenter.flush()
        }
        if let last { recognize(last, path: modelPath, language: language) }
        if pending == 0 { done() } else { finishing = done }
    }
}

/// Hält das lokale Modell im Speicher und rechnet nacheinander auf einer eigenen Queue.
/// Bei Speicherwarnung oder im Hintergrund wird das Modell freigegeben.
final class RecognizerHost: @unchecked Sendable {
    static let shared = RecognizerHost()

    private let queue = DispatchQueue(label: "klar.recognizer", qos: .userInitiated)
    private let recognizer = LocalRecognizer()

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: nil) { [weak self] _ in self?.unload() }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            // Nach dem Abschluss eines laufenden Diktats freigeben – die Queue arbeitet der Reihe nach.
            self?.unload()
        }
    }

    func warmUp(modelPath: String) {
        queue.async { _ = self.recognizer.load(modelPath) }
    }

    func transcribe(_ samples: [Float], modelPath: String, language: String,
                    completion: @escaping @MainActor (String?) -> Void) {
        queue.async {
            let result = self.recognizer.transcribe(modelPath: modelPath, samples: samples, language: language, hint: "")
            let text: String?
            switch result {
            case .text(let t): text = t
            case .modelNotLoaded, .failed: text = nil
            }
            Task { @MainActor in completion(text) }
        }
    }

    func unload() {
        queue.async { self.recognizer.unload() }
    }
}
