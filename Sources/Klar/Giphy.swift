import AppKit
import SwiftUI

// MARK: - Giphy-API

struct GiphyGif: Identifiable, Decodable, Equatable {
    struct Rendition: Decodable, Equatable {
        let url: String
        let width: String
        let height: String
    }
    struct Images: Decodable, Equatable {
        let fixedWidth: Rendition
        let original: Rendition
    }
    let id: String
    let title: String
    let images: Images

    var previewURL: URL? { URL(string: images.fixedWidth.url) }
    var originalURL: URL? { URL(string: images.original.url) }
    var previewAspect: CGFloat {
        let w = CGFloat(Double(images.fixedWidth.width) ?? 200)
        let h = CGFloat(Double(images.fixedWidth.height) ?? 200)
        return h > 0 ? w / h : 1
    }

    static func == (a: GiphyGif, b: GiphyGif) -> Bool { a.id == b.id }
}

enum GiphyError: LocalizedError {
    case missingKey, http(Int), invalid

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Kein Giphy-API-Schlüssel hinterlegt."
        case .http(let code): return code == 401 || code == 403 ? "Giphy-Schlüssel ungültig." : "Giphy antwortet nicht (\(code))."
        case .invalid: return "Giphy-Antwort unlesbar."
        }
    }
}

enum GiphyClient {
    private struct Envelope: Decodable { let data: [GiphyGif] }

    static func fetch(query: String, limit: Int = 30) async throws -> [GiphyGif] {
        let key = Settings.shared.giphyAPIKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw GiphyError.missingKey }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var comps = URLComponents(string: q.isEmpty ? "https://api.giphy.com/v1/gifs/trending"
                                                    : "https://api.giphy.com/v1/gifs/search")!
        var items = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "rating", value: "pg-13"),
            URLQueryItem(name: "lang", value: "de"),
        ]
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        comps.queryItems = items
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw GiphyError.http(http.statusCode) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let env = try? decoder.decode(Envelope.self, from: data) else { throw GiphyError.invalid }
        return env.data
    }

    /// Lädt das Original-GIF, legt es dauerhaft ab und liefert den Pfad.
    static func download(_ gif: GiphyGif) async throws -> URL {
        guard let url = gif.originalURL else { throw GiphyError.invalid }
        let name = Self.fileName(for: gif)
        let target = Storage.gifs.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let (data, _) = try await URLSession.shared.data(from: url)
        try data.write(to: target, options: .atomic)
        try? FileManager.default.setAttributes(Storage.fileAttrs, ofItemAtPath: target.path)
        return target
    }

    private static func fileName(for gif: GiphyGif) -> String {
        var title = gif.title
            .replacingOccurrences(of: " GIF by .*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: " GIF$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|")
        title = title.components(separatedBy: bad).joined(separator: " ")
        if title.isEmpty { title = "GIF" }
        return "\(title.prefix(60)) \(gif.id.prefix(6)).gif"
    }
}

// MARK: - Vorschau-Cache

@MainActor final class GifPreviewCache {
    static let shared = GifPreviewCache()
    private var images: [URL: NSImage] = [:]
    private var pending: [URL: Task<NSImage?, Never>] = [:]

    func image(for url: URL) async -> NSImage? {
        if let img = images[url] { return img }
        if let task = pending[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        pending[url] = task
        let img = await task.value
        pending[url] = nil
        if let img { images[url] = img }
        return img
    }
}

// MARK: - Animierte Vorschau (bildschirmfüllend zugeschnitten)

final class GifFillView: NSView {
    let imageView = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.animates = true
        imageView.imageScaling = .scaleAxesIndependently
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { nil }

    var image: NSImage? {
        didSet { imageView.image = image; needsLayout = true }
    }

    override func layout() {
        super.layout()
        guard let size = image?.size, size.width > 0, size.height > 0 else { imageView.frame = bounds; return }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        imageView.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

struct GifThumb: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> GifFillView { GifFillView(frame: .zero) }

    func updateNSView(_ view: GifFillView, context: Context) {
        guard let url else { view.image = nil; return }
        if context.coordinator.url == url { return }
        context.coordinator.url = url
        view.image = nil
        Task { @MainActor in
            let img = await GifPreviewCache.shared.image(for: url)
            if context.coordinator.url == url { view.image = img }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var url: URL? }
}
