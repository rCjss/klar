import AVFoundation
import UIKit

/// Ein Abschnitt eines Meeting-Transkripts mit Zeitmarke ab Beginn.
struct MeetingLine: Codable, Equatable, Identifiable {
    var id = UUID()
    var offset: TimeInterval
    var text: String
}

struct MeetingRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var date: Date
    var duration: TimeInterval = 0
    var engine: String
    var lines: [MeetingLine] = []
    var summary: String?

    /// Transkript als Text mit Zeitmarken, z. B. zum Teilen.
    var transcript: String {
        lines.map { "[\(Meeting.clock($0.offset))] \($0.text)" }.joined(separator: "\n")
    }

    var shareText: String {
        var parts = [title, ""]
        if let summary, !summary.isEmpty { parts += [summary, "", "Transkript", ""] }
        parts.append(transcript)
        return parts.joined(separator: "\n")
    }
}

/// Gespeicherte Meetings, lokal in der App.
@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()
    @Published private(set) var items: [MeetingRecord] = []

    private static let file: URL = Files.history.deletingLastPathComponent().appendingPathComponent("meetings.json")

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let decoded = try? JSONDecoder().decode([MeetingRecord].self, from: data) {
            items = decoded
        }
    }

    func upsert(_ record: MeetingRecord) {
        if let i = items.firstIndex(where: { $0.id == record.id }) { items[i] = record } else { items.insert(record, at: 0) }
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func record(_ id: UUID) -> MeetingRecord? { items.first { $0.id == id } }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.file, options: [.atomic, .completeFileProtection])
    }
}

/// Nimmt ein Gespräch über das Mikrofon auf und transkribiert es fortlaufend. Läuft weiter, wenn der
/// Bildschirm gesperrt wird (Hintergrundmodus „Audio“). Den Ton anderer Apps (Zoom, Telefon) gibt iOS
/// nicht frei – aufgenommen wird, was das Mikrofon hört.
@MainActor
final class Meeting: ObservableObject {
    static let shared = Meeting()

    enum Phase: Equatable { case idle, preparing, recording, finishing, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var current: MeetingRecord?
    @Published private(set) var partial = ""
    @Published private(set) var status = ""
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private var backend: Backend?
    private var started = Date()
    private var ticker: Task<Void, Never>?
    private var saver: Task<Void, Never>?
    private var interruption: NSObjectProtocol?

    var isActive: Bool { phase == .preparing || phase == .recording || phase == .finishing }

    func start() async {
        guard !isActive, !Dictation.shared.isActive else { return }
        phase = .preparing
        partial = ""
        status = ""
        guard await Dictation.requestMicrophone() else {
            phase = .failed("Kein Mikrofonzugriff. Bitte in den iPhone-Einstellungen unter Klar erlauben.")
            return
        }
        let backend: Backend
        switch await Recognition.makeBackend(status: { [weak self] in self?.status = $0 }) {
        case .success(let b): backend = b
        case .failure(let problem): phase = .failed(problem.message); return
        }
        status = ""

        let now = Date()
        let record = MeetingRecord(title: "Meeting " + Self.titleFormat.string(from: now), date: now,
                                   engine: AppSettings.shared.engineLabel)
        current = record
        started = now
        elapsed = 0
        backend.onCommitted = { [weak self] text in self?.append(text) }
        backend.onPartial = { [weak self] text in self?.partial = text }

        do {
            let session = AVAudioSession.sharedInstance()
            // .playAndRecord + Lautsprecher: läuft auch neben einem Telefonat auf Lautsprecher weiter.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw Dictation.DictationError.noInput }
            input.removeTap(onBus: 0)
            let sink = backend
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                sink.append(buffer)
                let level = Dictation.rms(buffer)
                Task { @MainActor in self?.level = level }
            }
            engine.prepare()
            try engine.start()
            try backend.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            phase = .failed("Mikrofon lässt sich nicht starten: \(error.localizedDescription)")
            current = nil
            return
        }
        self.backend = backend
        RecognizerHost.shared.keepLoaded = true
        phase = .recording
        UIApplication.shared.isIdleTimerDisabled = true
        // Ein Anruf oder Siri unterbricht die Aufnahme – dann wird sauber beendet.
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                              object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in self?.stop() }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.started)
            }
        }
        // Zwischenstände sichern, damit bei einem Absturz nichts verloren geht.
        saver = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, var record = self.current else { return }
                record.duration = Date().timeIntervalSince(self.started)
                MeetingStore.shared.upsert(record)
            }
        }
    }

    func stop() {
        guard phase == .recording, let backend else { return }
        phase = .finishing
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        ticker?.cancel()
        saver?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        level = 0
        UIApplication.shared.isIdleTimerDisabled = false
        let duration = Date().timeIntervalSince(started)
        backend.finish { [weak self] in
            guard let self else { return }
            self.backend = nil
            RecognizerHost.shared.keepLoaded = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.partial = ""
            self.phase = .idle
            guard var record = self.current else { return }
            record.duration = duration
            if record.lines.isEmpty {
                MeetingStore.shared.remove(record.id)
                self.status = "Nichts erkannt."
                self.current = nil
                return
            }
            MeetingStore.shared.upsert(record)
            self.current = record
            MeetingSummary.shared.summarize(record.id)
        }
    }

    /// Ansicht des zuletzt beendeten Meetings schließen.
    func dismissLast() {
        guard !isActive else { return }
        current = nil
        status = ""
        if case .failed = phase { phase = .idle }
    }

    private func append(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, current != nil else { return }
        current!.lines.append(MeetingLine(offset: Date().timeIntervalSince(started), text: t))
    }

    nonisolated static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static let titleFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "d. MMM, HH:mm"
        return f
    }()
}
