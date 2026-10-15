import Foundation

/// Erkennt gesprochene Befehle im Diktat und ersetzt sie durch Textbausteine.
/// „Signatur“ allein → Baustein. „… einfügen Signatur …“ → inline ersetzt.
enum VoiceCommands {
    struct Result {
        var text: String
        var usedSnippet: String?
    }

    static func apply(_ raw: String, snippets: [Snippet], prefix: String) -> Result {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var used: String?

        let normalized = normalize(text)
        for s in snippets where !s.trigger.isEmpty {
            if normalized == normalize(s.trigger) {
                return Result(text: s.text, usedSnippet: s.trigger)
            }
        }

        let prefixPattern = prefix.trimmingCharacters(in: .whitespaces)
        for s in snippets where !s.trigger.isEmpty {
            let words = s.trigger.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let triggerPattern = words.joined(separator: "[\\s,]+")
            var patterns: [String] = []
            if !prefixPattern.isEmpty {
                patterns.append("(?i)\\b" + NSRegularExpression.escapedPattern(for: prefixPattern) + "[\\s,.:;]+" + triggerPattern + "\\b[.,!?]?")
            }
            for p in patterns {
                guard let re = try? NSRegularExpression(pattern: p) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if re.firstMatch(in: text, range: range) != nil {
                    let replacement = NSRegularExpression.escapedTemplate(for: s.text)
                    text = re.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
                    used = s.trigger
                }
            }
        }

        text = builtins(text)
        return Result(text: text, usedSnippet: used)
    }

    /// Eingebaute Befehle: „neue Zeile“, „neuer Absatz“.
    private static func builtins(_ input: String) -> String {
        var t = input
        let rules: [(String, String)] = [
            ("(?i),?\\s*\\bneuer absatz\\b[.,]?\\s*", "\n\n"),
            ("(?i),?\\s*\\bneue zeile\\b[.,]?\\s*", "\n"),
        ]
        for (p, r) in rules {
            if let re = try? NSRegularExpression(pattern: p) {
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: r)
            }
        }
        return t
    }

    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let stripped = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(stripped)).split(separator: " ").joined(separator: " ")
    }
}
