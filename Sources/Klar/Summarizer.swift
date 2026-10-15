import Foundation
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Erstellt Zusammenfassungen von Meeting-Transkripten – lokal über Apple Intelligence
/// oder über die Claude-API, falls ein Schlüssel hinterlegt ist.
@MainActor
final class Summarizer: ObservableObject {
    static let shared = Summarizer()
    @Published private(set) var busy: Set<UUID> = []
    @Published private(set) var lastError: String?

    static let instructions = """
    Du fasst Meeting-Transkripte auf Deutsch zusammen. Sprecher „Ich“ ist der Nutzer, „Andere“ sind die Gesprächspartner.
    Nutze ausschließlich Informationen aus dem Transkript, erfinde nichts. Antworte in Markdown mit genau diesen Abschnitten:
    ## Kurzfassung
    (3–5 Sätze)
    ## Themen
    (Stichpunkte)
    ## Entscheidungen
    (Stichpunkte, oder „Keine“)
    ## Aufgaben
    (Stichpunkte: Wer macht was bis wann, oder „Keine“)
    ## Offene Fragen
    (Stichpunkte, oder „Keine“)
    """

    enum Provider: String, CaseIterable {
        case auto, claudeCode, claudeAPI, apple

        var label: String {
            switch self {
            case .auto: return "Automatisch"
            case .claudeCode: return "Claude Code"
            case .claudeAPI: return "Claude-API"
            case .apple: return "Apple Intelligence"
            }
        }
    }

    private static var appleAvailable: Bool {
        if #available(macOS 26.0, *) { return AppleModelBackend.isAvailable }
        return false
    }

    /// Der tatsächlich genutzte Weg – bei „Automatisch“: Claude Code, sonst API-Schlüssel, sonst Apple.
    var resolvedProvider: Provider? {
        let choice = Provider(rawValue: Settings.shared.summaryProvider) ?? .auto
        let hasKey = !KeychainHelper.read(account: "claude-api-key").isEmpty
        switch choice {
        case .claudeCode: return ClaudeCodeBackend.isAvailable ? .claudeCode : nil
        case .claudeAPI: return hasKey ? .claudeAPI : nil
        case .apple: return Self.appleAvailable ? .apple : nil
        case .auto:
            if ClaudeCodeBackend.isAvailable { return .claudeCode }
            if hasKey { return .claudeAPI }
            if Self.appleAvailable { return .apple }
            return nil
        }
    }

    var appleStatus: String {
        if #available(macOS 26.0, *) { return AppleModelBackend.status }
        return "benötigt macOS 26"
    }

    var claudeCodeStatus: String {
        ClaudeCodeBackend.isAvailable ? "installiert, nutzt dein Abo" : "nicht gefunden"
    }

    var claudeAPIStatus: String {
        KeychainHelper.read(account: "claude-api-key").isEmpty ? "kein Schlüssel" : "Schlüssel hinterlegt"
    }

    func summarize(_ id: UUID) async {
        guard !busy.contains(id), let meeting = MeetingStore.shared.items.first(where: { $0.id == id }) else { return }
        guard !meeting.lines.isEmpty else { lastError = "Das Transkript ist leer."; return }
        busy.insert(id)
        lastError = nil
        defer { busy.remove(id) }
        do {
            let text = meeting.plainText
            let summary: String
            switch resolvedProvider {
            case .claudeCode:
                summary = try await ClaudeCodeBackend().summarize(text)
            case .claudeAPI:
                summary = try await ClaudeBackend(apiKey: KeychainHelper.read(account: "claude-api-key")).summarize(text)
            case .apple:
                if #available(macOS 26.0, *) {
                    summary = try await AppleModelBackend().summarize(text)
                } else {
                    throw SummaryError.unavailable
                }
            case .auto, nil:
                throw SummaryError.unavailable
            }
            MeetingStore.shared.setSummary(id, summary)
        } catch {
            lastError = (error as? SummaryError)?.message ?? error.localizedDescription
        }
    }
}

enum SummaryError: Error {
    case unavailable, http(Int, String), refused, empty, claudeCode(String)
    var message: String {
        switch self {
        case .unavailable: return "Keine Zusammenfassung möglich: Der gewählte Weg ist nicht verfügbar (Einstellungen → Zusammenfassung)."
        case .claudeCode(let detail): return "Claude Code: \(detail)"
        case .http(let code, let body): return "Claude-API antwortete mit \(code): \(body.prefix(200))"
        case .refused: return "Die Anfrage wurde vom Modell abgelehnt."
        case .empty: return "Leere Antwort erhalten."
        }
    }
}

// MARK: - Apple Intelligence (macOS 26)

@available(macOS 26.0, *)
struct AppleModelBackend {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var status: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "verfügbar"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "Gerät nicht geeignet"
            case .appleIntelligenceNotEnabled: return "Apple Intelligence ist in den Systemeinstellungen nicht aktiviert"
            case .modelNotReady: return "Modell wird noch geladen"
            @unknown default: return "nicht verfügbar"
            }
        }
    }

    /// Das lokale Modell hat ein kleines Kontextfenster – lange Transkripte werden
    /// in Abschnitten zusammengefasst und anschließend verdichtet.
    func summarize(_ text: String) async throws -> String {
        let chunks = Self.chunk(text, maxWords: 900)
        if chunks.count == 1 {
            return try await respond(instructions: Summarizer.instructions, prompt: "Transkript:\n\n" + chunks[0])
        }
        var partials: [String] = []
        for (i, c) in chunks.enumerated() {
            let p = try await respond(
                instructions: "Du fasst einen Abschnitt eines Meeting-Transkripts auf Deutsch zusammen. Nenne Themen, Entscheidungen, Aufgaben und offene Fragen als knappe Stichpunkte. Erfinde nichts.",
                prompt: "Abschnitt \(i + 1) von \(chunks.count):\n\n" + c)
            partials.append(p)
        }
        return try await respond(instructions: Summarizer.instructions,
                                 prompt: "Hier sind Teilzusammenfassungen eines Meetings in zeitlicher Reihenfolge. Führe sie zu einer Gesamtzusammenfassung zusammen:\n\n" + partials.joined(separator: "\n\n---\n\n"))
    }

    private func respond(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        let out = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { throw SummaryError.empty }
        return out
    }

    static func chunk(_ text: String, maxWords: Int) -> [String] {
        let lines = text.split(separator: "\n").map(String.init)
        var chunks: [String] = []
        var current: [String] = []
        var count = 0
        for line in lines {
            let w = line.split(separator: " ").count
            if count + w > maxWords, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
                count = 0
            }
            current.append(line)
            count += w
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks.isEmpty ? [text] : chunks
    }
}

// MARK: - Claude API

struct ClaudeBackend {
    let apiKey: String
    static let model = "claude-opus-5-5"

    func summarize(_ text: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 8000,
            "system": Summarizer.instructions,
            "fallbacks": "default",
            "messages": [["role": "user", "content": "Transkript:\n\n" + text]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SummaryError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SummaryError.empty }
        if json["stop_reason"] as? String == "refusal" { throw SummaryError.refused }
        let content = json["content"] as? [[String: Any]] ?? []
        let out = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { throw SummaryError.empty }
        return out
    }
}

// MARK: - Claude Code (Abo)

/// Nutzt die installierte Claude-Code-Kommandozeile im Print-Modus. Läuft über das Claude-Abo,
/// ohne API-Schlüssel. Werkzeuge sind abgeschaltet, die Sitzung wird nicht gespeichert.
struct ClaudeCodeBackend {
    static var path: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { path != nil }

    func summarize(_ text: String) async throws -> String {
        guard let exe = Self.path else { throw SummaryError.unavailable }
        let input = "Transkript:\n\n" + text
        return try await Self.run(exe, arguments: [
            "-p", "--output-format", "text", "--no-session-persistence",
            "--tools", "", "--system-prompt", Summarizer.instructions,
        ], stdin: input)
    }

    private static func run(_ exe: String, arguments: [String], stdin input: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: exe)
                proc.arguments = arguments
                proc.currentDirectoryURL = Storage.root
                var env = ProcessInfo.processInfo.environment
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                env["HOME"] = env["HOME"] ?? home
                env["USER"] = env["USER"] ?? NSUserName()
                env["PATH"] = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:\(home)/.local/bin:" + (env["PATH"] ?? "")
                // Keine Vererbung einer laufenden Claude-Code-Sitzung.
                for key in env.keys where key.hasPrefix("CLAUDE") { env[key] = nil }
                proc.environment = env

                let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
                proc.standardInput = inPipe
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do { try proc.run() } catch {
                    cont.resume(throwing: SummaryError.claudeCode("Start fehlgeschlagen – \(error.localizedDescription)"))
                    return
                }
                inPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inPipe.fileHandleForWriting.close()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let out = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let err = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus != 0 {
                    let detail = (err.isEmpty ? out : err).split(separator: "\n").last.map(String.init) ?? "Exit \(proc.terminationStatus)"
                    cont.resume(throwing: SummaryError.claudeCode(detail))
                } else if out.isEmpty || out.hasPrefix("Not logged in") {
                    cont.resume(throwing: SummaryError.claudeCode(out.isEmpty ? "leere Antwort" : "nicht angemeldet – im Terminal „claude“ starten und /login ausführen"))
                } else {
                    cont.resume(returning: out)
                }
            }
        }
    }
}

// MARK: - Keychain

enum KeychainHelper {
    private static let service = "de.felixsiebrasse.klar"

    static func read(account: String) -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(account: String, value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
