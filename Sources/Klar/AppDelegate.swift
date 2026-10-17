import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var clipboardPanel: ClipboardPanel!
    private var mainWindow: NSWindow?
    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        applyDockSetting()
        clipboardPanel = ClipboardPanel()
        ClipboardMonitor.shared.start()
        setupStatusItem()
        registerHotkeys()
        observeSettings()
        #if DEBUG
        // Steuerung per Skript – nur im Debug-Build. Im Release gäbe das jedem lokalen Prozess
        // die Möglichkeit, Diktat (Mikrofon) oder das Panel auszulösen.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("de.felixsiebrasse.klar.toggleClipboard"), object: nil, queue: .main) { _ in
            Task { @MainActor in AppDelegate.shared?.toggleClipboardPanel() }
        }
        dnc.addObserver(forName: Notification.Name("de.felixsiebrasse.klar.showSettings"), object: nil, queue: .main) { _ in
            Task { @MainActor in AppDelegate.shared?.showMainWindow(section: .settings) }
        }
        dnc.addObserver(forName: Notification.Name("de.felixsiebrasse.klar.showAwake"), object: nil, queue: .main) { _ in
            Task { @MainActor in AppDelegate.shared?.showMainWindow(section: .awake); AwakeManager.shared.start(duration: 1800) }
        }
        dnc.addObserver(forName: Notification.Name("de.felixsiebrasse.klar.showGifs"), object: nil, queue: .main) { _ in
            Task { @MainActor in AppDelegate.shared?.clipboardPanel.show(tab: .gifs) }
        }
        dnc.addObserver(forName: Notification.Name("de.felixsiebrasse.klar.toggleDictation"), object: nil, queue: .main) { _ in
            Task { @MainActor in DictationEngine.shared.toggle() }
        }
        #endif
        if !UserDefaults.standard.bool(forKey: "didShowWindowOnce") {
            UserDefaults.standard.set(true, forKey: "didShowWindowOnce")
            showMainWindow(section: .settings)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AwakeManager.shared.releaseLidModeOnQuit()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        refreshStatusIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    func refreshStatusIcon() {
        let name: String
        // Meeting und Aufnahme halten den Mac automatisch wach.
        AwakeManager.shared.setAutoHold(MeetingRecorder.shared.isRunning || ScreenRecorder.shared.isRecording)
        if ScreenRecorder.shared.isRecording { name = "record.circle.fill" }
        else if DictationEngine.shared.isListening { name = "waveform" }
        else if MeetingRecorder.shared.isRunning { name = "waveform.circle" }
        else if AwakeManager.shared.isActive { name = "sun.max" }
        else { name = "circle" }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Klar")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func statusClicked() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Zwischenablage  \(settings.clipboardHotkey.display)", action: #selector(menuClipboard), keyEquivalent: "")
        menu.addItem(withTitle: (DictationEngine.shared.isListening ? "Diktat beenden  " : "Diktat starten  ") + settings.dictationHotkey.display, action: #selector(menuDictation), keyEquivalent: "")
        menu.addItem(withTitle: (MeetingRecorder.shared.isRunning ? "Meeting-Transkription beenden  " : "Meeting transkribieren  ") + settings.meetingHotkey.display, action: #selector(menuMeeting), keyEquivalent: "")
        menu.addItem(withTitle: (ScreenRecorder.shared.isRecording ? "Aufnahme beenden  " : "Bildschirm aufnehmen  ") + settings.recordingHotkey.display, action: #selector(menuRecording), keyEquivalent: "")
        menu.addItem(.separator())
        let awake = AwakeManager.shared
        let awakeItem = NSMenuItem(title: awake.menuTitle + "  " + settings.awakeHotkey.display, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if awake.isActive {
            sub.addItem(withTitle: "Beenden", action: #selector(menuAwakeStop), keyEquivalent: "")
            sub.addItem(.separator())
        }
        let indefinite = sub.addItem(withTitle: "Unbegrenzt", action: #selector(menuAwake(_:)), keyEquivalent: "")
        indefinite.tag = 0
        for (i, d) in AwakeManager.durations.enumerated() {
            let item = sub.addItem(withTitle: d.label, action: #selector(menuAwake(_:)), keyEquivalent: "")
            item.tag = i + 1
        }
        for item in sub.items { item.target = self }
        awakeItem.submenu = sub
        menu.addItem(awakeItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Klar öffnen", action: #selector(menuOpen), keyEquivalent: "")
        menu.addItem(withTitle: "Einstellungen", action: #selector(menuSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.target == nil { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuClipboard() { clipboardPanel.toggle() }
    func toggleClipboardPanel() { clipboardPanel.toggle() }
    @objc private func menuDictation() { DictationEngine.shared.toggle() }
    @objc private func menuMeeting() { MeetingRecorder.shared.toggle(); showMainWindow(section: .meetings) }
    @objc private func menuRecording() { ScreenRecorder.shared.toggle() }
    @objc private func menuAwake(_ sender: NSMenuItem) {
        let d = sender.tag == 0 ? nil : AwakeManager.durations[sender.tag - 1].seconds
        AwakeManager.shared.start(duration: d)
    }
    @objc private func menuAwakeStop() { AwakeManager.shared.stop() }
    @objc private func menuOpen() { showMainWindow() }
    @objc private func menuSettings() { showMainWindow(section: .settings) }

    // MARK: Hotkeys

    private func registerHotkeys() {
        let hk = HotkeyManager.shared
        hk.set(id: HotkeyID.clipboard, hotkey: settings.clipboardHotkey) { [weak self] in self?.clipboardPanel.toggle() }
        hk.set(id: HotkeyID.dictation, hotkey: settings.dictationHotkey,
               onPress: { DictationEngine.shared.hotkeyPressed() },
               onRelease: { DictationEngine.shared.hotkeyReleased() },
               onCancel: { DictationEngine.shared.hotkeyCancelled() })
        hk.set(id: HotkeyID.meeting, hotkey: settings.meetingHotkey) { MeetingRecorder.shared.toggle() }
        hk.set(id: HotkeyID.recording, hotkey: settings.recordingHotkey) { ScreenRecorder.shared.toggle() }
        hk.set(id: HotkeyID.awake, hotkey: settings.awakeHotkey) { AwakeManager.shared.toggle() }
    }

    private var observers: [Any] = []
    private func observeSettings() {
        observers.append(settings.$clipboardHotkey.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.registerHotkeys() } })
        observers.append(settings.$dictationHotkey.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.registerHotkeys() } })
        observers.append(settings.$meetingHotkey.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.registerHotkeys() } })
        observers.append(settings.$recordingHotkey.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.registerHotkeys() } })
        observers.append(settings.$awakeHotkey.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.registerHotkeys() } })
        observers.append(settings.$awakeKeepsDisplay.dropFirst().sink { _ in Task { @MainActor in AwakeManager.shared.refresh() } })
        observers.append(settings.$awakeDuringCapture.dropFirst().sink { _ in Task { @MainActor in AppDelegate.shared?.refreshStatusIcon() } })
        observers.append(settings.$showInDock.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.applyDockSetting() } })
    }

    // MARK: Main window

    let navigation = Navigation()

    func showMainWindow(section: Section? = nil) {
        if let s = section { navigation.section = s }
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.minSize = NSSize(width: 820, height: 540)
            w.backgroundColor = Theme.paperNS
            w.isReleasedWhenClosed = false
            w.center()
            w.contentView = NSHostingView(rootView: MainView().environmentObject(navigation))
            mainWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func applyDockSetting() {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
    }

    // MARK: Login item

    static var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Gibt eine Fehlermeldung zurück, falls macOS die Registrierung ablehnt.
    @discardableResult
    static func setLaunchesAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            NSLog("Klar: Login item: \(error)")
            return error.localizedDescription
        }
    }
}

enum Section: String, CaseIterable, Identifiable {
    case clipboard = "Zwischenablage"
    case dictations = "Diktate"
    case meetings = "Meetings"
    case recordings = "Aufnahmen"
    case awake = "Cocaine"
    case settings = "Einstellungen"
    var id: String { rawValue }
}

final class Navigation: ObservableObject {
    @Published var section: Section = .clipboard
}
