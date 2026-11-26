import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = LocalModels.store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Einstellungen").font(Theme.title).foregroundColor(Theme.ink)
                    Spacer()
                    TextButton(title: "Fertig", prominent: true) { dismiss() }
                }
                .padding(.top, 24)
                .padding(.bottom, 36)

                SectionLabel(text: "Sprache")
                ForEach(SpeechLanguage.all) { language in
                    ChoiceRow(title: language.name, selected: settings.localeIdentifier == language.id) {
                        settings.localeIdentifier = language.id
                    }
                }
                Spacer().frame(height: 36)

                SectionLabel(text: "Erkennung")
                ChoiceRow(title: "Apple", detail: "im System", selected: settings.localModel == nil) {
                    settings.engine = AppSettings.apple
                }
                ForEach(SpeechModels.all) { model in
                    ChoiceRow(title: model.label, detail: detail(model), selected: settings.engine == model.id) {
                        settings.engine = model.id
                    }
                }
                Text(note)
                    .font(Theme.small).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                if let model = settings.localModel, model.supports(languageCode: settings.language.code) {
                    HStack(spacing: 24) {
                        if store.activeID == model.id {
                            Text("Wird geladen … \(Int(store.progress * 100)) %").font(Theme.body).foregroundColor(Theme.ink)
                                .padding(.vertical, 8)
                        } else if store.isDownloaded(model) {
                            TextButton(title: "Modell löschen") { store.remove(model) }
                        } else {
                            TextButton(title: "Modell laden (\(model.sizeLabel))", prominent: true) {
                                Task { await store.ensure(model) }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                if let error = store.error {
                    Text(error).font(Theme.small).foregroundColor(Theme.ink).padding(.top, 6)
                }
                Spacer().frame(height: 36)

                SectionLabel(text: "Nach dem Diktat")
                ChoiceRow(title: "Text automatisch kopieren", selected: settings.copyAfterDictation) {
                    settings.copyAfterDictation.toggle()
                }
                Spacer().frame(height: 36)

                Text("Alle Modelle laufen lokal auf dem iPhone; der Ton verlässt das Gerät nicht. Nur beim ersten Mal wird das gewählte Modell von Hugging Face geladen.")
                    .font(Theme.small).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(Theme.small).foregroundColor(Theme.faint)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 28)
        }
        .background(Theme.paper.ignoresSafeArea())
    }

    private func detail(_ model: SpeechModel) -> String {
        if store.activeID == model.id { return "\(Int(store.progress * 100)) %" }
        if store.isDownloaded(model) { return model.sizeLabel + " · geladen" }
        return model.sizeLabel
    }

    private var note: String {
        let language = settings.language
        guard let model = settings.localModel else {
            return "Apples Spracherkennung. Der Text erscheint schon beim Sprechen."
        }
        if !model.supports(languageCode: language.code) {
            return "\(model.label) kennt kein \(language.name). Für \(language.name) bitte ein Whisper-Modell wählen."
        }
        switch model.id {
        case SpeechModels.whisperLargeV3.id:
            return "Das genaueste Modell. Braucht viel Arbeitsspeicher – empfohlen ab iPhone 15 Pro. Der Text erscheint nach jeder Sprechpause."
        case SpeechModels.parakeetV3.id:
            return "Sehr schnell, mit Satzzeichen. Erkennt 25 europäische Sprachen von selbst, aber kein Türkisch."
        default:
            return "Fast so genau wie Large-v3, aber deutlich schneller. Der Text erscheint nach jeder Sprechpause."
        }
    }
}
