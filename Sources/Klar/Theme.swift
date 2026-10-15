import SwiftUI
import AppKit

/// Radikal reduzierte Schwarz-Weiß-Palette. Im hellen Modus schwarz auf weiß,
/// im dunklen Modus weiß auf schwarz. Keine weiteren Farben.
enum Theme {
    static let paperNS = NSColor(name: nil) { a in a.isDark ? .black : .white }
    static let inkNS = NSColor(name: nil) { a in a.isDark ? .white : .black }

    static var paper: Color { Color(nsColor: paperNS) }
    static var ink: Color { Color(nsColor: inkNS) }
    static var muted: Color { ink.opacity(0.42) }
    static var faint: Color { ink.opacity(0.18) }
    static var line: Color { ink.opacity(0.08) }
    static var hover: Color { ink.opacity(0.04) }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static let title = font(26, .light)
    static let body = font(14, .regular)
    static let small = font(12, .regular)
    static let label = font(11, .medium)
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// Textbutton ohne jede Dekoration – nur Schrift, die beim Hover dunkler wird.
@MainActor struct PlainTextButton: View {
    let title: String
    var prominent = false
    let action: @MainActor () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: { MainActor.assumeIsolated { action() } }) {
            Text(title)
                .font(Theme.small)
                .foregroundColor(prominent || hovering ? Theme.ink : Theme.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Kleine Überschrift in Versalien mit viel Abstand.
@MainActor struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.label)
            .tracking(1.6)
            .foregroundColor(Theme.muted)
            .padding(.bottom, 14)
    }
}

@MainActor struct HairlineDivider: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
    }
}

/// Minimaler Schalter: ein Kreis, gefüllt oder leer.
@MainActor struct DotToggle: View {
    @Binding var isOn: Bool
    let label: String
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(Theme.ink, lineWidth: 1)
                    .background(Circle().fill(isOn ? Theme.ink : Color.clear))
                    .frame(width: 12, height: 12)
                Text(label).font(Theme.body).foregroundColor(Theme.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Textfeld ohne Rahmen, nur eine Haarlinie darunter.
@MainActor struct UnderlinedField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        VStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .foregroundColor(Theme.ink)
            HairlineDivider()
        }
    }
}
