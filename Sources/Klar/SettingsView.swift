import SwiftUI
import AppKit

@MainActor struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var summarizer = Summarizer.shared
    @State private var launchAtLogin = AppDelegate.launchesAtLogin
    @State private var loginError: String?
    @State private var permissionsTick = 0

    private let locales: [(String, String)] = [
        ("de-DE", "Deutsch"), ("en-US", "English (US)"), ("en-GB", "English (UK)"),
        ("fr-FR", "Français"), ("es-ES", "Español"), ("it-IT", "Italiano"),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "Einstellungen")

                SectionLabel(text: "Tastenkürzel")
                HotkeyRow(label: "Zwischenablage öffnen", hotkey: $settings.clipboardHotkey)
                HotkeyRow(label: "Diktat (tippen oder halten)", hotkey: $settings.dictationHotkey)
                HotkeyRow(label: "Meeting transkribieren", hotkey: $settings.meetingHotkey)
                HotkeyRow(label: "Bildschirmaufnahme", hotkey: $settings.recordingHotkey)
                Text("Klicken, dann Kombination drücken. Auch eine einzelne Taste wie die rechte ⌘ oder fn ist möglich – dafür ist die Bedienungshilfen-Freigabe nötig.")
                    .font(Theme.small).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                Spacer().frame(height: 48)

                SectionLabel(text: "Sprache")
                HStack(spacing: 28) {
                    ForEach(locales, id: \.0) { id, name in
                        PlainTextButton(title: name, prominent: settings.localeIdentifier == id) { settings.localeIdentifier = id }
                    }
                }
                .padding(.bottom, 12)
                DotToggle(isOn: $settings.pasteAfterDictation, label: "Diktat direkt in die aktive App einfügen")
                    .padding(.bottom, 14)
                DotToggle(isOn: $settings.recordMicInScreenRecording, label: "Bei Bildschirmaufnahmen auch das Mikrofon aufnehmen")
                Spacer().frame(height: 48)

                SectionLabel(text: "Sprachbefehle")
                Text("Sag nur den Namen („Signatur“) oder mitten im Satz „\(settings.commandPrefix) Signatur“, und der Baustein wird eingefügt. „Neue Zeile“ und „neuer Absatz“ funktionieren immer.")
                    .font(Theme.small).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 20)
                HStack(spacing: 12) {
                    Text("Befehlswort").font(Theme.small).foregroundColor(Theme.muted)
                    TextField("einfügen", text: $settings.commandPrefix)
                        .textFieldStyle(.plain).font(Theme.body).foregroundColor(Theme.ink).frame(width: 160)
                }
                .padding(.bottom, 20)
                ForEach($settings.snippets) { $snippet in
                    SnippetEditor(snippet: $snippet) { settings.snippets.removeAll { $0.id == snippet.id } }
                }
                PlainTextButton(title: "+ Neuer Befehl", prominent: true) {
                    settings.snippets.append(Snippet(trigger: "", text: ""))
                }
                .padding(.top, 8)
                Spacer().frame(height: 48)

                SectionLabel(text: "Zusammenfassung")
                Text("Nach jeder Meeting-Transkription entsteht automatisch eine Zusammenfassung. „Automatisch“ nimmt Claude Code über dein Abo, sonst die Claude-API mit Schlüssel, sonst Apple Intelligence.")
                    .font(Theme.small).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
                DotToggle(isOn: $settings.autoSummarize, label: "Automatisch zusammenfassen")
                    .padding(.bottom, 16)
                HStack(spacing: 12) {
                    Text("Zusammenfassen über").font(Theme.body).foregroundColor(Theme.ink)
                    ForEach(Summarizer.Provider.allCases, id: \.self) { p in
                        PlainTextButton(title: p.label, prominent: settings.summaryProvider == p.rawValue) {
                            settings.summaryProvider = p.rawValue
                        }
                    }
                }
                .padding(.bottom, 10)
                Text("Claude Code: \(summarizer.claudeCodeStatus) · Claude-API: \(summarizer.claudeAPIStatus) · Apple Intelligence: \(summarizer.appleStatus)")
                    .font(Theme.small).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
                HStack(spacing: 12) {
                    Text("Claude-API-Schlüssel").font(Theme.small).foregroundColor(Theme.muted)
                    SecureField("optional", text: $settings.claudeAPIKey)
                        .textFieldStyle(.plain).font(Theme.body).foregroundColor(Theme.ink).frame(width: 320)
                }
                Spacer().frame(height: 48)

                SectionLabel(text: "GIFs")
                Text("Der Reiter „GIFs“ im Zwischenablage-Panel durchsucht Giphy. Ein kostenloser Schlüssel lässt sich unter developers.giphy.com anlegen (App erstellen → API Key).")
                    .font(Theme.small).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
                HStack(spacing: 12) {
                    Text("Giphy-API-Schlüssel").font(Theme.small).foregroundColor(Theme.muted)
                    SecureField("optional", text: $settings.giphyAPIKey)
                        .textFieldStyle(.plain).font(Theme.body).foregroundColor(Theme.ink).frame(width: 320)
                }
                Spacer().frame(height: 48)

                SectionLabel(text: "Berechtigungen")
                PermissionRow(name: "Bedienungshilfen", detail: "zum Einfügen per ⌘V", state: Permissions.accessibility) {
                    _ = Permissions.requestAccessibility(); Permissions.openSettings("Privacy_Accessibility")
                }
                PermissionRow(name: "Mikrofon", detail: "für Diktat und Meetings", state: Permissions.microphone) {
                    Task { _ = await Permissions.requestMicrophone(); permissionsTick += 1 }
                }
                PermissionRow(name: "Spracherkennung", detail: "lokal auf dem Gerät", state: Permissions.speech) {
                    Task { _ = await Permissions.requestSpeech(); permissionsTick += 1 }
                }
                PermissionRow(name: "Bildschirmaufnahme", detail: "für Systemton und Aufnahmen", state: Permissions.screen) {
                    _ = Permissions.requestScreen(); Permissions.openSettings("Privacy_ScreenCapture")
                }
                .id(permissionsTick)
                Spacer().frame(height: 48)

                SectionLabel(text: "Allgemein")
                DotToggle(isOn: $launchAtLogin, label: "Beim Anmelden starten")
                    .onChange(of: launchAtLogin) { _, v in
                        loginError = AppDelegate.setLaunchesAtLogin(v)
                        launchAtLogin = AppDelegate.launchesAtLogin
                    }
                    .padding(.bottom, loginError == nil ? 14 : 6)
                if let e = loginError {
                    Text("Autostart fehlgeschlagen: \(e). Alternativ: Systemeinstellungen → Allgemein → Anmeldeobjekte → „+“ → Klar.")
                        .font(Theme.small).foregroundColor(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 14)
                }
                DotToggle(isOn: $settings.showInDock, label: "Symbol im Dock anzeigen")
                    .padding(.bottom, 14)
                HStack(spacing: 12) {
                    Text("Verlauf behalten").font(Theme.body).foregroundColor(Theme.ink)
                    ForEach([100, 500, 2000], id: \.self) { n in
                        PlainTextButton(title: "\(n)", prominent: settings.historyLimit == n) { settings.historyLimit = n }
                    }
                }
                Spacer().frame(height: 40)
            }
        }
        // Freigaben werden in den Systemeinstellungen erteilt – deshalb regelmäßig neu prüfen,
        // solange die Einstellungen sichtbar sind, und zusätzlich beim Zurückkehren zur App.
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in permissionsTick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissionsTick += 1 }
    }
}

@MainActor struct HotkeyRow: View {
    let label: String
    @Binding var hotkey: Hotkey
    var body: some View {
        HStack {
            Text(label).font(Theme.body).foregroundColor(Theme.ink)
            Spacer()
            HotkeyRecorder(hotkey: $hotkey)
        }
        .padding(.vertical, 10)
        HairlineDivider()
    }
}

@MainActor struct PermissionRow: View {
    let name: String
    let detail: String
    let state: Permissions.State
    let action: () -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(Theme.body).foregroundColor(Theme.ink)
                Text(detail).font(Theme.small).foregroundColor(Theme.faint)
            }
            Spacer()
            switch state {
            case .granted: Text("erteilt").font(Theme.small).foregroundColor(Theme.muted)
            case .denied: PlainTextButton(title: "Freigeben", prominent: true, action: action)
            case .undetermined: PlainTextButton(title: "Anfragen", prominent: true, action: action)
            }
        }
        .padding(.vertical, 10)
        HairlineDivider()
    }
}

@MainActor struct SnippetEditor: View {
    @Binding var snippet: Snippet
    let remove: () -> Void
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Befehl, z. B. Signatur", text: $snippet.trigger)
                    .textFieldStyle(.plain).font(Theme.font(14, .medium)).foregroundColor(Theme.ink)
                Spacer()
                PlainTextButton(title: "Entfernen", action: remove).opacity(hover ? 1 : 0)
            }
            TextEditor(text: $snippet.text)
                .font(Theme.body)
                .foregroundColor(Theme.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 44, maxHeight: 140)
                .padding(.leading, -4)
            HairlineDivider()
        }
        .padding(.vertical, 10)
        .onHover { hover = $0 }
    }
}

/// Klick, dann Tastenkombination drücken.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var hotkey: Hotkey

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.onChange = { hotkey = $0 }
        v.current = hotkey
        return v
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.current = hotkey
        nsView.needsDisplay = true
    }

    final class RecorderView: NSView {
        var onChange: ((Hotkey) -> Void)?
        var current: Hotkey?
        private var recording = false { didSet { needsDisplay = true } }
        private var pendingModifier: UInt32?

        override func flagsChanged(with event: NSEvent) {
            guard recording else { super.flagsChanged(with: event); return }
            let code = UInt32(event.keyCode)
            guard Hotkey.modifierKeyNames[code] != nil else { return }
            if Hotkey.modifierPressed(in: event, keyCode: code) {
                pendingModifier = code
            } else if pendingModifier == code {
                pendingModifier = nil
                accept(Hotkey(keyCode: code, carbonModifiers: 0))
            }
        }

        private func accept(_ hk: Hotkey) {
            current = hk
            onChange?(hk)
            recording = false
            HotkeyManager.shared.resume()
            window?.makeFirstResponder(nil)
        }

        override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 30) }
        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            recording = true
            HotkeyManager.shared.pause()
        }

        override func resignFirstResponder() -> Bool {
            if recording { recording = false; HotkeyManager.shared.resume() }
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            pendingModifier = nil
            if event.keyCode == 53 { recording = false; HotkeyManager.shared.resume(); return }
            if let hk = Hotkey(event: event) { accept(hk) }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return false }
            keyDown(with: event)
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            let text = recording ? "Taste drücken …" : (current?.display ?? "–")
            let color = recording ? Theme.inkNS.withAlphaComponent(0.4) : Theme.inkNS
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: color,
            ]
            let size = text.size(withAttributes: attrs)
            let rect = NSRect(x: bounds.maxX - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            text.draw(in: rect, withAttributes: attrs)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: bounds.maxX - size.width, y: 2))
            line.line(to: NSPoint(x: bounds.maxX, y: 2))
            (recording ? Theme.inkNS : Theme.inkNS.withAlphaComponent(0.15)).setStroke()
            line.lineWidth = 1
            line.stroke()
        }
    }
}
