import Foundation
import KlarRecognizers
import WhisperWire

// Hilfsprozess für die lokale Erkennung (Whisper und Parakeet). Klar startet ihn bei Bedarf, schickt
// Tonabschnitte über die Standardeingabe und liest den erkannten Text von der Standardausgabe. Schließt
// Klar die Leitung (oder endet Klar), beendet sich der Prozess und gibt das Modell frei.

signal(SIGPIPE, SIG_IGN)

let recognizer = LocalRecognizer()

func handle(_ request: Wire.Request) -> Wire.Response {
    switch recognizer.transcribe(modelPath: request.modelPath, samples: request.samples,
                                 language: request.language, hint: request.hint) {
    case .text(let text): return .init(status: .ok, text: text)
    case .modelNotLoaded: return .init(status: .modelNotLoaded, text: "")
    case .failed: return .init(status: .inferenceFailed, text: "")
    }
}

while true {
    guard let request = try? Wire.readRequest(from: STDIN_FILENO) else { break }
    do { try Wire.write(handle(request), to: STDOUT_FILENO) } catch { break }
}

// Vor dem Ende freigeben: whisper.cpp bricht sonst beim Aufräumen des Prozesses mit einer Assertion ab.
recognizer.unload()
exit(0)
