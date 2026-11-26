import AVFoundation
import XCTest
@testable import Klar

/// Prüft die gemeinsamen Teile und – wenn die Modelle bereitliegen – die echte Erkennung im Simulator.
/// Die Modelle und Testaufnahmen gibt der Workflow über die Umgebung mit:
///   KLAR_MODELS  Ordner wie in der App (ggml-…bin und parakeet-tdt-0.6b-v3/)
///   KLAR_WAVS    Ordner mit de.wav, en.wav, ro.wav, pl.wav, tr.wav
final class KlarTests: XCTestCase {
    private let expected = [
        "de": "guten morgen", "en": "good morning", "ro": "bună dimineața", "pl": "dzień dobry", "tr": "günaydın",
    ]

    func testCatalog() {
        XCTAssertEqual(SpeechModels.all.map(\.id), ["large-v3", "large-v3-turbo", "parakeet-tdt-0.6b-v3"])
        XCTAssertEqual(SpeechLanguage.all.map(\.code), ["de", "en", "ro", "pl", "tr"])
        XCTAssertFalse(SpeechModels.parakeetV3.supports(languageCode: "tr"))
        XCTAssertTrue(SpeechModels.parakeetV3.supports(languageCode: "ro"))
        XCTAssertTrue(SpeechModels.whisperLargeV3.supports(languageCode: "tr"))
        XCTAssertEqual(SpeechModels.find("small").id, "large-v3-turbo")
        XCTAssertEqual(SpeechLanguage.find("en-GB").id, "en-US")
        XCTAssertEqual(SpeechModels.whisperLargeV3Turbo.sizeLabel, "574 MB")
    }

    func testSegmenterSplitsAtPauses() {
        let s = SpeechSegmenter()
        var tone = [Float](repeating: 0, count: 16000 * 3)
        for i in 0..<16000 { tone[i] = 0.2 * sin(Float(i) * 0.05) }           // 1 s Ton
        for i in 32000..<40000 { tone[i] = 0.2 * sin(Float(i) * 0.05) }       // 0,5 s Ton nach 1 s Pause
        let parts = tone.withUnsafeBufferPointer { s.append($0) }
        XCTAssertEqual(parts.count, 1)
        XCTAssertNotNil(s.flush())
    }

    func testParakeet() throws { try recognize(SpeechModels.parakeetV3, languages: ["de", "en", "ro", "pl"]) }

    func testWhisperTurbo() throws { try recognize(SpeechModels.whisperLargeV3Turbo, languages: ["de", "en", "ro", "pl", "tr"]) }

    private func recognize(_ model: SpeechModel, languages: [String]) throws {
        let env = ProcessInfo.processInfo.environment
        guard let models = env["KLAR_MODELS"], let wavs = env["KLAR_WAVS"] else {
            throw XCTSkip("KLAR_MODELS/KLAR_WAVS nicht gesetzt")
        }
        let directory = URL(fileURLWithPath: models)
        guard model.isDownloaded(in: directory) else { throw XCTSkip("\(model.label) liegt nicht bereit") }
        let recognizer = LocalRecognizer()
        var checked = 0
        for code in languages {
            let wav = URL(fileURLWithPath: wavs).appendingPathComponent(code + ".wav")
            guard FileManager.default.fileExists(atPath: wav.path) else { continue }
            let samples = try Self.read(wav)
            let started = Date()
            let result = recognizer.transcribe(modelPath: model.location(in: directory).path, samples: samples,
                                               language: code, hint: "")
            guard case .text(let text) = result else { return XCTFail("\(model.label) \(code): \(result)") }
            print(String(format: "%@ %@ (%.1f s): %@", model.label, code, Date().timeIntervalSince(started), text))
            XCTAssertTrue(text.lowercased().contains(expected[code]!), "\(model.label) \(code): „\(text)“")
            checked += 1
        }
        recognizer.unload()
        XCTAssertGreaterThan(checked, 0, "keine Testaufnahme gefunden")
    }

    /// Datei → 16 kHz Mono Float.
    private static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16000 / file.processingFormat.sampleRate) + 1024
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
