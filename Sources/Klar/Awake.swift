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
    /// Deckel-Modus: Der Mac läuft auch zugeklappt weiter (ohne externen Bildschirm).
    /// Setzt systemweit „SleepDisabled“ – braucht das Admin-Passwort, wie bei Amphetamine.
    @Published private(set) var lidMode = false
    @Published var lidError: String?
    @Published private(set) var lidBusy = false

    static let durations: [(label: String, seconds: TimeInterval)] = [
        ("15 Min", 15 * 60), ("30 Min", 30 * 60), ("1 Std", 3600),
        ("2 Std", 2 * 3600), ("4 Std", 4 * 3600), ("8 Std", 8 * 3600),
    ]

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var expiry: Timer?
    private var ticker: Timer?

    private init() {
        // Nach Absturz oder Neustart: Zustand aus dem System übernehmen.
        let armed = UserDefaults.standard.bool(forKey: "lidModeArmed")
        let disabled = Self.systemSleepDisabled()
        lidMode = armed && disabled
        if armed && !disabled { UserDefaults.standard.set(false, forKey: "lidModeArmed") }
    }

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
        if lidMode { setLidMode(false) }
    }

    // MARK: Deckel-Modus

    /// Liest „SleepDisabled“ aus der Power-Management-Domäne des Kernels.
    nonisolated static func systemSleepDisabled() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    /// Schaltet den Deckel-Modus um. macOS fragt nach dem Administrator-Passwort.
    func setLidMode(_ on: Bool) {
        guard !lidBusy, on != lidMode else { return }
        lidBusy = true
        lidError = nil
        if on, !isActive { start(duration: nil) }
        Task.detached {
            let script = "do shell script \"/usr/bin/pmset disablesleep \(on ? 1 : 0)\" with administrator privileges"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            let ok = error == nil && Self.systemSleepDisabled() == on
            let message = (error?[NSAppleScript.errorMessage] as? String) ?? ""
            await MainActor.run {
                self.lidBusy = false
                if ok {
                    self.lidMode = on
                    UserDefaults.standard.set(on, forKey: "lidModeArmed")
                } else if message.contains("-128") || message.localizedCaseInsensitiveContains("abgebrochen") || message.localizedCaseInsensitiveContains("cancel") {
                    // Passwortdialog abgebrochen – kein Fehler.
                } else {
                    self.lidError = message.isEmpty ? "Deckel-Modus konnte nicht geändert werden." : message
                }
                self.objectWillChange.send()
            }
        }
    }

    /// Beim Beenden der App: Deckel-Modus nie aktiv zurücklassen.
    func releaseLidModeOnQuit() {
        guard lidMode else { return }
        let script = "do shell script \"/usr/bin/pmset disablesleep 0\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error == nil { UserDefaults.standard.set(false, forKey: "lidModeArmed") }
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
            return lidMode ? "Wach, unbegrenzt – auch zugeklappt" : "Wach, unbegrenzt"
        }
        if autoHold { return "Wach, solange Meeting oder Aufnahme läuft" }
        return "Der Mac darf schlafen."
    }

    var menuTitle: String {
        if isActive {
            if let end = until { return "Cocaine bis \(Format.time.string(from: end))" }
            return "Cocaine (unbegrenzt)"
        }
        return "Cocaine"
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
