import Foundation
import IOKit.pwr_mgt

/// Hält Mac und Bildschirm wach – für eine gewählte Dauer oder unbegrenzt.
/// Technisch über IOKit-Power-Assertions, genau wie Amphetamine oder `caffeinate`.
/// Deckel schließen schläft trotzdem, sofern kein externer Bildschirm und Netzteil angeschlossen sind.
@MainActor
final class AwakeManager: ObservableObject {
    static let shared = AwakeManager()

    /// Manuell aktiv (per Menü, Hotkey oder Fenster).
    @Published private(set) var isActive = false
    /// Endzeitpunkt; nil = unbegrenzt.
    @Published private(set) var until: Date?
    /// Automatisch aktiv, weil ein Meeting transkribiert oder der Bildschirm aufgenommen wird.
    @Published private(set) var autoHold = false
    /// Tickt jede Sekunde, damit Anzeigen der Restzeit aktuell bleiben.
    @Published private(set) var tick = 0

    static let durations: [(label: String, seconds: TimeInterval)] = [
        ("15 Min", 15 * 60), ("30 Min", 30 * 60), ("1 Std", 3600),
        ("2 Std", 2 * 3600), ("4 Std", 4 * 3600), ("8 Std", 8 * 3600),
    ]

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var expiry: Timer?
    private var ticker: Timer?

    private init() {}

    var isHolding: Bool { isActive || autoHold }

    /// Startet oder verlängert. `duration` nil = unbegrenzt.
    func start(duration: TimeInterval?) {
        isActive = true
        until = duration.map { Date().addingTimeInterval($0) }
        expiry?.invalidate()
        if let end = until {
            expiry = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            RunLoop.main.add(expiry!, forMode: .common)
        }
        apply()
    }

    func stop() {
        isActive = false
        until = nil
        expiry?.invalidate()
        expiry = nil
        apply()
    }

    func toggle() {
        if isActive { stop() } else { start(duration: nil) }
    }

    /// Von Meeting-Transkription und Bildschirmaufnahme aufgerufen.
    func setAutoHold(_ on: Bool) {
        let wanted = on && Settings.shared.awakeDuringCapture
        guard wanted != autoHold else { return }
        autoHold = wanted
        apply()
    }

    /// Einstellung „Bildschirm ebenfalls wach halten“ wurde geändert.
    func refresh() { apply() }

    var statusText: String {
        if isActive {
            if let end = until { return "Wach bis \(Format.time.string(from: end)) · noch \(remainingText(end))" }
            return "Wach, unbegrenzt"
        }
        if autoHold { return "Wach, solange Meeting oder Aufnahme läuft" }
        return "Der Mac darf schlafen."
    }

    var menuTitle: String {
        if isActive {
            if let end = until { return "Wach bis \(Format.time.string(from: end))" }
            return "Wach (unbegrenzt)"
        }
        return "Wach halten"
    }

    private func remainingText(_ end: Date) -> String {
        let s = max(0, Int(end.timeIntervalSinceNow))
        if s >= 3600 { return "\(s / 3600) Std \(s % 3600 / 60) Min" }
        if s >= 60 { return "\(s / 60) Min" }
        return "\(s) Sek"
    }

    // MARK: Assertions

    private func apply() {
        let hold = isHolding
        let display = hold && Settings.shared.awakeKeepsDisplay
        set(&systemAssertion, type: kIOPMAssertionTypePreventUserIdleSystemSleep, on: hold)
        set(&displayAssertion, type: kIOPMAssertionTypePreventUserIdleDisplaySleep, on: display)
        updateTicker()
        AppDelegate.shared?.refreshStatusIcon()
    }

    private func set(_ id: inout IOPMAssertionID, type: String, on: Bool) {
        if on, id == 0 {
            var newID: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Klar hält den Mac wach" as CFString, &newID)
            if ok == kIOReturnSuccess { id = newID } else { NSLog("Klar: Power-Assertion fehlgeschlagen (%d)", ok) }
        } else if !on, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }

    private func updateTicker() {
        if isActive, until != nil, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick += 1 }
            }
        } else if (until == nil || !isActive), let t = ticker {
            t.invalidate(); ticker = nil
        }
    }
}
