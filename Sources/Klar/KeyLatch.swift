import AppKit
import ApplicationServices

// Feststelltaste als „Taste festhalten“: Ist die Feststelltaste an und wird eine Taste gedrückt (z. B. W),
// bleibt diese für alle Apps gedrückt, auch nach dem Loslassen – etwa zum Dauerlaufen in Spielen.
// Losgelassen wird sie, wenn man sie bei eingeschalteter Feststelltaste erneut drückt, sie bei
// ausgeschalteter Feststelltaste normal antippt oder die Feststelltaste ausschaltet.

/// Entscheidungslogik ohne Systemaufrufe (Mac und Windows verhalten sich gleich, siehe Klar.Core/KeyLatch.cs).
struct KeyLatchLogic {
    enum Verdict: Equatable {
        /// Ereignis unverändert weitergeben.
        case pass
        /// Weitergeben – die Taste ist ab jetzt festgehalten (auf dem Mac ohne Großschreibung).
        case passAndLatch
        /// Ereignis verschlucken.
        case swallow
    }

    private(set) var latched = Set<UInt16>()
    /// Physisches Loslassen, das verschluckt wird, weil die App die Taste weiter gedrückt sehen soll.
    private var swallowUp = Set<UInt16>()

    /// - Returns: Urteil und Tasten, für die jetzt ein künstliches Loslassen zu senden ist.
    mutating func keyDown(_ key: UInt16, isRepeat: Bool, capsLock: Bool, otherModifiers: Bool,
                          latchable: Bool) -> (Verdict, release: [UInt16]) {
        if isRepeat { return (.pass, []) }
        if latched.contains(key) {
            guard capsLock else { return (.pass, []) } // normales Antippen: das Loslassen beendet es
            latched.remove(key)
            swallowUp.insert(key)
            return (.swallow, [key])
        }
        guard capsLock, !otherModifiers, latchable else { return (.pass, []) }
        latched.insert(key)
        swallowUp.insert(key)
        return (.passAndLatch, [])
    }

    mutating func keyUp(_ key: UInt16) -> Verdict {
        if swallowUp.remove(key) != nil { return .swallow }
        latched.remove(key)
        return .pass
    }

    /// Feststelltaste aus: alle festgehaltenen Tasten loslassen.
    mutating func capsLockOff() -> [UInt16] {
        let all = Array(latched)
        latched.removeAll()
        return all
    }
}

/// Fängt die Tastatur über einen Event-Tap ab (braucht die Bedienungshilfen-Freigabe).
@MainActor
final class KeyLatch {
    static let shared = KeyLatch()

    /// Kennzeichnung eigener, künstlicher Ereignisse, damit der Tap sie nicht erneut bewertet.
    nonisolated static let marker: Int64 = 0x4B4C_4C54 // „KLLT“

    nonisolated(unsafe) private var logic = KeyLatchLogic()
    nonisolated(unsafe) private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private(set) var isRunning = false

    private init() {}

    /// Schaltet die Funktion passend zur Einstellung ein oder aus.
    func apply(enabled: Bool) {
        enabled ? start() : stop()
    }

    private func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            NSLog("Klar: Feststelltaste festhalten braucht die Bedienungshilfen-Freigabe.")
            return
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            KeyLatch.handle(type: type, event: event)
        }, userInfo: nil) else {
            NSLog("Klar: Event-Tap für die Feststelltaste ließ sich nicht anlegen.")
            return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        isRunning = true
    }

    private func stop() {
        guard let port = tap else { return }
        Self.release(logic.capsLockOff())
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        tap = nil
        source = nil
        isRunning = false
    }

    /// Modifier, Feststelltaste und Escape lassen sich nicht festhalten.
    nonisolated private static let notLatchable: Set<UInt16> = [53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 179]

    /// Läuft auf dem Haupt-Thread (Run-Loop des Taps) und muss sofort zurückkehren.
    nonisolated private static func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let me = MainActor.assumeIsolated { KeyLatch.shared }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = me.tap { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == marker { return Unmanaged.passUnretained(event) }
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        switch type {
        case .flagsChanged:
            if key == 57, !flags.contains(.maskAlphaShift) { release(me.logic.capsLockOff()) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let (verdict, toRelease) = me.logic.keyDown(
                key, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                capsLock: flags.contains(.maskAlphaShift),
                otherModifiers: !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty,
                latchable: !notLatchable.contains(key))
            release(toRelease)
            switch verdict {
            case .pass: return Unmanaged.passUnretained(event)
            case .passAndLatch:
                event.flags.remove(.maskAlphaShift) // „w“ statt „W“
                return Unmanaged.passUnretained(event)
            case .swallow: return nil
            }
        case .keyUp:
            return me.logic.keyUp(key) == .swallow ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    nonisolated private static func release(_ keys: [UInt16]) {
        guard !keys.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = marker
        for key in keys {
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            up?.setIntegerValueField(.eventSourceUserData, value: marker)
            up?.post(tap: .cgSessionEventTap)
        }
    }
}
