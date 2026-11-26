import KlarSpeech
import SwiftUI

/// Einstellungen → Sprache: Wahl der Erkennung – Apple oder eines der lokalen Modelle.
@MainActor struct SpeechEngineSettings: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var store = LocalModels.store

    private var usesLocal: Bool { settings.speechEngine == SpeechEngine.whisper.rawValue }
    private var model: SpeechModel { SpeechModels.find(settings.whisperModel) }
    private var language: SpeechLanguage { SpeechLanguage.find(settings.localeIdentifier) }

    /// Ein lokales Modell ist gewählt, fehlt und es lädt gerade nichts.
    private var needsDownload: Bool { usesLocal && store.activeID == nil && !store.isDownloaded(model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Erkennung").font(Theme.body).foregroundColor(Theme.ink)
            row(title: "Apple", detail: "im System", selected: !usesLocal) {
                settings.speechEngine = SpeechEngine.apple.rawValue
            }
            ForEach(SpeechModels.all) { candidate in
                row(title: candidate.label, detail: detail(for: candidate),
                    selected: usesLocal && settings.whisperModel == candidate.id) {
                    settings.speechEngine = SpeechEngine.whisper.rawValue
                    settings.whisperModel = candidate.id
                    load()
                }
            }
            Text(note)
                .font(Theme.small).foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            if needsDownload && model.supports(languageCode: language.code) {
                PlainTextButton(title: "Modell laden", prominent: true) { load() }
            }
        }
    }

    private func row(title: String, detail: String, selected: Bool, action: @escaping @MainActor () -> Void) -> some View {
        HStack(spacing: 0) {
            PlainTextButton(title: (selected ? "● " : "○ ") + title, prominent: selected, action: action)
                .frame(width: 220, alignment: .leading)
            Text(detail).font(Theme.small).foregroundColor(Theme.muted)
        }
    }

    private func detail(for candidate: SpeechModel) -> String {
        if store.activeID == candidate.id { return "wird geladen … \(Int(store.progress * 100)) %" }
        if store.isDownloaded(candidate) { return candidate.sizeLabel + " · geladen" }
        return candidate.sizeLabel
    }

    private var note: String {
        guard usesLocal else {
            return "Apples Spracherkennung, lokal auf dem Gerät. Der Text erscheint schon beim Sprechen. Gilt für Diktat und Meetings."
        }
        if !model.supports(languageCode: language.code) {
            return "\(model.label) kennt kein \(language.name). Für \(language.name) bitte ein Whisper-Modell wählen."
        }
        let about: String
        switch model.id {
        case SpeechModels.whisperLargeV3.id:
            about = "Das genaueste Whisper-Modell, braucht aber am meisten Zeit und Speicher."
        case SpeechModels.parakeetV3.id:
            about = "Sehr schnell, mit Satzzeichen. Kennt 25 europäische Sprachen (kein Türkisch) und erkennt sie selbst."
        default:
            about = "Fast so genau wie Large-v3, aber deutlich schneller."
        }
        let state: String
        if store.activeID == model.id {
            state = ""
        } else if store.isDownloaded(model) {
            state = " Bereit."
        } else if let error = store.error {
            state = " " + error
        } else {
            state = " Wird einmalig geladen (\(model.sizeLabel))."
        }
        return about + " Läuft lokal auf dem Mac, der Text erscheint nach jeder Sprechpause." + state
    }

    private func load() {
        let wanted = model
        guard wanted.supports(languageCode: language.code) else { return }
        Task {
            if await LocalModels.store.ensure(wanted) { WhisperEngine.warmUpIfSelected() }
        }
    }
}
