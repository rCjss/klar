import Foundation

struct DictationRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
    var engine: String
}

/// Die letzten Diktate, lokal in der App gespeichert.
@MainActor
final class History: ObservableObject {
    static let shared = History()
    static let limit = 200

    @Published private(set) var items: [DictationRecord] = []

    private init() {
        if let data = try? Data(contentsOf: Files.history),
           let decoded = try? JSONDecoder().decode([DictationRecord].self, from: data) {
            items = decoded
        }
    }

    func add(_ text: String, engine: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.insert(DictationRecord(date: Date(), text: trimmed, engine: engine), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    func remove(_ record: DictationRecord) {
        items.removeAll { $0.id == record.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Files.history, options: [.atomic, .completeFileProtection])
    }
}
