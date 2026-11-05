import AVFoundation
import Combine
import Foundation
import Security
import WhisperWire

// Lokale Spracherkennung mit Whisper (whisper.cpp) als Alternative zu Apples Erkennung.
// Aufbau wie in der Windows-Fassung: Ton → 16 kHz Mono → Abschnitte an Sprechpausen → Whisper.

// MARK: - Auswahl

enum SpeechEngine: String, CaseIterable {
    case apple, whisper

    var label: String {
        switch self {
        case .apple: return "Apple"
        case .whisper: return "Whisper"
        }
    }

    static var current: SpeechEngine { SpeechEngine(rawValue: Settings.shared.speechEngine) ?? .apple }
}

/// Whisper-Modell. Wird einmalig von Hugging Face geladen und liegt danach lokal.
struct WhisperModel: Identifiable, Equatable {
    let id: String
    let label: String
    let fileName: String
    let detail: String

    static let fast = WhisperModel(id: "base", label: "Schnell", fileName: "ggml-base-q5_1.bin", detail: "60 MB")
    static let balanced = WhisperModel(id: "small", label: "Ausgewogen", fileName: "ggml-small-q5_1.bin", detail: "190 MB")
    static let accurate = WhisperModel(id: "large-v3-turbo", label: "Genau", fileName: "ggml-large-v3-turbo-q5_0.bin", detail: "574 MB")
    static let all = [fast, balanced, accurate]

    static func find(_ id: String) -> WhisperModel { all.first { $0.id == id } ?? balanced }

    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/" + fileName)! }
    var fileURL: URL { Storage.models.appendingPathComponent(fileName) }

    var isDownloaded: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size > 1_000_000
    }
}

// MARK: - Modelle laden

/// Lädt Whisper-Modelle herunter und meldet den Fortschritt an die Oberfläche.
@MainActor
final class WhisperModelStore: ObservableObject {
    static let shared = WhisperModelStore()

    @Published private(set) var activeID: String?
    /// 0 bis 1.
    @Published private(set) var progress: Double = 0
    @Published private(set) var error: String?

    private var running: Task<Bool, Never>?

    private init() {}

    /// Stellt sicher, dass das Modell vorhanden ist. Läuft bereits ein Download, wird auf ihn gewartet.
    @discardableResult
    func ensure(_ model: WhisperModel) async -> Bool {
        while let running {
            let sameModel = activeID == model.id
            let ok = await running.value
            if sameModel { return ok }
        }
        if model.isDownloaded { return true }

        activeID = model.id
        progress = 0
        error = nil
        // Die Aufgabe räumt selbst auf, damit Wartende beim Aufwachen schon den neuen Stand sehen.
        let task = Task { @MainActor () -> Bool in
            var ok = false
            do {
                try await ModelDownload(destination: model.fileURL) { p in
                    Task { @MainActor in
                        let store = WhisperModelStore.shared
                        if store.activeID == model.id, p > store.progress { store.progress = p }
                    }
                }.run(from: model.url)
                ok = true
            } catch {
                let stalled = (error as? URLError)?.code == .timedOut
                self.error = "Sprachmodell konnte nicht geladen werden: "
                    + (stalled ? "Die Verbindung steht still." : error.localizedDescription)
                NSLog("Klar: Whisper-Modell %@ nicht geladen: %@", model.id, String(describing: error))
            }
            self.running = nil
            self.activeID = nil
            if ok { self.progress = 1 }
            return ok
        }
        running = task
        return await task.value
    }
}

/// Ein Download mit Fortschritt. Steht die Verbindung eine Minute lang still, bricht er ab.
private final class ModelDownload: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(from url: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.addOperation {
                self.continuation = c
                session.downloadTask(with: url).resume()
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Die temporäre Datei verschwindet nach dieser Methode – deshalb hier verschieben.
        do {
            guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let fm = FileManager.default
            let size = (try fm.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size < 1_000_000 || (http.expectedContentLength > 0 && size != http.expectedContentLength) {
                throw URLError(.networkConnectionLost)
            }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = continuation
        continuation = nil
        if let e = error ?? failure { c?.resume(throwing: e) } else { c?.resume() }
    }
}

// MARK: - Abschnitte

/// Teilt einen 16-kHz-Mono-Strom an Sprechpausen in Abschnitte. Nicht threadsicher.
final class SpeechSegmenter {
    static let rate = 16000
    private static let frame = 320 // 20 ms
    private static let frameSeconds = Double(frame) / Double(rate)

    /// Sprechpause, die einen Abschnitt beendet.
    var pauseSeconds = 0.7
    /// Ab dieser Länge genügt eine kurze Pause zum Trennen.
    var softLimitSeconds = 18.0
    var softPauseSeconds = 0.3
    /// Whisper verarbeitet 30-Sekunden-Fenster; spätestens hier wird getrennt.
    var hardLimitSeconds = 28.0
    var minSpeechSeconds = 0.24
    var preRollSeconds = 0.3
    var keepTrailingSeconds = 0.2
    var minThreshold: Float = 0.006

    private var frameBuffer = [Float]()
    private var preRoll = [[Float]]()
    private var segment: [Float]?
    private var speechFrames = 0
    private var silenceRun = 0
    private var onsetRun = 0
    private var noise: Float = 0.002
    private var recent = [Float](repeating: 0, count: 200) // Pegel der letzten vier Sekunden
    private var recentIndex = 0
    private var recentCount = 0

    init() { frameBuffer.reserveCapacity(Self.frame) }

    /// Nimmt 16-kHz-Mono-Samples entgegen und liefert die dabei abgeschlossenen Abschnitte.
    func append(_ samples: UnsafeBufferPointer<Float>) -> [[Float]] {
        var done = [[Float]]()
        var offset = 0
        while offset < samples.count {
            let take = min(Self.frame - frameBuffer.count, samples.count - offset)
            frameBuffer.append(contentsOf: UnsafeBufferPointer(rebasing: samples[offset..<(offset + take)]))
            offset += take
            guard frameBuffer.count == Self.frame else { break }
            if let finished = process(frameBuffer) { done.append(finished) }
            frameBuffer.removeAll(keepingCapacity: true)
        }
        return done
    }

    private func process(_ frame: [Float]) -> [Float]? {
        var sum: Float = 0
        for v in frame { sum += v * v }
        let rms = (sum / Float(frame.count)).squareRoot()

        // Grundrauschen: langsam nachgeführter Wert aus den leisen Phasen, mindestens aber das Minimum
        // der letzten vier Sekunden. So zählt gleichmäßiges Rauschen (Lüfter) nicht als Dauersprache;
        // echte Sprache fällt zwischen Silben immer wieder fast auf das Grundrauschen ab.
        recent[recentIndex] = rms
        recentIndex = (recentIndex + 1) % recent.count
        if recentCount < recent.count { recentCount += 1 }
        var windowMin: Float = 0
        if recentCount >= 50 { windowMin = recent[0..<recentCount].min() ?? 0 }
        let floor = min(max(max(noise, windowMin), 0.0003), 0.05)
        let threshold = max(minThreshold, floor * 3)
        let speech = rms > threshold
        if !speech {
            noise = rms < noise ? noise * 0.7 + rms * 0.3 : noise * 0.995 + rms * 0.005
            noise = min(max(noise, 0.0003), 0.03)
        }

        guard segment != nil else {
            preRoll.append(frame)
            let keep = max(2, Int((preRollSeconds / Self.frameSeconds).rounded()))
            if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
            onsetRun = speech ? onsetRun + 1 : 0
            guard onsetRun >= 2 else { return nil }
            var start = [Float]()
            start.reserveCapacity(Self.rate * 8)
            for f in preRoll { start.append(contentsOf: f) }
            segment = start
            preRoll.removeAll()
            speechFrames = onsetRun
            silenceRun = 0
            onsetRun = 0
            return nil
        }

        segment!.append(contentsOf: frame)
        if speech { speechFrames += 1; silenceRun = 0 } else { silenceRun += 1 }

        let length = Double(segment!.count) / Double(Self.rate)
        let silence = Double(silenceRun) * Self.frameSeconds
        if silence >= pauseSeconds
            || (length >= softLimitSeconds && silence >= softPauseSeconds)
            || length >= hardLimitSeconds {
            return close()
        }
        return nil
    }

    /// Kommt kein Ton mehr (z. B. Systemton pausiert), endet der laufende Abschnitt.
    func closeIfIdle(_ idleFor: TimeInterval) -> [Float]? {
        segment != nil && idleFor >= pauseSeconds ? close() : nil
    }

    /// Am Ende der Aufnahme: den offenen Abschnitt abschließen.
    func flush() -> [Float]? {
        frameBuffer.removeAll(keepingCapacity: true)
        onsetRun = 0
        preRoll.removeAll()
        return segment != nil ? close() : nil
    }

    private func close() -> [Float]? {
        guard var samples = segment else { return nil }
        let speech = Double(speechFrames) * Self.frameSeconds
        let trailing = silenceRun * Self.frame
        segment = nil
        speechFrames = 0
        silenceRun = 0
        guard speech >= minSpeechSeconds else { return nil }
        let cut = max(0, trailing - Int(keepTrailingSeconds * Double(Self.rate)))
        if cut > 0 { samples.removeLast(min(cut, samples.count)) }
        return samples
    }
}

// MARK: - Nachbearbeitung

/// Whisper erfindet bei Stille gern Abspänne. Solche Ausgaben werden verworfen.
enum HallucinationFilter {
    private static let annotation = try! NSRegularExpression(
        pattern: #"\[[^\]]{0,40}\]|\*[^*]{0,40}\*|\((?:musik|music|applaus|applause|lachen|laughter|laughs|stille|silence|räuspern|husten)[^)]{0,20}\)|♪+"#,
        options: [.caseInsensitive])
    private static let spaces = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)

    private static let phrases: Set<String> = [
        "vielen dank fürs zuschauen", "vielen dank für s zuschauen", "danke fürs zuschauen",
        "thanks for watching", "thank you for watching", "bis zum nächsten mal",
        "sous titres réalisés para la communauté d amara org", "sous titres réalisés par la communauté d amara org",
        "sottotitoli creati dalla comunità amara org", "subtítulos realizados por la comunidad de amara org",
        "subtitles by the amara org community",
    ]

    static func clean(_ text: String) -> String {
        var t = annotation.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        t = spaces.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        // Satzzeichen zählen als Wortgrenze, damit „Amara.org“ zu „amara org“ wird.
        let spaced = String(t.map { $0.isLetter || $0.isNumber ? $0 : " " })
        let n = VoiceCommands.normalize(spaced)
        if n.isEmpty { return "" }
        if n.count < 90 && (n.hasPrefix("untertitel") || n.contains("amara org")) { return "" }
        if phrases.contains(n) { return "" }
        return t
    }
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

    /// Wärmt vor, wenn Whisper gewählt und das Modell schon vorhanden ist.
    static func warmUpIfSelected() {
        guard SpeechEngine.current == .whisper else { return }
        let model = WhisperModel.find(Settings.shared.whisperModel)
        if model.isDownloaded { shared.warmUp(modelPath: model.fileURL.path) }
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
                NSLog("Klar: Whisper-Modell konnte nicht geöffnet werden: %@", request.modelPath)
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

/// Whisper als `SpeechBackend`: nimmt Ton entgegen, teilt ihn an Sprechpausen und meldet jeden
/// Abschnitt als bestätigten Text. Vorläufigen Text gibt es nicht – Whisper arbeitet abschnittsweise.
@MainActor
final class WhisperSession: SpeechBackend {
    var onPartial: (@MainActor (String) -> Void)?
    var onCommitted: (@MainActor (String) -> Void)?

    private let model: WhisperModel
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
    static func make(localeIdentifier: String, model: WhisperModel, vocabulary: String?,
                     status: (@MainActor (String) -> Void)?) async -> WhisperSession? {
        if !model.isDownloaded {
            let store = WhisperModelStore.shared
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
            lastError = "Whisper lässt sich nicht starten. Bitte Klar neu installieren."
            return nil
        }
        lastError = nil
        let language = Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? "de"
        return WhisperSession(model: model, language: language, hint: vocabulary)
    }

    private init(model: WhisperModel, language: String, hint: String?) {
        self.model = model
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

        WhisperEngine.shared.retain(modelPath: model.fileURL.path)
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
            text = try await WhisperEngine.shared.transcribe(segment, modelPath: model.fileURL.path,
                                                             language: language, hint: hint)
        } catch {
            NSLog("Klar: Whisper-Erkennung fehlgeschlagen: %@", String(describing: error))
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
