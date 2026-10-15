import Carbon
import AppKit

/// Globale Tastenkürzel über Carbon. Funktioniert ohne Bedienungshilfen-Freigabe
/// und liefert sowohl Drücken als auch Loslassen (für Push-to-Talk).
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    struct Binding {
        var hotkey: Hotkey
        var onPress: @MainActor () -> Void
        var onRelease: @MainActor () -> Void
        var onCancel: @MainActor () -> Void
    }

    private var monitors: [Any] = []
    private var heldModifier: UInt32?

    private var bindings: [UInt32: Binding] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false
    private var paused = false
    private let signature: OSType = 0x4B4C4152 // "KLAR"

    private init() {}

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let handler: EventHandlerUPP = { _, event, _ in
            guard let event = event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let kind = GetEventKind(event)
            Task { @MainActor in
                HotkeyManager.shared.dispatch(id: hkID.id, pressed: kind == UInt32(kEventHotKeyPressed))
            }
            return noErr
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), handler, specs.count, &specs, nil, nil)
        if status != noErr { NSLog("Klar: Hotkey-Handler konnte nicht installiert werden (%d)", status) }
    }

    func set(id: UInt32, hotkey: Hotkey, onPress: @escaping @MainActor () -> Void,
             onRelease: @escaping @MainActor () -> Void = {}, onCancel: @escaping @MainActor () -> Void = {}) {
        installIfNeeded()
        unregister(id: id)
        bindings[id] = Binding(hotkey: hotkey, onPress: onPress, onRelease: onRelease, onCancel: onCancel)
        if !paused { register(id: id) }
        updateModifierMonitors()
    }

    /// Einzelne Modifier-Tasten laufen nicht über Carbon, sondern über Event-Monitore
    /// (benötigen die Bedienungshilfen-Freigabe, wenn eine andere App aktiv ist).
    private func updateModifierMonitors() {
        let needed = bindings.values.contains { $0.hotkey.isModifierOnly }
        if needed && monitors.isEmpty {
            let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
            if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
                Task { @MainActor in self?.handleModifierEvent(e) }
            }) { monitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
                self?.handleModifierEvent(e)
                return e
            }) { monitors.append(l) }
        } else if !needed && !monitors.isEmpty {
            monitors.forEach { NSEvent.removeMonitor($0) }
            monitors.removeAll()
        }
    }

    private func handleModifierEvent(_ event: NSEvent) {
        guard !paused else { return }
        if event.type == .keyDown {
            // Eine andere Taste während des Haltens: das war ein Shortcut, kein Auslöser.
            if let held = heldModifier, let b = bindings.values.first(where: { $0.hotkey.isModifierOnly && $0.hotkey.keyCode == held }) {
                heldModifier = nil
                b.onCancel()
            }
            return
        }
        let code = UInt32(event.keyCode)
        guard let b = bindings.values.first(where: { $0.hotkey.isModifierOnly && $0.hotkey.keyCode == code }) else { return }
        let pressed = Hotkey.modifierPressed(in: event, keyCode: code)
        if pressed {
            heldModifier = code
            b.onPress()
        } else {
            let wasHeld = heldModifier == code
            heldModifier = nil
            if wasHeld { b.onRelease() }
        }
    }

    private func register(id: UInt32) {
        guard let b = bindings[id], !b.hotkey.isModifierOnly else { return }
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(b.hotkey.keyCode, b.hotkey.carbonModifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref = ref { refs[id] = ref }
        else { NSLog("Klar: Hotkey %@ konnte nicht registriert werden (%d)", b.hotkey.display, status) }
    }

    private func unregister(id: UInt32) {
        if let ref = refs[id] { UnregisterEventHotKey(ref); refs[id] = nil }
    }

    /// Während ein neues Kürzel aufgenommen wird, sollen die alten nicht feuern.
    func pause() {
        paused = true
        for id in Array(refs.keys) { unregister(id: id) }
    }

    func resume() {
        paused = false
        for id in bindings.keys { register(id: id) }
    }

    private func dispatch(id: UInt32, pressed: Bool) {
        guard let b = bindings[id] else { return }
        NSLog("Klar: Hotkey %@ %@", b.hotkey.display, pressed ? "gedrückt" : "losgelassen")
        pressed ? b.onPress() : b.onRelease()
    }
}

enum HotkeyID {
    static let clipboard: UInt32 = 1
    static let dictation: UInt32 = 2
    static let meeting: UInt32 = 3
    static let recording: UInt32 = 4
}
