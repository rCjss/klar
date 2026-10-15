import Foundation
import Carbon
import AppKit

// MARK: - Hotkey

struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let clipboardDefault = Hotkey(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | shiftKey))
    static let dictationDefault = Hotkey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
    static let meetingDefault = Hotkey(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: UInt32(cmdKey | shiftKey | optionKey))
    static let recordingDefault = Hotkey(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(cmdKey | shiftKey | optionKey))

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Einzelne Modifier-Tasten (z. B. rechte ⌘) als eigener Auslöser.
    static let modifierKeyNames: [UInt32: String] = [
        54: "rechte ⌘", 55: "linke ⌘", 61: "rechte ⌥", 58: "linke ⌥",
        60: "rechte ⇧", 56: "linke ⇧", 62: "rechte ⌃", 59: "linke ⌃", 63: "fn",
    ]
    /// Geräte-spezifische Flag-Bits aus IOKit (NX_DEVICE…KEYMASK), um Links/Rechts zu unterscheiden.
    static let modifierDeviceMasks: [UInt32: UInt] = [
        54: 0x10, 55: 0x08, 61: 0x40, 58: 0x20, 60: 0x04, 56: 0x02, 62: 0x2000, 59: 0x01, 63: 0x80_0000,
    ]

    var isModifierOnly: Bool { carbonModifiers == 0 && Self.modifierKeyNames[keyCode] != nil }

    static func modifierPressed(in event: NSEvent, keyCode: UInt32) -> Bool {
        guard let mask = modifierDeviceMasks[keyCode] else { return false }
        return event.modifierFlags.rawValue & mask != 0
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        let code = UInt32(event.keyCode)
        let isFunctionKey = (Int(code) >= kVK_F1 && Int(code) <= kVK_F12) || code == UInt32(kVK_F13) || code == UInt32(kVK_F14) || code == UInt32(kVK_F15)
        if mods == 0 && !isFunctionKey { return nil }
        self.init(keyCode: code, carbonModifiers: mods)
    }

    var display: String {
        if isModifierOnly { return Self.modifierKeyNames[keyCode] ?? "?" }
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }
}

enum KeyNames {
    static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "PgUp", kVK_PageDown: "PgDn", kVK_ForwardDelete: "⌦",
    ]

    static func name(for keyCode: UInt32) -> String {
        if let s = special[Int(keyCode)] { return s }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let data = unsafeBitCast(layoutPtr, to: CFData.self) as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            let layout = ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

// MARK: - Clipboard

enum ClipKind: String, Codable {
    case text, image, files
}

struct ClipItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: ClipKind
    var text: String?
    var imageFile: String?
    var files: [String]?
    var createdAt: Date = Date()
    var pinned: Bool = false
    var sourceApp: String?

    var preview: String {
        switch kind {
        case .text:
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.replacingOccurrences(of: "\n", with: " ⏎ ")
        case .image:
            return "Bild"
        case .files:
            let names = (files ?? []).map { ($0 as NSString).lastPathComponent }
            return names.joined(separator: ", ")
        }
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return preview.localizedCaseInsensitiveContains(query)
            || (sourceApp ?? "").localizedCaseInsensitiveContains(query)
    }
}

// MARK: - Dictation

struct Dictation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String
    var createdAt: Date = Date()
    var duration: TimeInterval
    var usedSnippet: String?
}

struct Snippet: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var trigger: String
    var text: String
}

// MARK: - Meetings

struct TranscriptLine: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var time: TimeInterval
    var speaker: String
    var text: String
}

struct MeetingTranscript: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var startedAt: Date = Date()
    var endedAt: Date?
    var lines: [TranscriptLine] = []
    var summary: String?

    var plainText: String {
        lines.map { "[\(Format.clock($0.time))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }
}

enum Format {
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "d. MMM yyyy, HH:mm"
        return f
    }()

    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()

    static func relative(_ d: Date) -> String {
        let diff = Date().timeIntervalSince(d)
        if diff < 60 { return "gerade eben" }
        if diff < 3600 { return "vor \(Int(diff / 60)) Min." }
        if Calendar.current.isDateInToday(d) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
        }
        if Calendar.current.isDateInYesterday(d) { return "gestern" }
        return dateTime.string(from: d)
    }
}
