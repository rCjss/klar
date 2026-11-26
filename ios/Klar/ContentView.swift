import SwiftUI

struct ContentView: View {
    @ObservedObject private var dictation = Dictation.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showSettings = false
    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline().padding(.top, 16)
            ScrollView(showsIndicators: false) {
                transcript
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 28)
            }
            Hairline()
            footer
        }
        .padding(.horizontal, 28)
        .background(Theme.paper.ignoresSafeArea())
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showHistory) { HistoryView() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Klar").font(Theme.title).foregroundColor(Theme.ink)
            Spacer()
            TextButton(title: "Verlauf") { showHistory = true }
                .padding(.trailing, 18)
            TextButton(title: "Einstellungen") { showSettings = true }
        }
        .padding(.top, 12)
    }

    @ViewBuilder private var transcript: some View {
        let shown = [dictation.text, dictation.partial].filter { !$0.isEmpty }.joined(separator: " ")
        VStack(alignment: .leading, spacing: 16) {
            if shown.isEmpty {
                Text(placeholder)
                    .font(Theme.text)
                    .foregroundColor(Theme.faint)
            } else {
                Text(dictation.text)
                    .font(Theme.text)
                    .foregroundColor(Theme.ink)
                + Text(dictation.partial.isEmpty ? "" : (dictation.text.isEmpty ? "" : " ") + dictation.partial)
                    .font(Theme.text)
                    .foregroundColor(Theme.muted)
            }
            if case .failed(let message) = dictation.phase {
                Text(message).font(Theme.small).foregroundColor(Theme.ink)
            }
        }
        .textSelection(.enabled)
    }

    private var placeholder: String {
        switch dictation.phase {
        case .preparing: return dictation.status.isEmpty ? "Einen Moment …" : dictation.status
        case .listening: return "Sprich jetzt."
        default: return "Antippen und sprechen."
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(settings.language.name) · \(settings.engineLabel)")
                    .font(Theme.small).foregroundColor(Theme.muted)
                Spacer()
                if !dictation.status.isEmpty && dictation.phase != .preparing {
                    Text(dictation.status).font(Theme.small).foregroundColor(Theme.muted)
                }
            }
            HStack(alignment: .center, spacing: 0) {
                Button(action: { dictation.toggle() }) {
                    Text(mainTitle)
                        .font(Theme.font(22, .regular))
                        .foregroundColor(Theme.paper)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(Theme.ink.opacity(dictation.phase == .finishing ? 0.5 : 1))
                        .overlay(alignment: .bottom) {
                            // Pegel als feine Linie unter dem Knopf
                            if dictation.phase == .listening {
                                Rectangle().fill(Theme.paper.opacity(0.6))
                                    .frame(width: CGFloat(min(1, dictation.level * 12)) * 240, height: 2)
                                    .padding(.bottom, 10)
                                    .animation(.linear(duration: 0.08), value: dictation.level)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(dictation.phase == .finishing || dictation.phase == .preparing)
                .accessibilityLabel(mainTitle)
            }
            HStack(spacing: 24) {
                TextButton(title: "Kopieren", prominent: !dictation.text.isEmpty) {
                    UIPasteboard.general.string = dictation.text
                }
                .disabled(dictation.text.isEmpty || dictation.isActive)
                ShareLink(item: dictation.text) {
                    Text("Teilen").font(Theme.body)
                        .foregroundColor(dictation.text.isEmpty ? Theme.muted : Theme.ink)
                        .padding(.vertical, 8)
                }
                .disabled(dictation.text.isEmpty || dictation.isActive)
                Spacer()
                TextButton(title: "Leeren") { dictation.clear() }
                    .disabled(dictation.text.isEmpty || dictation.isActive)
            }
        }
        .padding(.vertical, 18)
    }

    private var mainTitle: String {
        switch dictation.phase {
        case .listening: return "Fertig"
        case .preparing: return "Startet …"
        case .finishing: return "Wird erkannt …"
        default: return "Diktieren"
        }
    }
}
