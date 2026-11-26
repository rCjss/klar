import Foundation

// MARK: - Abschnitte

/// Teilt einen 16-kHz-Mono-Strom an Sprechpausen in Abschnitte. Nicht threadsicher.
public final class SpeechSegmenter {
    public static let rate = 16000
    private static let frame = 320 // 20 ms
    private static let frameSeconds = Double(frame) / Double(rate)

    /// Sprechpause, die einen Abschnitt beendet.
    public var pauseSeconds = 0.7
    /// Ab dieser Länge genügt eine kurze Pause zum Trennen.
    public var softLimitSeconds = 18.0
    public var softPauseSeconds = 0.3
    /// Whisper verarbeitet 30-Sekunden-Fenster; spätestens hier wird getrennt.
    public var hardLimitSeconds = 28.0
    public var minSpeechSeconds = 0.24
    public var preRollSeconds = 0.3
    public var keepTrailingSeconds = 0.2
    public var minThreshold: Float = 0.006

    private var frameBuffer = [Float]()
    private var preRoll = [[Float]]()
    private var segment: [Float]?
    private var speechFrames = 0
    private var silenceRun = 0
    private var onsetRun = 0
    private var noise: Float = 0.002
    private var recent = [Float](repeating: 0, count: 200) // Pegel der letzten vier Sekunden
    private var recentIndex = 0
    private var recentCount = 0

    public init() { frameBuffer.reserveCapacity(Self.frame) }

    /// Nimmt 16-kHz-Mono-Samples entgegen und liefert die dabei abgeschlossenen Abschnitte.
    public func append(_ samples: UnsafeBufferPointer<Float>) -> [[Float]] {
        var done = [[Float]]()
        var offset = 0
        while offset < samples.count {
            let take = min(Self.frame - frameBuffer.count, samples.count - offset)
            frameBuffer.append(contentsOf: UnsafeBufferPointer(rebasing: samples[offset..<(offset + take)]))
            offset += take
            guard frameBuffer.count == Self.frame else { break }
            if let finished = process(frameBuffer) { done.append(finished) }
            frameBuffer.removeAll(keepingCapacity: true)
        }
        return done
    }

    private func process(_ frame: [Float]) -> [Float]? {
        var sum: Float = 0
        for v in frame { sum += v * v }
        let rms = (sum / Float(frame.count)).squareRoot()

        // Grundrauschen: langsam nachgeführter Wert aus den leisen Phasen, mindestens aber das Minimum
        // der letzten vier Sekunden. So zählt gleichmäßiges Rauschen (Lüfter) nicht als Dauersprache;
        // echte Sprache fällt zwischen Silben immer wieder fast auf das Grundrauschen ab.
        recent[recentIndex] = rms
        recentIndex = (recentIndex + 1) % recent.count
        if recentCount < recent.count { recentCount += 1 }
        var windowMin: Float = 0
        if recentCount >= 50 { windowMin = recent[0..<recentCount].min() ?? 0 }
        let floor = min(max(max(noise, windowMin), 0.0003), 0.05)
        let threshold = max(minThreshold, floor * 3)
        let speech = rms > threshold
        if !speech {
            noise = rms < noise ? noise * 0.7 + rms * 0.3 : noise * 0.995 + rms * 0.005
            noise = min(max(noise, 0.0003), 0.03)
        }

        guard segment != nil else {
            preRoll.append(frame)
            let keep = max(2, Int((preRollSeconds / Self.frameSeconds).rounded()))
            if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
            onsetRun = speech ? onsetRun + 1 : 0
            guard onsetRun >= 2 else { return nil }
            var start = [Float]()
            start.reserveCapacity(Self.rate * 8)
            for f in preRoll { start.append(contentsOf: f) }
            segment = start
            preRoll.removeAll()
            speechFrames = onsetRun
            silenceRun = 0
            onsetRun = 0
            return nil
        }

        segment!.append(contentsOf: frame)
        if speech { speechFrames += 1; silenceRun = 0 } else { silenceRun += 1 }

        let length = Double(segment!.count) / Double(Self.rate)
        let silence = Double(silenceRun) * Self.frameSeconds
        if silence >= pauseSeconds
            || (length >= softLimitSeconds && silence >= softPauseSeconds)
            || length >= hardLimitSeconds {
            return close()
        }
        return nil
    }

    /// Kommt kein Ton mehr (z. B. Systemton pausiert), endet der laufende Abschnitt.
    public func closeIfIdle(_ idleFor: TimeInterval) -> [Float]? {
        segment != nil && idleFor >= pauseSeconds ? close() : nil
    }

    /// Am Ende der Aufnahme: den offenen Abschnitt abschließen.
    public func flush() -> [Float]? {
        frameBuffer.removeAll(keepingCapacity: true)
        onsetRun = 0
        preRoll.removeAll()
        return segment != nil ? close() : nil
    }

    private func close() -> [Float]? {
        guard var samples = segment else { return nil }
        let speech = Double(speechFrames) * Self.frameSeconds
        let trailing = silenceRun * Self.frame
        segment = nil
        speechFrames = 0
        silenceRun = 0
        guard speech >= minSpeechSeconds else { return nil }
        let cut = max(0, trailing - Int(keepTrailingSeconds * Double(Self.rate)))
        if cut > 0 { samples.removeLast(min(cut, samples.count)) }
        return samples
    }
}

// MARK: - Nachbearbeitung

/// Whisper erfindet bei Stille gern Abspänne. Solche Ausgaben werden verworfen. Parakeet tut das nicht,
/// der Filter schadet dort aber auch nicht.
public enum HallucinationFilter {
    private static let annotation = try! NSRegularExpression(
        pattern: #"\[[^\]]{0,40}\]|\*[^*]{0,40}\*|\((?:musik|music|applaus|applause|lachen|laughter|laughs|stille|silence|räuspern|husten)[^)]{0,20}\)|♪+"#,
        options: [.caseInsensitive])
    private static let spaces = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)

    private static let phrases: Set<String> = [
        "vielen dank fürs zuschauen", "vielen dank für s zuschauen", "danke fürs zuschauen",
        "thanks for watching", "thank you for watching", "bis zum nächsten mal",
        "sous titres réalisés para la communauté d amara org", "sous titres réalisés par la communauté d amara org",
        "sottotitoli creati dalla comunità amara org", "subtítulos realizados por la comunidad de amara org",
        "subtitles by the amara org community",
    ]

    public static func clean(_ text: String) -> String {
        var t = annotation.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        t = spaces.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        // Satzzeichen zählen als Wortgrenze, damit „Amara.org“ zu „amara org“ wird.
        let spaced = String(t.map { $0.isLetter || $0.isNumber ? $0 : " " })
        let n = normalize(spaced)
        if n.isEmpty { return "" }
        if n.count < 90 && (n.hasPrefix("untertitel") || n.contains("amara org")) { return "" }
        if phrases.contains(n) { return "" }
        return t
    }

    /// Kleinbuchstaben, nur Buchstaben, Ziffern und einfache Leerzeichen.
    public static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let stripped = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(stripped)).split(separator: " ").joined(separator: " ")
    }
}
