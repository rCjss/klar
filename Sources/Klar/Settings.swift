import Foundation
import Combine

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var clipboardHotkey: Hotkey { didSet { save("clipboardHotkey", clipboardHotkey) } }
    @Published var dictationHotkey: Hotkey { didSet { save("dictationHotkey", dictationHotkey) } }
    @Published var meetingHotkey: Hotkey { didSet { save("meetingHotkey", meetingHotkey) } }
    @Published var recordingHotkey: Hotkey { didSet { save("recordingHotkey", recordingHotkey) } }
    @Published var snippets: [Snippet] { didSet { save("snippets", snippets) } }
    @Published var localeIdentifier: String { didSet { d.set(localeIdentifier, forKey: "locale") } }
    @Published var commandPrefix: String { didSet { d.set(commandPrefix, forKey: "commandPrefix") } }
    @Published var historyLimit: Int { didSet { d.set(historyLimit, forKey: "historyLimit") } }
    @Published var pasteAfterDictation: Bool { didSet { d.set(pasteAfterDictation, forKey: "pasteAfterDictation") } }
    @Published var recordMicInScreenRecording: Bool { didSet { d.set(recordMicInScreenRecording, forKey: "recordMic") } }
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }
    @Published var autoSummarize: Bool { didSet { d.set(autoSummarize, forKey: "autoSummarize") } }
    @Published var summaryProvider: String { didSet { d.set(summaryProvider, forKey: "summaryProvider") } }
    @Published var claudeAPIKey: String { didSet { KeychainHelper.write(account: "claude-api-key", value: claudeAPIKey.trimmingCharacters(in: .whitespaces)) } }
    @Published var giphyAPIKey: String { didSet { KeychainHelper.write(account: "giphy-api-key", value: giphyAPIKey.trimmingCharacters(in: .whitespaces)) } }

    private init() {
        clipboardHotkey = Self.load("clipboardHotkey") ?? .clipboardDefault
        dictationHotkey = Self.load("dictationHotkey") ?? .dictationDefault
        meetingHotkey = Self.load("meetingHotkey") ?? .meetingDefault
        recordingHotkey = Self.load("recordingHotkey") ?? .recordingDefault
        snippets = Self.load("snippets") ?? [
            Snippet(trigger: "Signatur", text: "Viele Grüße\n" + NSFullUserName()),
        ]
        localeIdentifier = d.string(forKey: "locale") ?? "de-DE"
        commandPrefix = d.string(forKey: "commandPrefix") ?? "einfügen"
        historyLimit = d.object(forKey: "historyLimit") as? Int ?? 500
        pasteAfterDictation = d.object(forKey: "pasteAfterDictation") as? Bool ?? true
        recordMicInScreenRecording = d.object(forKey: "recordMic") as? Bool ?? false
        showInDock = d.object(forKey: "showInDock") as? Bool ?? false
        autoSummarize = d.object(forKey: "autoSummarize") as? Bool ?? true
        summaryProvider = d.string(forKey: "summaryProvider") ?? "auto"
        claudeAPIKey = KeychainHelper.read(account: "claude-api-key")
        giphyAPIKey = KeychainHelper.read(account: "giphy-api-key")
    }

    private func save<T: Encodable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
