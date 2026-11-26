import Foundation

// Gemeinsame Teile der lokalen Spracherkennung für Mac und iPhone: Modelle, Sprachen, Abschnitte,
// Nachbearbeitung und Download. Die Windows-Fassung führt dieselben Angaben in Klar.Core/Speech.cs.

/// Womit ein Modell gerechnet wird.
public enum SpeechModelKind: Sendable {
    /// whisper.cpp, eine einzelne ggml-Datei.
    case whisper
    /// NVIDIA Parakeet über sherpa-onnx, ein Ordner mit Encoder, Decoder, Joiner und Tokens.
    case parakeet
}

/// Eine Datei eines Modells. Die Prüfsumme stellt sicher, dass genau diese Datei ankommt.
public struct SpeechModelFile: Sendable, Equatable {
    public let name: String
    public let bytes: Int64
    public let sha256: String
}

/// Ein lokales Sprachmodell. Wird einmalig von Hugging Face geladen und liegt danach auf dem Gerät.
public struct SpeechModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let kind: SpeechModelKind
    /// Basisadresse auf Hugging Face, festgelegt auf einen Stand des Repositorys.
    public let baseURL: String
    public let files: [SpeechModelFile]
    /// Sprachcodes, die das Modell kennt. `nil` = alle (Whisper).
    public let languages: Set<String>?

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// „574 MB“, „1,1 GB“.
    public var sizeLabel: String {
        let mb = Double(totalBytes) / 1_000_000
        if mb < 1000 { return "\(Int(mb.rounded())) MB" }
        return String(format: "%.1f GB", mb / 1000).replacingOccurrences(of: ".", with: ",")
    }

    public func supports(languageCode: String) -> Bool {
        languages?.contains(languageCode) ?? true
    }

    /// Ablageort im Modellordner: bei Whisper die Datei, bei Parakeet ein Unterordner.
    public func location(in directory: URL) -> URL {
        switch kind {
        case .whisper: return directory.appendingPathComponent(files[0].name)
        case .parakeet: return directory.appendingPathComponent(id, isDirectory: true)
        }
    }

    /// Zieladresse jeder Datei.
    public func fileURL(_ file: SpeechModelFile, in directory: URL) -> URL {
        switch kind {
        case .whisper: return directory.appendingPathComponent(file.name)
        case .parakeet: return location(in: directory).appendingPathComponent(file.name)
        }
    }

    public func url(of file: SpeechModelFile) -> URL { URL(string: baseURL + file.name)! }

    /// Alle Dateien vorhanden und vollständig.
    public func isDownloaded(in directory: URL) -> Bool {
        files.allSatisfy { file in
            let path = fileURL(file, in: directory).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? -1
            return size == file.bytes
        }
    }
}

public enum SpeechModels {
    private static let whisperBase =
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/"
    private static let parakeetBase =
        "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/ed5d745623472f97cfc2e6c2916ee248798fc5a8/"

    /// Die 25 europäischen Sprachen von Parakeet TDT 0.6B v3. Türkisch gehört nicht dazu.
    public static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt",
        "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    public static let whisperLargeV3 = SpeechModel(
        id: "large-v3", label: "Whisper Large-v3", kind: .whisper, baseURL: whisperBase,
        files: [.init(name: "ggml-large-v3-q5_0.bin", bytes: 1_081_140_203,
                      sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1")],
        languages: nil)

    public static let whisperLargeV3Turbo = SpeechModel(
        id: "large-v3-turbo", label: "Whisper Large-v3 Turbo", kind: .whisper, baseURL: whisperBase,
        files: [.init(name: "ggml-large-v3-turbo-q5_0.bin", bytes: 574_041_195,
                      sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")],
        languages: nil)

    public static let parakeetV3 = SpeechModel(
        id: "parakeet-tdt-0.6b-v3", label: "Parakeet TDT 0.6B v3", kind: .parakeet, baseURL: parakeetBase,
        files: [
            .init(name: "encoder.int8.onnx", bytes: 652_282_294,
                  sha256: "1afbe69c1ffdabee94755f42e4daf1d93549131a3da11356bda84fcef0f2c479"),
            .init(name: "decoder.int8.onnx", bytes: 11_845_274,
                  sha256: "0222a86147299d4dee90edf95b6d13827edb42ad8b7c9cf0b2582f030937c0b5"),
            .init(name: "joiner.int8.onnx", bytes: 6_355_277,
                  sha256: "cbd02f3696e9944970111fb439d9c3fd365a80374565f13f2b9c7007d253fc98"),
            .init(name: "tokens.txt", bytes: 93_939,
                  sha256: "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"),
        ],
        languages: parakeetLanguages)

    public static let all = [whisperLargeV3, whisperLargeV3Turbo, parakeetV3]
    public static let standard = whisperLargeV3Turbo

    /// Frühere Modelle („base“, „small“) gibt es nicht mehr; sie werden zum Turbo-Modell.
    public static func find(_ id: String?) -> SpeechModel {
        all.first { $0.id == id } ?? standard
    }
}

/// Sprachen, in denen Klar diktiert.
public struct SpeechLanguage: Identifiable, Equatable, Sendable {
    /// Locale, z. B. „de-DE“.
    public let id: String
    public let name: String
    /// Sprachcode, z. B. „de“.
    public var code: String { String(id.prefix { $0 != "-" }).lowercased() }

    public static let all: [SpeechLanguage] = [
        .init(id: "de-DE", name: "Deutsch"),
        .init(id: "en-US", name: "Englisch"),
        .init(id: "ro-RO", name: "Rumänisch"),
        .init(id: "pl-PL", name: "Polnisch"),
        .init(id: "tr-TR", name: "Türkisch"),
    ]

    /// Unbekannte oder nicht mehr angebotene Einstellungen werden zur passenden Sprache oder zu Deutsch.
    public static func find(_ id: String?) -> SpeechLanguage {
        if let exact = all.first(where: { $0.id == id }) { return exact }
        let code = String((id ?? "").prefix { $0 != "-" }).lowercased()
        return all.first { $0.code == code } ?? all[0]
    }
}
