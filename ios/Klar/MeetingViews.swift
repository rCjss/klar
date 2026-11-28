import SwiftUI

/// Meeting: Gespräch im Raum aufnehmen, fortlaufend transkribieren, danach zusammenfassen.
struct MeetingPane: View {
    @ObservedObject private var meeting = Meeting.shared
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var summary = MeetingSummary.shared
    @ObservedObject private var settings = AppSettings.shared

    /// Nach dem Beenden: das gespeicherte Meeting (mit Zusammenfassung, sobald fertig).
    private var finished: MeetingRecord? {
        guard !meeting.isActive, let id = meeting.current?.id else { return nil }
        return store.record(id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let finished {
                MeetingDetail(id: finished.id, embedded: true)
            } else {
                live
            }
            Hairline()
            footer
        }
    }

    private var live: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if let lines = meeting.current?.lines, !lines.isEmpty {
                        ForEach(lines) { line in LineRow(line: line) }
                    } else {
                        Text(placeholder).font(Theme.text).foregroundColor(Theme.faint)
                    }
                    if !meeting.partial.isEmpty {
                        Text(meeting.partial).font(Theme.body).foregroundColor(Theme.muted)
                    }
                    if case .failed(let message) = meeting.phase {
                        Text(message).font(Theme.small).foregroundColor(Theme.ink)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 28)
                .textSelection(.enabled)
            }
            .onChange(of: meeting.current?.lines.count) { _, _ in
                withAnimation { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var placeholder: String {
        switch meeting.phase {
        case .preparing: return meeting.status.isEmpty ? "Einen Moment …" : meeting.status
        case .recording: return "Hört zu. Der Text erscheint nach jeder Sprechpause."
        default:
            return "Legt das iPhone auf den Tisch und startet das Meeting. Klar schreibt mit – auch bei gesperrtem Bildschirm."
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(settings.language.name) · \(settings.engineLabel)")
                    .font(Theme.small).foregroundColor(Theme.muted)
                Spacer()
                if meeting.phase == .recording || meeting.phase == .finishing {
                    Text(Meeting.clock(meeting.elapsed)).font(Theme.small.monospacedDigit()).foregroundColor(Theme.ink)
                } else if !meeting.status.isEmpty && meeting.phase != .preparing {
                    Text(meeting.status).font(Theme.small).foregroundColor(Theme.muted)
                }
            }
            Button(action: toggle) {
                Text(mainTitle)
                    .font(Theme.font(22, .regular))
                    .foregroundColor(Theme.paper)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Theme.ink.opacity(meeting.phase == .finishing ? 0.5 : 1))
                    .overlay(alignment: .bottom) {
                        if meeting.phase == .recording {
                            Rectangle().fill(Theme.paper.opacity(0.6))
                                .frame(width: CGFloat(min(1, meeting.level * 12)) * 240, height: 2)
                                .padding(.bottom, 10)
                                .animation(.linear(duration: 0.08), value: meeting.level)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(meeting.phase == .finishing || meeting.phase == .preparing)
            if let finished {
                HStack(spacing: 24) {
                    ShareLink(item: finished.shareText) {
                        Text("Teilen").font(Theme.body).foregroundColor(Theme.ink).padding(.vertical, 8)
                    }
                    TextButton(title: "Kopieren", prominent: true) { UIPasteboard.general.string = finished.shareText }
                    Spacer()
                    TextButton(title: "Schließen") { meeting.dismissLast() }
                }
            } else {
                Text("Aufgenommen wird, was das Mikrofon hört. Den Ton von Zoom, Teams oder Telefonaten gibt iOS anderen Apps nicht frei – dafür auf Lautsprecher stellen.")
                    .font(Theme.small).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 18)
    }

    private var mainTitle: String {
        switch meeting.phase {
        case .recording: return "Meeting beenden"
        case .preparing: return "Startet …"
        case .finishing: return "Wird abgeschlossen …"
        default: return "Meeting starten"
        }
    }

    private func toggle() {
        if meeting.phase == .recording { meeting.stop() } else { Task { await meeting.start() } }
    }
}

struct LineRow: View {
    let line: MeetingLine
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Meeting.clock(line.offset)).font(Theme.small.monospacedDigit()).foregroundColor(Theme.muted)
                .frame(width: 44, alignment: .leading)
            Text(line.text).font(Theme.body).foregroundColor(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Ein gespeichertes Meeting: Zusammenfassung und Transkript.
struct MeetingDetail: View {
    let id: UUID
    var embedded = false
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var summary = MeetingSummary.shared

    var body: some View {
        if let record = store.record(id) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(record.title).font(embedded ? Theme.text : Theme.title).foregroundColor(Theme.ink)
                    Text("\(Meeting.clock(record.duration)) · \(record.engine)")
                        .font(Theme.small).foregroundColor(Theme.muted).padding(.top, 4)
                    Spacer().frame(height: 28)

                    SectionLabel(text: "Zusammenfassung")
                    if summary.busy.contains(id) {
                        Text("Wird erstellt …").font(Theme.body).foregroundColor(Theme.muted)
                    } else if let text = record.summary, !text.isEmpty {
                        Text(text).font(Theme.body).foregroundColor(Theme.ink)
                    } else {
                        if let error = summary.errors[id] {
                            Text(error).font(Theme.small).foregroundColor(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        TextButton(title: "Zusammenfassen", prominent: true) { summary.summarize(id) }
                    }
                    Spacer().frame(height: 28)

                    SectionLabel(text: "Transkript")
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(record.lines) { LineRow(line: $0) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, embedded ? 28 : 0)
                .textSelection(.enabled)
            }
        } else {
            Text("Meeting nicht gefunden.").font(Theme.body).foregroundColor(Theme.muted)
        }
    }
}

/// Alle gespeicherten Meetings.
struct MeetingListView: View {
    @ObservedObject private var store = MeetingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Meetings").font(Theme.title).foregroundColor(Theme.ink)
                    Spacer()
                    TextButton(title: "Fertig", prominent: true) { dismiss() }
                }
                .padding(.top, 24).padding(.bottom, 20).padding(.horizontal, 28)

                if store.items.isEmpty {
                    Text("Noch keine Meetings.").font(Theme.body).foregroundColor(Theme.muted).padding(.horizontal, 28)
                    Spacer()
                } else {
                    List {
                        ForEach(store.items) { item in
                            Button { path.append(item.id) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title).font(Theme.body).foregroundColor(Theme.ink)
                                    Text("\(Meeting.clock(item.duration)) · \(item.lines.count) Abschnitte"
                                         + (item.summary == nil ? "" : " · zusammengefasst"))
                                        .font(Theme.small).foregroundColor(Theme.muted)
                                }
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.paper)
                            .listRowSeparatorTint(Theme.line)
                        }
                        .onDelete { offsets in
                            offsets.map { store.items[$0].id }.forEach(store.remove)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    Hairline()
                    Text("Antippen öffnet, nach links wischen löscht.")
                        .font(Theme.small).foregroundColor(Theme.muted)
                        .padding(.horizontal, 28).padding(.vertical, 12)
                }
            }
            .background(Theme.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        TextButton(title: "Zurück") { path.removeLast() }
                        Spacer()
                        if let record = store.record(id) {
                            ShareLink(item: record.shareText) {
                                Text("Teilen").font(Theme.body).foregroundColor(Theme.ink).padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(.top, 12).padding(.bottom, 16)
                    MeetingDetail(id: id)
                }
                .padding(.horizontal, 28)
                .background(Theme.paper.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}
