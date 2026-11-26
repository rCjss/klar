import Foundation

/// Einstellungen der iPhone-App.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    /// „apple“ oder die ID eines lokalen Modells (siehe `SpeechModels`).
    @Published var engine: String { didSet { d.set(engine, forKey: "engine") } }
    @Published var localeIdentifier: String { didSet { d.set(localeIdentifier, forKey: "locale") } }
    @Published var copyAfterDictation: Bool { didSet { d.set(copyAfterDictation, forKey: "copyAfterDictation") } }

    static let apple = "apple"

    private init() {
        let stored = d.string(forKey: "engine") ?? Self.apple
        engine = stored == Self.apple ? stored : SpeechModels.find(stored).id
        localeIdentifier = SpeechLanguage.find(d.string(forKey: "locale") ?? Locale.preferredLanguages.first).id
        copyAfterDictation = d.object(forKey: "copyAfterDictation") as? Bool ?? true
    }

    var language: SpeechLanguage { SpeechLanguage.find(localeIdentifier) }

    /// Das gewählte lokale Modell, oder `nil` für Apples Erkennung.
    var localModel: SpeechModel? { engine == Self.apple ? nil : SpeechModels.find(engine) }

    var engineLabel: String { localModel?.label ?? "Apple" }
}

enum Files {
    /// Ordner für Sprachmodelle. Wird nicht in iCloud gesichert – die Modelle lassen sich jederzeit neu laden.
    static let models: URL = {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    static let history: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictations.json")
    }()
}

@MainActor
enum LocalModels {
    static let store = ModelStore(directory: Files.models)
}
