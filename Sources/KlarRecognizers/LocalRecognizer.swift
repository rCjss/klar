import Foundation
import SherpaOnnxC
import whisper

/// Lokale Erkennung mit Whisper (whisper.cpp) oder Parakeet (sherpa-onnx). Hält ein Modell im Speicher.
/// Auf dem Mac läuft sie im Hilfsprozess `KlarWhisper`, auf dem iPhone direkt in der App.
/// Nicht threadsicher – Aufrufe nacheinander.
public final class LocalRecognizer {
    public enum Result { case text(String), modelNotLoaded, failed }

    private var whisperContext: OpaquePointer?
    private var parakeet: OpaquePointer?
    private var loadedPath: String?

    public init() {
        Self.quietLogs()
    }

    deinit { unload() }

    /// Modell öffnen. Ein Ordner ist ein Parakeet-Modell, eine Datei ein Whisper-Modell.
    public func load(_ path: String) -> Bool {
        if loadedPath == path, whisperContext != nil || parakeet != nil { return true }
        unload()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue {
            parakeet = Self.openParakeet(path)
        } else {
            whisperContext = Self.openWhisper(path)
        }
        guard whisperContext != nil || parakeet != nil else { return false }
        loadedPath = path
        return true
    }

    /// Gibt das Modell frei (mehrere hundert MB Arbeitsspeicher).
    public func unload() {
        if let whisperContext { whisper_free(whisperContext) }
        if let parakeet { SherpaOnnxDestroyOfflineRecognizer(parakeet) }
        whisperContext = nil
        parakeet = nil
        loadedPath = nil
    }

    /// - Parameters:
    ///   - samples: 16 kHz Mono. Leer = nur das Modell laden.
    ///   - language: Sprachcode, z. B. „de“. Parakeet erkennt die Sprache selbst.
    ///   - hint: Wörter, die wahrscheinlich vorkommen. Nur Whisper nutzt ihn.
    public func transcribe(modelPath: String, samples: [Float], language: String, hint: String) -> Result {
        guard load(modelPath) else { return .modelNotLoaded }
        if samples.isEmpty { return .text("") }
        if let parakeet { return Self.runParakeet(parakeet, samples) }
        if let whisperContext { return Self.runWhisper(whisperContext, samples, language: language, hint: hint) }
        return .modelNotLoaded
    }

    private static var threads: Int32 {
        Int32(min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)))
    }

    // MARK: Whisper

    private static func openWhisper(_ path: String) -> OpaquePointer? {
        var params = whisper_context_default_params()
        #if os(macOS) && arch(x86_64)
        params.use_gpu = false // Metal lohnt sich nur auf Apple Silicon
        #endif
        return whisper_init_from_file_with_params(path, params)
    }

    private static func runWhisper(_ ctx: OpaquePointer, _ samples: [Float], language: String, hint: String) -> Result {
        // whisper.cpp verwirft Eingaben unter einer Sekunde – kurze Abschnitte mit Stille auffüllen.
        var input = samples
        let minimum = 16000 * 5 / 4
        if input.count < minimum { input.append(contentsOf: repeatElement(0, count: minimum - input.count)) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threads
        params.translate = false
        params.detect_language = false
        params.no_context = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false

        let prompt = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let status: Int32 = language.withCString { languagePointer in
            prompt.withCString { promptPointer in
                params.language = languagePointer
                params.initial_prompt = prompt.isEmpty ? nil : promptPointer
                return input.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
            }
        }
        guard status == 0 else { return .failed }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if whisper_full_get_segment_no_speech_prob(ctx, i) > 0.8 { continue }
            if let c = whisper_full_get_segment_text(ctx, i) { text += String(cString: c) }
        }
        return .text(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Parakeet

    private static func openParakeet(_ directory: String) -> OpaquePointer? {
        let folder = URL(fileURLWithPath: directory)
        let files = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]
            .map { folder.appendingPathComponent($0).path }
        guard files.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else { return nil }
        // Die Zeichenketten müssen bis nach dem Anlegen des Erkenners leben.
        let strings: [UnsafeMutablePointer<CChar>?] = (files + ["nemo_transducer", "cpu", "greedy_search"]).map { strdup($0) }
        defer { strings.forEach { free($0) } }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = UnsafePointer(strings[0])
        config.model_config.transducer.decoder = UnsafePointer(strings[1])
        config.model_config.transducer.joiner = UnsafePointer(strings[2])
        config.model_config.tokens = UnsafePointer(strings[3])
        config.model_config.model_type = UnsafePointer(strings[4])
        config.model_config.provider = UnsafePointer(strings[5])
        config.model_config.num_threads = threads
        config.model_config.debug = 0
        config.decoding_method = UnsafePointer(strings[6])
        return SherpaOnnxCreateOfflineRecognizer(&config)
    }

    private static func runParakeet(_ recognizer: OpaquePointer, _ samples: [Float]) -> Result {
        // Kurze Abschnitte mit etwas Stille auffüllen, sonst fehlt das letzte Wort gelegentlich.
        var input = samples
        input.append(contentsOf: repeatElement(0, count: 16000 / 4))
        let r = recognizer
        guard let stream = SherpaOnnxCreateOfflineStream(r) else { return .failed }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        input.withUnsafeBufferPointer {
            SherpaOnnxAcceptWaveformOffline(stream, 16000, $0.baseAddress, Int32($0.count))
        }
        SherpaOnnxDecodeOfflineStream(r, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return .failed }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        let text: String = result.pointee.text.map { String(cString: $0) } ?? ""
        return .text(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Protokoll

    private static var logsQuieted = false

    /// whisper.cpp schreibt sonst jede Kleinigkeit nach stderr; nur Fehler interessieren.
    private static func quietLogs() {
        guard !logsQuieted else { return }
        logsQuieted = true
        whisper_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            let message = String(cString: text)
            // Ein Core-ML-Modell liegt nicht bei; whisper.cpp rechnet dann wie vorgesehen über Metal.
            if message.contains("Core ML") { return }
            FileHandle.standardError.write(Data(("whisper: " + message).utf8))
        }, nil)
    }
}
