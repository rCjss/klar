import Foundation

/// Datenformat zwischen Klar und dem Whisper-Hilfsprozess: Anfragen über dessen Standardeingabe,
/// Antworten über die Standardausgabe. Alle Zahlen sind UInt32 in der Byte-Reihenfolge des Rechners.
public enum Wire {
    public struct Request {
        public var modelPath: String
        /// Sprachcode, z. B. „de“.
        public var language: String
        /// Wörter, die wahrscheinlich vorkommen. Leer = kein Hinweis.
        public var hint: String
        /// 16 kHz Mono. Leer = nur das Modell laden.
        public var samples: [Float]

        public init(modelPath: String, language: String, hint: String, samples: [Float]) {
            self.modelPath = modelPath
            self.language = language
            self.hint = hint
            self.samples = samples
        }
    }

    public struct Response {
        public var status: Status
        public var text: String

        public init(status: Status, text: String) {
            self.status = status
            self.text = text
        }
    }

    public enum Status: UInt32 {
        case ok = 0
        case modelNotLoaded = 1
        case inferenceFailed = 2
    }

    public enum Failure: Error { case closed, malformed, io(Int32) }

    private static let requestMagic: UInt32 = 0x4B57_5231 // „KWR1“
    private static let responseMagic: UInt32 = 0x4B57_4131 // „KWA1“
    private static let maxString = 1 << 16
    /// Zehn Minuten Ton – weit mehr, als ein Abschnitt je hat.
    private static let maxSamples = 16000 * 600

    // MARK: Anfrage

    public static func write(_ request: Request, to fd: Int32) throws {
        var head = Data()
        append(requestMagic, to: &head)
        try append(request.modelPath, to: &head)
        try append(request.language, to: &head)
        try append(request.hint, to: &head)
        guard request.samples.count <= maxSamples else { throw Failure.malformed }
        append(UInt32(request.samples.count), to: &head)
        try writeAll(head, to: fd)
        try request.samples.withUnsafeBytes { try writeAll($0, to: fd) }
    }

    /// Liefert `nil`, wenn die Gegenseite die Leitung sauber geschlossen hat.
    public static func readRequest(from fd: Int32) throws -> Request? {
        guard let magic = try readUInt32(from: fd, allowEOF: true) else { return nil }
        guard magic == requestMagic else { throw Failure.malformed }
        let modelPath = try readString(from: fd)
        let language = try readString(from: fd)
        let hint = try readString(from: fd)
        let count = Int(try readUInt32(from: fd, allowEOF: false)!)
        guard count <= maxSamples else { throw Failure.malformed }
        var samples = [Float](repeating: 0, count: count)
        _ = try samples.withUnsafeMutableBytes { try readAll(into: $0, from: fd) }
        return Request(modelPath: modelPath, language: language, hint: hint, samples: samples)
    }

    // MARK: Antwort

    public static func write(_ response: Response, to fd: Int32) throws {
        var data = Data()
        append(responseMagic, to: &data)
        append(response.status.rawValue, to: &data)
        try append(response.text, to: &data)
        try writeAll(data, to: fd)
    }

    public static func readResponse(from fd: Int32) throws -> Response {
        guard let magic = try readUInt32(from: fd, allowEOF: true) else { throw Failure.closed }
        guard magic == responseMagic else { throw Failure.malformed }
        guard let status = Status(rawValue: try readUInt32(from: fd, allowEOF: false)!) else { throw Failure.malformed }
        return Response(status: status, text: try readString(from: fd))
    }

    // MARK: Bausteine

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    private static func append(_ string: String, to data: inout Data) throws {
        let bytes = Array(string.utf8)
        guard bytes.count <= maxString else { throw Failure.malformed }
        append(UInt32(bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    private static func readUInt32(from fd: Int32, allowEOF: Bool) throws -> UInt32? {
        var value: UInt32 = 0
        let complete = try withUnsafeMutableBytes(of: &value) { try readAll(into: $0, from: fd, allowEOF: allowEOF) }
        return complete ? value : nil
    }

    private static func readString(from fd: Int32) throws -> String {
        let count = Int(try readUInt32(from: fd, allowEOF: false)!)
        guard count <= maxString else { throw Failure.malformed }
        var bytes = [UInt8](repeating: 0, count: count)
        _ = try bytes.withUnsafeMutableBytes { try readAll(into: $0, from: fd) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { try writeAll($0, to: fd) }
    }

    private static func writeAll(_ buffer: UnsafeRawBufferPointer, to fd: Int32) throws {
        var offset = 0
        while offset < buffer.count {
            let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if n > 0 { offset += n; continue }
            if n < 0 && errno == EINTR { continue }
            throw n == 0 ? Failure.closed : Failure.io(errno)
        }
    }

    /// Liest genau `buffer.count` Bytes. Mit `allowEOF` darf die Leitung vor dem ersten Byte enden (Ergebnis `false`).
    @discardableResult
    private static func readAll(into buffer: UnsafeMutableRawBufferPointer, from fd: Int32, allowEOF: Bool = false) throws -> Bool {
        var offset = 0
        while offset < buffer.count {
            let n = Darwin.read(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if n > 0 { offset += n; continue }
            if n < 0 && errno == EINTR { continue }
            if n == 0 {
                if allowEOF && offset == 0 { return false }
                throw Failure.closed
            }
            throw Failure.io(errno)
        }
        return true
    }
}
