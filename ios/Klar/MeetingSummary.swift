import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Zusammenfassung nach dem Meeting über Apple Intelligence – auf dem Gerät, ohne Internet.
/// Gibt es nur auf iPhones mit Apple Intelligence (ab iPhone 15 Pro, iOS 26, eingeschaltet).
@MainActor
final class MeetingSummary: ObservableObject {
    static let shared = MeetingSummary()

    @Published private(set) var busy: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]

    static let instructions = """
    Du fasst Meeting-Transkripte zusammen. Antworte in der Sprache des Transkripts. Nutze ausschließlich \
    Informationen aus dem Transkript, erfinde nichts. Gliedere so:
    Kurzfassung (3–5 Sätze)
    Themen (Stichpunkte)
    Entscheidungen (Stichpunkte oder „Keine“)
    Aufgaben (Stichpunkte: wer macht was bis wann, oder „Keine“)
    Offene Fragen (Stichpunkte oder „Keine“)
    """

    /// Ist auf diesem iPhone eine Zusammenfassung möglich? Sonst der Grund.
    var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible):
                return "Zusammenfassungen brauchen ein iPhone mit Apple Intelligence (ab iPhone 15 Pro)."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Für Zusammenfassungen bitte Apple Intelligence in den iPhone-Einstellungen einschalten."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence wird noch eingerichtet. Später noch einmal versuchen."
            default:
                return "Apple Intelligence ist gerade nicht verfügbar."
            }
        }
        #endif
        return "Zusammenfassungen brauchen iOS 26 mit Apple Intelligence."
    }

    func summarize(_ id: UUID) {
        guard !busy.contains(id), let record = MeetingStore.shared.record(id), !record.lines.isEmpty else { return }
        if let reason = unavailableReason { errors[id] = reason; return }
        busy.insert(id)
        errors[id] = nil
        Task {
            defer { busy.remove(id) }
            do {
                let text = try await Self.summarize(text: record.lines.map(\.text).joined(separator: "\n"))
                guard var latest = MeetingStore.shared.record(id) else { return }
                latest.summary = text
                MeetingStore.shared.upsert(latest)
            } catch {
                errors[id] = "Zusammenfassung fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    /// Das Modell hat ein kleines Kontextfenster: lange Transkripte erst abschnittsweise, dann gesamt.
    private static func summarize(text: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let chunks = chunk(text, maxWords: 900)
            if chunks.count == 1 { return try await respond(instructions, "Transkript:\n\n" + chunks[0]) }
            var partials: [String] = []
            for (i, c) in chunks.enumerated() {
                partials.append(try await respond(
                    "Fasse einen Abschnitt eines Meeting-Transkripts in seiner Sprache als knappe Stichpunkte zusammen: Themen, Entscheidungen, Aufgaben, offene Fragen. Erfinde nichts.",
                    "Abschnitt \(i + 1) von \(chunks.count):\n\n" + c))
            }
            return try await respond(instructions,
                "Teilzusammenfassungen eines Meetings in zeitlicher Reihenfolge. Führe sie zu einer Gesamtzusammenfassung zusammen:\n\n"
                + partials.joined(separator: "\n\n---\n\n"))
        }
        #endif
        throw CocoaError(.featureUnsupported)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func respond(_ instructions: String, _ prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif

    nonisolated static func chunk(_ text: String, maxWords: Int) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var count = 0
        for line in text.split(separator: "\n").map(String.init) {
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
