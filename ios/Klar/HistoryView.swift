import SwiftUI

struct HistoryView: View {
    @ObservedObject private var history = History.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied: UUID?

    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Verlauf").font(Theme.title).foregroundColor(Theme.ink)
                Spacer()
                TextButton(title: "Fertig", prominent: true) { dismiss() }
            }
            .padding(.top, 24)
            .padding(.bottom, 20)
            .padding(.horizontal, 28)

            if history.items.isEmpty {
                Text("Noch keine Diktate.")
                    .font(Theme.body).foregroundColor(Theme.muted)
                    .padding(.horizontal, 28)
                Spacer()
            } else {
                List {
                    ForEach(history.items) { item in
                        Button {
                            UIPasteboard.general.string = item.text
                            copied = item.id
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.text).font(Theme.body).foregroundColor(Theme.ink).lineLimit(6)
                                Text(copied == item.id
                                     ? "Kopiert."
                                     : Self.format.string(from: item.date) + " · " + item.engine)
                                    .font(Theme.small).foregroundColor(Theme.muted)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.paper)
                        .listRowSeparatorTint(Theme.line)
                    }
                    .onDelete { offsets in
                        offsets.map { history.items[$0] }.forEach(history.remove)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                Hairline()
                HStack {
                    Text("Antippen kopiert, nach links wischen löscht.")
                        .font(Theme.small).foregroundColor(Theme.muted)
                    Spacer()
                    TextButton(title: "Alle löschen") { history.clear() }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
            }
        }
        .background(Theme.paper.ignoresSafeArea())
    }
}
