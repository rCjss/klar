import SwiftUI

/// Einstellungen → Sprache: Wahl zwischen Apples Spracherkennung und Whisper, samt Whisper-Modell.
@MainActor struct SpeechEngineSettings: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var models = WhisperModelStore.shared

    private var usesWhisper: Bool { settings.speechEngine == SpeechEngine.whisper.rawValue }
    private var model: WhisperModel { WhisperModel.find(settings.whisperModel) }

    /// Whisper ist gewählt, das Modell fehlt und es lädt gerade nichts.
    private var needsDownload: Bool { usesWhisper && models.activeID == nil && !model.isDownloaded }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Erkennung über").font(Theme.body).foregroundColor(Theme.ink)
                ForEach(SpeechEngine.allCases, id: \.self) { engine in
                    PlainTextButton(title: engine.label, prominent: settings.speechEngine == engine.rawValue) {
                        settings.speechEngine = engine.rawValue
                        if engine == .whisper { load() }
                    }
                }
            }
            if usesWhisper {
                HStack(spacing: 12) {
                    Text("Modell").font(Theme.body).foregroundColor(Theme.ink)
                    ForEach(WhisperModel.all) { candidate in
                        PlainTextButton(title: candidate.label, prominent: settings.whisperModel == candidate.id) {
                            settings.whisperModel = candidate.id
                            load()
                        }
                    }
                }
            }
            Text(note)
                .font(Theme.small).foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if needsDownload {
                PlainTextButton(title: "Modell laden", prominent: true) { load() }
            }
        }
    }

    private var note: String {
        guard usesWhisper else {
            return "Apples Spracherkennung, lokal auf dem Gerät. Der Text erscheint schon beim Sprechen. Gilt für Diktat und Meetings."
        }
        let name = "Modell „\(model.label)“ (\(model.detail))"
        let state: String
        if models.activeID == model.id {
            state = "\(name) wird geladen … \(Int(models.progress * 100)) %"
        } else if model.isDownloaded {
            state = "\(name) ist bereit."
        } else if let error = models.error {
            state = error
        } else {
            state = "\(name) wird einmalig geladen."
        }
        return "Whisper, ebenfalls lokal auf dem Gerät. Der Text erscheint nach jeder Sprechpause. Gilt für Diktat und Meetings. " + state
    }

    private func load() {
        let wanted = model
        Task {
            if await WhisperModelStore.shared.ensure(wanted) { WhisperEngine.warmUpIfSelected() }
        }
    }
}
