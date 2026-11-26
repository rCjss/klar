import AppKit

@main
struct KlarMain {
    @MainActor
    static func main() {
        WhisperSelfTest.runIfRequested() // kehrt nur zurück, wenn kein Selbsttest verlangt ist
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
