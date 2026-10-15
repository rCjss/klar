import Speech
import AVFoundation

/// Gemeinsame Schnittstelle für die alte (SFSpeechRecognizer) und die neue
/// (SpeechAnalyzer, macOS 26) Spracherkennung.
@MainActor
protocol SpeechBackend: AnyObject {
    var onPartial: (@MainActor (String) -> Void)? { get set }
    var onCommitted: (@MainActor (String) -> Void)? { get set }
    func start() async throws
    nonisolated func append(_ buffer: AVAudioPCMBuffer)
    func stop() async
}

enum SpeechBackendFactory {
    /// Liefert die beste verfügbare Erkennung für die Sprache. Lädt bei Bedarf das Sprachmodell.
    @MainActor
    static func make(localeIdentifier: String, status: (@MainActor (String) -> Void)? = nil) async -> SpeechBackend? {
        if #available(macOS 26.0, *) {
            if let modern = await AnalyzerSession.make(localeIdentifier: localeIdentifier, status: status) {
                return modern
            }
        }
        return SpeechSession(localeIdentifier: localeIdentifier)
    }
}

extension SpeechSession: SpeechBackend {
    func start() async throws { begin() }
    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            end { cont.resume() }
        }
    }
}

// MARK: - SpeechAnalyzer (macOS 26)

@available(macOS 26.0, *)
@MainActor
final class AnalyzerSession: SpeechBackend {
    var onPartial: (@MainActor (String) -> Void)?
    var onCommitted: (@MainActor (String) -> Void)?

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    nonisolated private let targetFormat: AVAudioFormat
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    nonisolated private let converterBox = ConverterBox()

    /// Konverter läuft auf dem Audio-Thread; Zugriff über Lock.
    private final class ConverterBox {
        let lock = NSLock()
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var active = false

        func activate(_ c: AsyncStream<AnalyzerInput>.Continuation) {
            lock.lock(); continuation = c; active = true; lock.unlock()
        }
        func deactivate() {
            lock.lock(); continuation = nil; active = false; converter = nil; lock.unlock()
        }
    }

    static func make(localeIdentifier: String, status: (@MainActor (String) -> Void)?) async -> AnalyzerSession? {
        let locale = Locale(identifier: localeIdentifier)
        let supported = await SpeechTranscriber.supportedLocales
        guard let match = supported.first(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) })
                ?? supported.first(where: { $0.language.languageCode == locale.language.languageCode }) else {
            return nil
        }
        let transcriber = SpeechTranscriber(locale: match,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                status?("Sprachmodell wird geladen …")
                try await request.downloadAndInstall()
            }
        } catch {
            NSLog("Klar: Sprachmodell konnte nicht geladen werden: \(error)")
            return nil
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return nil }
        return AnalyzerSession(transcriber: transcriber, analyzer: analyzer, format: format)
    }

    private init(transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.targetFormat = format
    }

    func start() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.continuation = continuation
        converterBox.activate(continuation)

        resultsTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await result in self.transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.onPartial?("")
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { self.onCommitted?(t) }
                    } else {
                        self.onPartial?(text)
                    }
                }
            } catch {
                NSLog("Klar: Analyzer-Ergebnisse beendet: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        converterBox.lock.lock()
        defer { converterBox.lock.unlock() }
        guard converterBox.active, let continuation = converterBox.continuation else { return }
        let target = targetFormat
        if buffer.format == target {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converterBox.converter == nil || converterBox.inputFormat != buffer.format {
            converterBox.converter = AVAudioConverter(from: buffer.format, to: target)
            converterBox.inputFormat = buffer.format
        }
        guard let converter = converterBox.converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: out))
    }

    func stop() async {
        converterBox.deactivate()
        continuation?.finish()
        continuation = nil
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            NSLog("Klar: Analyzer-Abschluss: \(error)")
        }
        // Ergebnis-Stream endet nach dem Abschluss von selbst.
        _ = await resultsTask?.value
        resultsTask = nil
    }
}
