import SwiftUI
import AppKit

@MainActor struct MainView: View {
    @EnvironmentObject var nav: Navigation

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 220)
            Group {
                switch nav.section {
                case .clipboard: ClipboardView()
                case .dictations: DictationsView()
                case .meetings: MeetingsView()
                case .recordings: RecordingsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 24)
            .padding(.trailing, 56)
            .padding(.top, 64)
            .padding(.bottom, 40)
        }
        .background(Theme.paper)
        .ignoresSafeArea()
    }
}

@MainActor struct Sidebar: View {
    @EnvironmentObject var nav: Navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Klar")
                .font(Theme.font(15, .medium))
                .tracking(2)
                .foregroundColor(Theme.ink)
                .padding(.leading, 48)
                .padding(.top, 64)
                .padding(.bottom, 56)
            ForEach(Section.allCases) { s in
                SidebarItem(title: s.rawValue, active: nav.section == s) { nav.section = s }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Text("Jasper Felix Siebrasse").font(Theme.small).foregroundColor(Theme.faint)
                Text("v0.1").font(Theme.small).foregroundColor(Theme.faint)
            }
            .padding(.leading, 48).padding(.bottom, 32)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

@MainActor struct SidebarItem: View {
    let title: String
    let active: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(14, active ? .medium : .regular))
                .foregroundColor(active ? Theme.ink : (hover ? Theme.ink.opacity(0.7) : Theme.muted))
                .padding(.leading, 48)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

@MainActor struct PageTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.title).foregroundColor(Theme.ink)
            if let s = subtitle { Text(s).font(Theme.small).foregroundColor(Theme.muted) }
        }
        .padding(.bottom, 36)
    }
}

// MARK: - Zwischenablage

@MainActor struct ClipboardView: View {
    @ObservedObject var store = ClipboardStore.shared
    @ObservedObject var settings = Settings.shared
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                PageTitle(title: "Zwischenablage", subtitle: "\(settings.clipboardHotkey.display) öffnet das Panel in jeder App.")
                Spacer()
                PlainTextButton(title: "Verlauf leeren") { store.clearUnpinned() }
            }
            UnderlinedField(placeholder: "Suchen", text: $query)
                .padding(.bottom, 8)
            let items = store.ordered.filter { $0.matches(query) }
            if items.isEmpty {
                EmptyNote(text: query.isEmpty ? "Kopiere etwas mit ⌘C – es erscheint hier." : "Keine Treffer.")
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in ClipRow(item: item) }
                    }
                }
            }
        }
    }
}

@MainActor struct ClipRow: View {
    let item: ClipItem
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                if item.pinned {
                    Circle().fill(Theme.ink).frame(width: 6, height: 6).padding(.top, 7)
                } else {
                    Circle().fill(Color.clear).frame(width: 6, height: 6)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if item.kind == .image, let file = item.imageFile,
                       let img = NSImage(contentsOf: Storage.images.appendingPathComponent(file)) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 120).clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Text(item.preview).font(Theme.body).foregroundColor(Theme.ink).lineLimit(3)
                    }
                    HStack(spacing: 10) {
                        Text(Format.relative(item.createdAt))
                        if let app = item.sourceApp { Text(app) }
                    }
                    .font(Theme.small).foregroundColor(Theme.faint)
                }
                Spacer()
                HStack(spacing: 18) {
                    PlainTextButton(title: "Kopieren") { Paster.write(item) }
                    PlainTextButton(title: item.pinned ? "Lösen" : "Anpinnen") { ClipboardStore.shared.togglePin(item.id) }
                    PlainTextButton(title: "Löschen") { ClipboardStore.shared.remove(item.id) }
                }
                .opacity(hover ? 1 : 0)
            }
            .padding(.vertical, 16)
            HairlineDivider()
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

@MainActor struct EmptyNote: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.body).foregroundColor(Theme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - Diktate

@MainActor struct DictationsView: View {
    @ObservedObject var store = DictationStore.shared
    @ObservedObject var engine = DictationEngine.shared
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                PageTitle(title: "Diktate", subtitle: "\(settings.dictationHotkey.display) tippen: Start/Stopp. Halten: sprechen, loslassen, fertig.")
                Spacer()
                PlainTextButton(title: engine.isListening ? "Stopp" : "Diktat starten", prominent: true) { engine.toggle() }
            }
            if store.items.isEmpty {
                EmptyNote(text: "Noch keine Diktate.")
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(store.items) { d in DictationRow(item: d) }
                    }
                }
            }
        }
    }
}

@MainActor struct DictationRow: View {
    let item: Dictation
    @State private var hover = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.text).font(Theme.body).foregroundColor(Theme.ink).lineLimit(hover ? nil : 3)
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        Text(Format.relative(item.createdAt))
                        Text(String(format: "%.0f s", item.duration))
                        if let s = item.usedSnippet { Text("Befehl „\(s)“") }
                    }
                    .font(Theme.small).foregroundColor(Theme.faint)
                }
                Spacer()
                HStack(spacing: 18) {
                    PlainTextButton(title: "Kopieren") { Paster.write(text: item.text) }
                    PlainTextButton(title: "Löschen") { DictationStore.shared.remove(item.id) }
                }
                .opacity(hover ? 1 : 0)
            }
            .padding(.vertical, 16)
            HairlineDivider()
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Meetings

@MainActor struct MeetingsView: View {
    @ObservedObject var store = MeetingStore.shared
    @ObservedObject var recorder = MeetingRecorder.shared
    @ObservedObject var settings = Settings.shared
    @State private var selected: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                PageTitle(title: "Meetings", subtitle: "Systemton und Mikrofon werden getrennt transkribiert – \(settings.meetingHotkey.display)")
                Spacer()
                PlainTextButton(title: recorder.isRunning ? "Transkription beenden" : "Transkription starten", prominent: true) { recorder.toggle() }
            }
            if let e = recorder.errorMessage {
                Text(e).font(Theme.small).foregroundColor(Theme.ink).padding(.bottom, 16)
            }
            if recorder.isRunning, let cur = recorder.current {
                LiveTranscript(transcript: cur, liveMe: recorder.liveMe, liveOthers: recorder.liveOthers)
            } else if let id = selected ?? recorder.lastFinishedID, let m = store.items.first(where: { $0.id == id }) {
                TranscriptDetail(transcript: m) { selected = nil; recorder.lastFinishedID = nil }
            } else if store.items.isEmpty {
                EmptyNote(text: "Noch keine Meetings transkribiert.")
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(store.items) { m in
                            MeetingRow(item: m) { selected = m.id }
                        }
                    }
                }
            }
        }
    }
}

@MainActor struct MeetingRow: View {
    let item: MeetingTranscript
    let open: () -> Void
    @State private var hover = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(Theme.body).foregroundColor(Theme.ink)
                    HStack(spacing: 10) {
                        Text(Format.dateTime.string(from: item.startedAt))
                        if let e = item.endedAt { Text(Format.clock(e.timeIntervalSince(item.startedAt))) }
                        Text("\(item.lines.count) Abschnitte")
                    }
                    .font(Theme.small).foregroundColor(Theme.faint)
                }
                Spacer()
                HStack(spacing: 18) {
                    PlainTextButton(title: "Kopieren") { Paster.write(text: item.plainText) }
                    PlainTextButton(title: "Löschen") { MeetingStore.shared.remove(item.id) }
                }
                .opacity(hover ? 1 : 0)
            }
            .padding(.vertical, 16)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            HairlineDivider()
        }
        .onHover { hover = $0 }
    }
}

@MainActor struct TranscriptDetail: View {
    let transcript: MeetingTranscript
    let back: () -> Void
    @State private var title: String = ""
    @ObservedObject var summarizer = Summarizer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                PlainTextButton(title: "← Zurück", action: back)
                Spacer()
                if summarizer.busy.contains(transcript.id) {
                    Text("Zusammenfassung wird erstellt …").font(Theme.small).foregroundColor(Theme.muted)
                } else {
                    PlainTextButton(title: transcript.summary == nil ? "Zusammenfassen" : "Neu zusammenfassen") {
                        Task { await summarizer.summarize(transcript.id) }
                    }
                }
                if let s = transcript.summary {
                    PlainTextButton(title: "Zusammenfassung kopieren") { Paster.write(text: s) }
                }
                PlainTextButton(title: "Transkript kopieren") { Paster.write(text: transcript.plainText) }
            }
            .padding(.bottom, 24)
            if let e = summarizer.lastError {
                Text(e).font(Theme.small).foregroundColor(Theme.ink).padding(.bottom, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Titel", text: $title, onCommit: { MeetingStore.shared.rename(transcript.id, to: title) })
                .textFieldStyle(.plain).font(Theme.font(18, .light)).foregroundColor(Theme.ink)
                .padding(.bottom, 20)
                .onAppear { title = transcript.title }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let s = transcript.summary {
                        SectionLabel(text: "Zusammenfassung")
                        SummaryView(markdown: s)
                            .padding(.bottom, 36)
                        SectionLabel(text: "Transkript")
                    }
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(transcript.lines) { line in TranscriptLineView(line: line) }
                    }
                }
            }
        }
    }
}

/// Zeigt die Markdown-Zusammenfassung reduziert: Überschriften als Versalien, Punkte als Zeilen.
@MainActor struct SummaryView: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                let line = String(raw).trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") {
                    Text(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).uppercased())
                        .font(Theme.label).tracking(1.6).foregroundColor(Theme.muted)
                        .padding(.top, 14)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                    HStack(alignment: .top, spacing: 10) {
                        Text("–").foregroundColor(Theme.muted)
                        Text(clean(String(line.dropFirst(2)))).foregroundColor(Theme.ink)
                    }
                    .font(Theme.body)
                } else if !line.isEmpty {
                    Text(clean(line)).font(Theme.body).foregroundColor(Theme.ink)
                }
            }
        }
        .textSelection(.enabled)
    }
    private func clean(_ s: String) -> String { s.replacingOccurrences(of: "**", with: "") }
}

@MainActor struct LiveTranscript: View {
    let transcript: MeetingTranscript
    let liveMe: String
    let liveOthers: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(transcript.lines) { line in TranscriptLineView(line: line) }
                    if !liveOthers.isEmpty { TranscriptLineView(line: TranscriptLine(time: 0, speaker: "Andere", text: liveOthers), live: true) }
                    if !liveMe.isEmpty { TranscriptLineView(line: TranscriptLine(time: 0, speaker: "Ich", text: liveMe), live: true) }
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .onChange(of: transcript.lines.count) { _, _ in proxy.scrollTo("end") }
            .onChange(of: liveMe) { _, _ in proxy.scrollTo("end") }
            .onChange(of: liveOthers) { _, _ in proxy.scrollTo("end") }
        }
    }
}

@MainActor struct TranscriptLineView: View {
    let line: TranscriptLine
    var live = false
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(line.speaker).font(Theme.label).foregroundColor(live ? Theme.faint : Theme.ink)
                if !live { Text(Format.clock(line.time)).font(Theme.small).foregroundColor(Theme.faint) }
            }
            .frame(width: 70, alignment: .trailing)
            Text(line.text).font(Theme.body).foregroundColor(live ? Theme.muted : Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Aufnahmen

@MainActor struct RecordingsView: View {
    @ObservedObject var recorder = ScreenRecorder.shared
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                PageTitle(title: "Aufnahmen", subtitle: "Bildschirm mit Systemton – \(settings.recordingHotkey.display). Dateien liegen in Filme/Klar.")
                Spacer()
                PlainTextButton(title: recorder.isRecording ? "Aufnahme beenden" : "Aufnahme starten", prominent: true) { recorder.toggle() }
            }
            if let e = recorder.errorMessage {
                Text(e).font(Theme.small).foregroundColor(Theme.ink).padding(.bottom, 16)
            }
            if recorder.isRecording {
                HStack(spacing: 10) {
                    Circle().fill(Theme.ink).frame(width: 8, height: 8)
                    Text("Aufnahme läuft").font(Theme.body).foregroundColor(Theme.ink)
                }
                .padding(.bottom, 24)
            }
            if recorder.files.isEmpty {
                EmptyNote(text: "Noch keine Aufnahmen.")
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(recorder.files, id: \.self) { url in RecordingRow(url: url) }
                    }
                }
            }
        }
        .onAppear { recorder.reloadFiles() }
    }
}

@MainActor struct RecordingRow: View {
    let url: URL
    @State private var hover = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(url.deletingPathExtension().lastPathComponent).font(Theme.body).foregroundColor(Theme.ink)
                    Text(sizeText).font(Theme.small).foregroundColor(Theme.faint)
                }
                Spacer()
                HStack(spacing: 18) {
                    PlainTextButton(title: "Öffnen") { NSWorkspace.shared.open(url) }
                    PlainTextButton(title: "Im Finder") { ScreenRecorder.shared.reveal(url) }
                    PlainTextButton(title: "Löschen") { ScreenRecorder.shared.delete(url) }
                }
                .opacity(hover ? 1 : 0)
            }
            .padding(.vertical, 16)
            HairlineDivider()
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private var sizeText: String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
