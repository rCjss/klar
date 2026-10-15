import AppKit
import ApplicationServices

/// Schreibt Inhalte in die Zwischenablage und löst ⌘V in der aktiven App aus.
enum Paster {
    static func write(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text ?? "", forType: .string)
        case .image:
            if let file = item.imageFile,
               let image = NSImage(contentsOf: Storage.images.appendingPathComponent(file)) {
                pb.writeObjects([image])
            }
        case .files:
            let urls = (item.files ?? []).map { URL(fileURLWithPath: $0) as NSURL }
            pb.writeObjects(urls)
        }
        ClipboardMonitor.shared.noteOwnChange()
        // Der Eintrag gilt wieder als zuletzt kopiert.
        ClipboardStore.shared.touch(item.id)
    }

    static func write(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ClipboardMonitor.shared.noteOwnChange()
    }

    /// Legt ein GIF als Datei und als Bilddaten in die Zwischenablage und merkt es im Verlauf.
    static func writeGif(at file: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        if let data = try? Data(contentsOf: file) {
            pb.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
        }
        ClipboardMonitor.shared.noteOwnChange()
        ClipboardStore.shared.add(ClipItem(kind: .files, files: [file.path], sourceApp: "Giphy"))
    }

    static var canPaste: Bool { AXIsProcessTrusted() }

    /// Sendet ⌘V an die aktuell aktive App. Benötigt die Bedienungshilfen-Freigabe.
    @discardableResult
    static func sendPasteKeystroke(delay: TimeInterval = 0.25) -> Bool {
        guard canPaste else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let src = CGEventSource(stateID: .hidSystemState)
            let vKey: CGKeyCode = 9
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else { return }
            down.flags = .maskCommand
            up.flags = .maskCommand
            // Ziel-App explizit adressieren, falls sie bekannt ist – sonst an das System.
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
               pid != ProcessInfo.processInfo.processIdentifier {
                down.postToPid(pid)
                usleep(20_000)
                up.postToPid(pid)
            } else {
                down.post(tap: .cghidEventTap)
                usleep(20_000)
                up.post(tap: .cghidEventTap)
            }
        }
        return true
    }

    static func paste(_ item: ClipItem) {
        write(item)
        sendPasteKeystroke()
    }

    static func paste(text: String) {
        write(text: text)
        sendPasteKeystroke()
    }
}
