import AVFoundation
import Combine
import Foundation
import Security
import KlarSpeech
import WhisperWire

// Lokale Spracherkennung mit Whisper (whisper.cpp) oder Parakeet (sherpa-onnx) als Alternative zu Apples
// Erkennung. Aufbau wie in der Windows-Fassung: Ton → 16 kHz Mono → Abschnitte an Sprechpausen → Modell.

// MARK: - Auswahl

/// „apple“ = Apples Erkennung, „whisper“ = lokales Modell (Whisper oder Parakeet, siehe `LocalModels`).
/// Der Wert heißt aus Kompatibilität mit älteren Einstellungen weiter „whisper“.
enum SpeechEngine: String, CaseIterable {
    case apple, whisper

    static var current: SpeechEngine { SpeechEngine(rawValue: Settings.shared.speechEngine) ?? .apple }
}

/// Die lokalen Modelle auf dem Mac.
@MainActor
enum LocalModels {
    static let store = ModelStore(directory: Storage.models)

    /// Das in den Einstellungen gewählte Modell.
    static var selected: SpeechModel { SpeechModels.find(Settings.shared.whisperModel) }
}

// MARK: - Erkennung

/// Spricht mit dem Whisper-Hilfsprozess (`KlarWhisper`). Der Helfer hält das Modell im Speicher;
/// Aufrufe laufen nacheinander auf einer eigenen Queue.
///
/// Warum ein eigener Prozess: whisper.cpp liegt als fremdes, fertig gebautes Framework bei. Die App
/// besitzt Mikrofon-, Bildschirm- und Bedienungshilfen-Freigaben und lädt deshalb keine fremden
/// Bibliotheken (Hardened Runtime). Der Helfer bekommt nur Tonabschnitte und liefert Text.
final class WhisperEngine: @unchecked Sendable {
    static let shared = WhisperEngine()

    enum Failure: Error { case helperUnavailable, modelNotLoaded, inference, connectionLost }

    private static let idleShutdown: TimeInterval = 600
    /// Ein Abschnitt ist höchstens 28 Sekunden lang; braucht der Helfer länger als das hier, hängt er.
    private static let requestTimeout: TimeInterval = 120

    // Alles Folgende nur auf `queue`.
    private let queue = DispatchQueue(label: "klar.whisper", qos: .userInitiated)
    private var helper: (pid: pid_t, input: Int32, output: Int32)?
    private var lastUsed = Date()
    private var users = 0

    private init() {}

    /// Eine Sitzung beginnt: Modell schon laden, damit der erste Abschnitt nicht darauf wartet.
    func retain(modelPath: String) {
        queue.async {
            self.users += 1
            _ = try? self.send(Wire.Request(modelPath: modelPath, language: "de", hint: "", samples: []))
        }
    }

    /// Eine Sitzung endet. Bleibt die Erkennung danach ungenutzt, endet der Helfer und gibt den Speicher frei.
    func release() {
        queue.async {
            self.users = max(0, self.users - 1)
            self.scheduleIdleCheck()
        }
    }

    /// Lässt sich der Hilfsprozess starten? Schlägt fehl, wenn er fehlt oder die App verändert wurde.
    func isAvailable() async -> Bool {
        await withCheckedContinuation { cont in
            queue.async {
                let running = (self.helper ?? self.startHelper()) != nil
                if running { self.lastUsed = Date(); self.scheduleIdleCheck() }
                cont.resume(returning: running)
            }
        }
    }

    private func scheduleIdleCheck() {
        queue.asyncAfter(deadline: .now() + Self.idleShutdown + 1) {
            guard self.users == 0, Date().timeIntervalSince(self.lastUsed) >= Self.idleShutdown else { return }
            self.stopHelper()
        }
    }

    /// Lädt das Modell und rechnet einmal über Stille. Der allererste Lauf nach einer Installation dauert
    /// einige Sekunden (macOS übersetzt die Grafik-Programme); das soll nicht ins erste Diktat fallen.
    func warmUp(modelPath: String) {
        queue.async {
            let silence = [Float](repeating: 0, count: SpeechSegmenter.rate)
            _ = try? self.send(Wire.Request(modelPath: modelPath, language: "de", hint: "", samples: silence))
        }
        retain(modelPath: modelPath)
        release()
    }

    /// Wärmt vor, wenn ein lokales Modell gewählt und schon vorhanden ist.
    @MainActor
    static func warmUpIfSelected() {
        guard SpeechEngine.current == .whisper else { return }
        let model = LocalModels.selected
        if LocalModels.store.isDownloaded(model) { shared.warmUp(modelPath: LocalModels.store.path(of: model)) }
    }

    /// - Parameters:
    ///   - samples: 16 kHz Mono.
    ///   - language: Sprachcode, z. B. „de“.
    ///   - hint: Wörter, die wahrscheinlich vorkommen (Befehle, Namen) – verbessert deren Schreibweise.
    func transcribe(_ samples: [Float], modelPath: String, language: String, hint: String?) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let request = Wire.Request(modelPath: modelPath, language: language, hint: hint ?? "", samples: samples)
                    cont.resume(returning: try self.send(request))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Beim Beenden der App: den Helfer geordnet beenden.
    func shutdown() {
        queue.sync { self.stopHelper() }
    }

    // MARK: Hilfsprozess

    private func send(_ request: Wire.Request) throws -> String {
        lastUsed = Date()
        defer { lastUsed = Date() }
        guard let helper = helper ?? startHelper() else { throw Failure.helperUnavailable }

        // Hängt der Helfer, wird er beendet – das Lesen unten schlägt dann fehl.
        let pid = helper.pid
        let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.requestTimeout, execute: watchdog)
        defer { watchdog.cancel() }

        do {
            try Wire.write(request, to: helper.input)
            let response = try Wire.readResponse(from: helper.output)
            switch response.status {
            case .ok: return response.text
            case .modelNotLoaded:
                NSLog("Klar: Sprachmodell konnte nicht geöffnet werden: %@", request.modelPath)
                throw Failure.modelNotLoaded
            case .inferenceFailed: throw Failure.inference
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            // Leitung gestört oder Helfer abgestürzt: aufräumen, der nächste Aufruf startet ihn neu.
            NSLog("Klar: Verbindung zum Whisper-Helfer verloren: %@", String(describing: error))
            stopHelper(force: true)
            throw Failure.connectionLost
        }
    }

    private func startHelper() -> (pid: pid_t, input: Int32, output: Int32)? {
        guard let path = Self.helperPath() else {
            NSLog("Klar: Whisper-Helfer fehlt oder die App wurde verändert – Whisper bleibt aus.")
            return nil
        }
        var toChild: [Int32] = [-1, -1], fromChild: [Int32] = [-1, -1]
        guard pipe(&toChild) == 0 else { return nil }
        guard pipe(&fromChild) == 0 else { close(toChild[0]); close(toChild[1]); return nil }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], STDOUT_FILENO)
        posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Der Helfer erbt außer den drei Standardkanälen keine offenen Dateien.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        // Der Helfer soll für macOS ein eigenständiger Prozess sein und Klars Freigaben (Mikrofon,
        // Bildschirm, Bedienungshilfen) nicht mitbenutzen dürfen.
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
            _ = unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1)
        }

        let environment = ProcessInfo.processInfo.environment
        let kept = ["HOME", "TMPDIR", "USER", "LOGNAME"].compactMap { key in environment[key].map { key + "=" + $0 } }
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        var envp: [UnsafeMutablePointer<CChar>?] = kept.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
        close(toChild[0])
        close(fromChild[1])
        guard result == 0 else {
            close(toChild[1]); close(fromChild[0])
            NSLog("Klar: Whisper-Helfer ließ sich nicht starten (%d).", result)
            return nil
        }
        // Stirbt der Helfer, soll ein Schreibversuch einen Fehler liefern und nicht die App beenden.
        _ = fcntl(toChild[1], F_SETNOSIGPIPE, 1)
        _ = fcntl(toChild[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fromChild[0], F_SETFD, FD_CLOEXEC)
        helper = (pid, toChild[1], fromChild[0])
        return helper
    }

    /// Schließt die Leitung; der Helfer gibt daraufhin das Modell frei und endet von selbst.
    private func stopHelper(force: Bool = false) {
        guard let h = helper else { return }
        helper = nil
        close(h.input)
        close(h.output)
        if force { kill(h.pid, SIGKILL) }
        var status: Int32 = 0
        for _ in 0..<40 where !force {
            if waitpid(h.pid, &status, WNOHANG) != 0 { return }
            usleep(50_000)
        }
        kill(h.pid, SIGKILL)
        waitpid(h.pid, &status, 0)
    }

    /// Pfad des Helfers in der App. Vorher wird geprüft, dass die App seit dem Signieren unverändert ist –
    /// sonst könnte ein ausgetauschter Helfer in Klars Namen laufen.
    private static func helperPath() -> String? {
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let path = bundle.appendingPathComponent("Contents/Helpers/KlarWhisper").path
            return fm.isExecutableFile(atPath: path) && bundleIsIntact() ? path : nil
        }
        #if DEBUG
        // Entwicklung ohne App-Bündel (swift run): der Helfer liegt neben dem Programm.
        if let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("KlarWhisper").path,
           fm.isExecutableFile(atPath: sibling) {
            return sibling
        }
        #endif
        return nil
    }

    /// Prüft die Signatur der laufenden App samt Helfer und Framework gegen die Dateien auf der Platte.
    private static func bundleIsIntact() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(staticCode, flags, nil)
        if status != errSecSuccess { NSLog("Klar: Signaturprüfung der App fehlgeschlagen (%d).", status) }
        return status == errSecSuccess
    }
}

// MARK: - Sitzung

/// Lokales Modell (Whisper oder Parakeet) als `SpeechBackend`: nimmt Ton entgegen, teilt ihn an
/// Sprechpausen und meldet jeden Abschnitt als bestätigten Text. Vorläufigen Text gibt es nicht –
/// beide Modelle arbeiten abschnittsweise.
@MainActor
final class WhisperSession: SpeechBackend {
    var onPartial: (@MainActor (String) -> Void)?
    var onCommitted: (@MainActor (String) -> Void)?

    private let model: SpeechModel
    private let modelPath: String
    private let language: String
    private let hint: String?
    nonisolated private let audio = AudioState()
    private var worker: Task<Void, Never>?
    private var idleWatch: Task<Void, Never>?
    private var started = false

    /// Wird auch vom Audio-Thread benutzt – immer unter `lock`.
    private final class AudioState {
        let lock = NSLock()
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechSegmenter.rate),
                                   channels: 1, interleaved: false)!
        let segmenter = SpeechSegmenter()
        var active = false
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        var continuation: AsyncStream<[Float]>.Continuation?
        var lastAppend = Date()
    }

    /// Grund, warum `make` zuletzt nichts geliefert hat.
    private(set) static var lastError: String?

    /// Lädt bei Bedarf das gewählte Modell und liefert eine startbereite Sitzung.
    static func make(localeIdentifier: String, model: SpeechModel, vocabulary: String?,
                     status: (@MainActor (String) -> Void)?) async -> WhisperSession? {
        let language = SpeechLanguage.find(localeIdentifier)
        guard model.supports(languageCode: language.code) else {
            lastError = "\(model.label) kennt kein \(language.name). Bitte ein Whisper-Modell wählen."
            return nil
        }
        let store = LocalModels.store
        if !store.isDownloaded(model) {
            status?("Sprachmodell wird geladen …")
            let watch = store.$progress.dropFirst().sink { p in
                MainActor.assumeIsolated { status?("Sprachmodell wird geladen … \(Int(p * 100)) %") }
            }
            let ok = await store.ensure(model)
            watch.cancel()
            guard ok else {
                lastError = store.error ?? "Sprachmodell konnte nicht geladen werden."
                return nil
            }
        }
        guard await WhisperEngine.shared.isAvailable() else {
            lastError = "Die lokale Erkennung lässt sich nicht starten. Bitte Klar neu installieren."
            return nil
        }
        lastError = nil
        // Parakeet kennt keinen Hinweis auf erwartete Wörter.
        let hint = model.kind == .whisper ? vocabulary : nil
        return WhisperSession(model: model, modelPath: store.path(of: model), language: language.code, hint: hint)
    }

    private init(model: SpeechModel, modelPath: String, language: String, hint: String?) {
        self.model = model
        self.modelPath = modelPath
        self.language = language
        self.hint = hint
    }

    func start() async throws {
        guard !started else { return }
        started = true
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        audio.lock.withLock {
            audio.continuation = continuation
            audio.lastAppend = Date()
            audio.active = true
        }

        WhisperEngine.shared.retain(modelPath: modelPath)
        worker = Task { [weak self] in
            for await segment in stream { await self?.recognize(segment) }
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
        guard audio.active, let continuation = audio.continuation, buffer.frameLength > 0 else { return }
        guard let mono = convert(buffer), let data = mono.floatChannelData?[0] else { return }
        audio.lastAppend = Date()
        let samples = UnsafeBufferPointer(start: data, count: Int(mono.frameLength))
        for segment in audio.segmenter.append(samples) { continuation.yield(segment) }
    }

    /// Wandelt in 16 kHz Mono um. Nur unter `audio.lock` aufrufen.
    private nonisolated func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = audio.target
        if buffer.format == target { return buffer }
        if audio.converter == nil || audio.inputFormat != buffer.format {
            audio.converter = AVAudioConverter(from: buffer.format, to: target)
            audio.inputFormat = buffer.format
        }
        guard let converter = audio.converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
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
        audio.lock.lock()
        defer { audio.lock.unlock() }
        guard audio.active, let continuation = audio.continuation else { return }
        if let segment = audio.segmenter.closeIfIdle(Date().timeIntervalSince(audio.lastAppend)) {
            continuation.yield(segment)
        }
    }

    private func recognize(_ segment: [Float]) async {
        onPartial?("…")
        var text = ""
        do {
            text = try await WhisperEngine.shared.transcribe(segment, modelPath: modelPath,
                                                             language: language, hint: hint)
        } catch {
            NSLog("Klar: Erkennung mit %@ fehlgeschlagen: %@", model.id, String(describing: error))
            onPartial?("Erkennung fehlgeschlagen")
            return
        }
        text = HallucinationFilter.clean(text)
        onPartial?("")
        if !text.isEmpty { onCommitted?(text) }
    }

    /// Schließt den offenen Abschnitt ab und wartet, bis alles erkannt ist.
    func stop() async {
        guard started else { return }
        started = false
        idleWatch?.cancel()
        idleWatch = nil

        let (last, continuation) = audio.lock.withLock { () -> ([Float]?, AsyncStream<[Float]>.Continuation?) in
            audio.active = false
            audio.converter = nil
            let continuation = audio.continuation
            audio.continuation = nil
            return (audio.segmenter.flush(), continuation)
        }
        if let last { continuation?.yield(last) }
        continuation?.finish()
        await worker?.value
        worker = nil
        WhisperEngine.shared.release()
    }
}
