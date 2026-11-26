import SwiftUI

/// Wie auf dem Mac: nur Schwarz und Weiß, Textbuttons, Haarlinien, viel Weißraum, keine Icons.
enum Theme {
    static var paper: Color { Color(uiColor: .systemBackground) }
    static var ink: Color { Color(uiColor: .label) }
    static var muted: Color { ink.opacity(0.45) }
    static var faint: Color { ink.opacity(0.18) }
    static var line: Color { ink.opacity(0.1) }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static let title = font(30, .light)
    static let text = font(20, .light)
    static let body = font(16, .regular)
    static let small = font(13, .regular)
    static let label = font(11, .medium)
}

/// Textbutton ohne Dekoration.
struct TextButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body)
                .foregroundColor(prominent ? Theme.ink : Theme.muted)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Kleine Überschrift in Versalien.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.label)
            .tracking(1.6)
            .foregroundColor(Theme.muted)
            .padding(.bottom, 10)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

/// Auswahlzeile mit Punkt: ● gewählt, ○ nicht gewählt.
struct ChoiceRow: View {
    let title: String
    var detail: String = ""
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) {
                Text((selected ? "●  " : "○  ") + title)
                    .font(Theme.body)
                    .foregroundColor(selected ? Theme.ink : Theme.muted)
                Spacer(minLength: 12)
                Text(detail).font(Theme.small).foregroundColor(Theme.muted)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
