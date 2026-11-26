import Combine
import CryptoKit
import Foundation

/// Lädt Sprachmodelle herunter und meldet den Fortschritt an die Oberfläche.
@MainActor
public final class ModelStore: ObservableObject {
    /// Ordner, in dem die Modelle liegen. Muss vor dem ersten Download gesetzt sein.
    public let directory: URL

    @Published public private(set) var activeID: String?
    /// 0 bis 1.
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var error: String?

    private var running: Task<Bool, Never>?

    public init(directory: URL) {
        self.directory = directory
    }

    public func isDownloaded(_ model: SpeechModel) -> Bool { model.isDownloaded(in: directory) }

    /// Pfad, den die Erkennung öffnet: Datei (Whisper) oder Ordner (Parakeet).
    public func path(of model: SpeechModel) -> String { model.location(in: directory).path }

    /// Stellt sicher, dass das Modell vorhanden ist. Läuft bereits ein Download, wird auf ihn gewartet.
    @discardableResult
    public func ensure(_ model: SpeechModel) async -> Bool {
        while let running {
            let sameModel = activeID == model.id
            let ok = await running.value
            if sameModel { return ok }
        }
        if isDownloaded(model) { return true }

        activeID = model.id
        progress = 0
        error = nil
        let directory = directory
        // Die Aufgabe räumt selbst auf, damit Wartende beim Aufwachen schon den neuen Stand sehen.
        let task = Task { @MainActor () -> Bool in
            var ok = false
            do {
                try await Self.download(model, into: directory) { [weak self] p in
                    Task { @MainActor in
                        guard let self, self.activeID == model.id, p > self.progress else { return }
                        self.progress = p
                    }
                }
                ok = true
            } catch {
                let stalled = (error as? URLError)?.code == .timedOut
                self.error = "Sprachmodell konnte nicht geladen werden: "
                    + (stalled ? "Die Verbindung steht still." : Self.describe(error))
                NSLog("Klar: Modell %@ nicht geladen: %@", model.id, String(describing: error))
            }
            self.running = nil
            self.activeID = nil
            if ok { self.progress = 1 }
            return ok
        }
        running = task
        return await task.value
    }

    /// Entfernt ein geladenes Modell (Speicher freigeben).
    public func remove(_ model: SpeechModel) {
        guard activeID != model.id else { return }
        try? FileManager.default.removeItem(at: model.location(in: directory))
        objectWillChange.send()
    }

    private static func describe(_ error: Error) -> String {
        if case DownloadFailure.checksum = error { return "Die Datei ist beschädigt angekommen." }
        if case DownloadFailure.diskFull = error { return "Nicht genug freier Speicher." }
        return error.localizedDescription
    }

    private nonisolated static func download(_ model: SpeechModel, into directory: URL,
                                             onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: model.location(in: directory).deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if model.kind == .parakeet {
            try fm.createDirectory(at: model.location(in: directory), withIntermediateDirectories: true)
        }
        if let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free > 0, free < model.totalBytes + 200_000_000 {
            throw DownloadFailure.diskFull
        }

        let total = Double(model.totalBytes)
        var done: Int64 = 0
        for file in model.files {
            let destination = model.fileURL(file, in: directory)
            let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? -1
            if size != file.bytes {
                let offset = done
                try await FileDownload(file: file, destination: destination) { written in
                    onProgress(min(1, Double(offset + written) / total))
                }.run(from: model.url(of: file))
            }
            done += file.bytes
            onProgress(min(1, Double(done) / total))
        }
    }
}

enum DownloadFailure: Error { case checksum, size, diskFull }

/// Eine Datei mit Fortschritt. Steht die Verbindung eine Minute lang still, bricht der Download ab.
/// Größe und SHA-256 werden geprüft, bevor die Datei an ihren Platz kommt.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let file: SpeechModelFile
    private let destination: URL
    private let onProgress: (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(file: SpeechModelFile, destination: URL, onProgress: @escaping (Int64) -> Void) {
        self.file = file
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(from url: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.addOperation {
                self.continuation = c
                session.downloadTask(with: url).resume()
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(min(totalBytesWritten, file.bytes))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Die temporäre Datei verschwindet nach dieser Methode – deshalb hier prüfen und verschieben.
        do {
            guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let fm = FileManager.default
            let size = (try fm.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size == file.bytes else { throw DownloadFailure.size }
            guard try Self.sha256(of: location) == file.sha256 else { throw DownloadFailure.checksum }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = continuation
        continuation = nil
        if let e = error ?? failure { c?.resume(throwing: e) } else { c?.resume() }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
