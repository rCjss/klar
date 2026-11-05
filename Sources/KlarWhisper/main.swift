import Foundation
import WhisperWire
import whisper

// Hilfsprozess für die Whisper-Erkennung. Klar startet ihn bei Bedarf, schickt Tonabschnitte über die
// Standardeingabe und liest den erkannten Text von der Standardausgabe. Schließt Klar die Leitung
// (oder endet Klar), beendet sich der Prozess und gibt das Modell frei.

signal(SIGPIPE, SIG_IGN)

// whisper.cpp schreibt sonst jede Kleinigkeit nach stderr; nur Fehler interessieren.
whisper_log_set({ level, text, _ in
    guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
    let message = String(cString: text)
    // Ein Core-ML-Modell liegt nicht bei; whisper.cpp rechnet dann wie vorgesehen über Metal.
    if message.contains("Core ML") { return }
    FileHandle.standardError.write(Data(("whisper: " + message).utf8))
}, nil)

var context: OpaquePointer?
var loadedPath: String?

func load(_ path: String) -> OpaquePointer? {
    if let context, loadedPath == path { return context }
    if let context { whisper_free(context) }
    context = nil
    loadedPath = nil
    var params = whisper_context_default_params()
    #if arch(x86_64)
    params.use_gpu = false // Metal lohnt sich nur auf Apple Silicon
    #endif
    guard let ctx = whisper_init_from_file_with_params(path, params) else { return nil }
    context = ctx
    loadedPath = path
    return ctx
}

func handle(_ request: Wire.Request) -> Wire.Response {
    guard let ctx = load(request.modelPath) else { return .init(status: .modelNotLoaded, text: "") }
    if request.samples.isEmpty { return .init(status: .ok, text: "") }

    // whisper.cpp verwirft Eingaben unter einer Sekunde – kurze Abschnitte mit Stille auffüllen.
    var input = request.samples
    let minimum = 16000 * 5 / 4
    if input.count < minimum { input.append(contentsOf: repeatElement(0, count: minimum - input.count)) }

    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    params.n_threads = Int32(min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)))
    params.translate = false
    params.detect_language = false
    params.no_context = true
    params.print_special = false
    params.print_progress = false
    params.print_realtime = false
    params.print_timestamps = false

    let prompt = request.hint.trimmingCharacters(in: .whitespacesAndNewlines)
    let status: Int32 = request.language.withCString { language in
        prompt.withCString { promptPointer in
            params.language = language
            params.initial_prompt = prompt.isEmpty ? nil : promptPointer
            return input.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
        }
    }
    guard status == 0 else { return .init(status: .inferenceFailed, text: "") }

    var text = ""
    for i in 0..<whisper_full_n_segments(ctx) {
        if whisper_full_get_segment_no_speech_prob(ctx, i) > 0.8 { continue }
        if let c = whisper_full_get_segment_text(ctx, i) { text += String(cString: c) }
    }
    return .init(status: .ok, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
}

while true {
    guard let request = try? Wire.readRequest(from: STDIN_FILENO) else { break }
    do { try Wire.write(handle(request), to: STDOUT_FILENO) } catch { break }
}

// Vor dem Ende freigeben: whisper.cpp bricht sonst beim Aufräumen des Prozesses mit einer Assertion ab.
if let context { whisper_free(context) }
exit(0)
