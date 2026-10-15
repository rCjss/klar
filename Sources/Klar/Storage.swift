import Foundation

enum Storage {
    /// Alle Daten (Zwischenablage, Diktate, Transkripte) sind nur für den eigenen Benutzer lesbar.
    private static let dirAttrs: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
    static let fileAttrs: [FileAttributeKey: Any] = [.posixPermissions: 0o600]

    static func makeDir(_ dir: URL) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: dirAttrs)
        try? FileManager.default.setAttributes(dirAttrs, ofItemAtPath: dir.path)
        return dir
    }

    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return makeDir(base.appendingPathComponent("Klar", isDirectory: true))
    }()

    static let images: URL = { makeDir(root.appendingPathComponent("Images", isDirectory: true)) }()

    static let gifs: URL = { makeDir(root.appendingPathComponent("GIFs", isDirectory: true)) }()

    static let recordings: URL = {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return makeDir(base.appendingPathComponent("Klar", isDirectory: true))
    }()

    static func load<T: Decodable>(_ name: String) -> T? {
        let url = root.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, as name: String) {
        let url = root.appendingPathComponent(name)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(value) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(fileAttrs, ofItemAtPath: url.path)
        }
    }
}

/// Verzögert Schreibvorgänge, damit schnelle Änderungen nicht jedes Mal die Datei treffen.
final class Debouncer {
    private var work: DispatchWorkItem?
    private let delay: TimeInterval
    init(delay: TimeInterval = 0.4) { self.delay = delay }
    func call(_ block: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: block)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    func flush() {
        if let w = work, !w.isCancelled { w.perform(); work = nil }
    }
}
