import AVFoundation
import Foundation

/// Selbsttest der Whisper-Erkennung ohne Oberfläche:
///
///     Klar.app/Contents/MacOS/Klar --whisper-selftest aufnahme.wav [--locale de-DE] [--model small]
///
/// Spielt die Audiodatei wie ein Mikrofon ein und gibt den erkannten Text aus. Prüft damit die ganze
/// Kette – Modell, Hilfsprozess, Signatur der App –, ohne Einstellungen zu lesen oder zu ändern.
/// Fehlt das Modell, wird es geladen. Endet mit 0, wenn Text erkannt wurde.
enum WhisperSelfTest {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--whisper-selftest") else { return }
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard flag + 1 < args.count else {
            print("Aufruf: Klar --whisper-selftest <Audiodatei> [--locale de-DE] [--model base|small|large-v3-turbo]")
            exit(2)
        }
        setvbuf(stdout, nil, _IONBF, 0)
        let path = args[flag + 1]
        let locale = value("--locale") ?? "de-DE"
        let model = WhisperModel.find(value("--model") ?? WhisperModel.balanced.id)
        Task { @MainActor in
            let ok = await run(path: path, locale: locale, model: model)
            WhisperEngine.shared.shutdown()
            exit(ok ? 0 : 1)
        }
        dispatchMain()
    }

    @MainActor
    private static func run(path: String, locale: String, model: WhisperModel) async -> Bool {
        print("Modell: \(model.label) (\(model.fileName)), Sprache: \(locale)")
        var lastStatus = ""
        guard let session = await WhisperSession.make(localeIdentifier: locale, model: model, vocabulary: nil,
                                                      status: { lastStatus = $0 }) else {
            print("FEHLER: " + (WhisperSession.lastError ?? "Whisper konnte nicht gestartet werden."))
            return false
        }
        if !lastStatus.isEmpty { print(lastStatus) }

        var parts: [String] = []
        let started = Date()
        session.onCommitted = { text in
            parts.append(text)
            print(String(format: "[%.1f s] %@", Date().timeIntervalSince(started), text))
        }
        do {
            try await session.start()
            let seconds = try await Task.detached { try feed(path, into: session) }.value
            await session.stop()
            print(String(format: "%.1f s Ton in %.1f s erkannt, %d Abschnitte.", seconds,
                         Date().timeIntervalSince(started), parts.count))
        } catch {
            await session.stop()
            print("FEHLER: Audiodatei nicht lesbar – \(error.localizedDescription)")
            return false
        }
        print(parts.isEmpty ? "FEHLER: nichts erkannt." : "OK")
        return !parts.isEmpty
    }

    /// Liest die Datei blockweise und reicht sie weiter, so wie es sonst der Audio-Thread tut.
    private static func feed(_ path: String, into session: WhisperSession) throws -> Double {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        var seconds = 0.0
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { break }
            try file.read(into: buffer, frameCount: 4096)
            if buffer.frameLength == 0 { break }
            session.append(buffer)
            seconds += Double(buffer.frameLength) / format.sampleRate
        }
        return seconds
    }
}
