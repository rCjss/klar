using System.Text;
using System.Text.RegularExpressions;

namespace Klar.Core;

/// <summary>Erkennt gesprochene Befehle im Diktat und ersetzt sie durch Textbausteine.
/// „Signatur“ allein → Baustein. „… einfügen Signatur …“ → inline ersetzt.</summary>
public static class VoiceCommands
{
    public readonly record struct Result(string Text, string? UsedSnippet);

    public static Result Apply(string raw, IEnumerable<Snippet> snippets, string prefix)
    {
        var text = raw.Trim();
        string? used = null;
        var list = snippets.Where(s => !string.IsNullOrWhiteSpace(s.Trigger)).ToList();

        var normalized = Normalize(text);
        foreach (var s in list)
            if (normalized == Normalize(s.Trigger))
                return new Result(s.Text, s.Trigger);

        var prefixPattern = prefix.Trim();
        if (prefixPattern.Length > 0)
        {
            foreach (var s in list)
            {
                var words = s.Trigger.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(Loose);
                var triggerPattern = string.Join(@"[\s,]+", words);
                var pattern = @"\b" + Loose(prefixPattern) + @"[\s,.:;\-]+" + triggerPattern + @"\b[.,!?]?";
                var re = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
                if (!re.IsMatch(text)) continue;
                var replacement = s.Text;
                text = re.Replace(text, _ => replacement);
                used = s.Trigger;
            }
        }

        return new Result(Builtins(text), used);
    }

    /// <summary>Whisper trennt kurze Befehle manchmal falsch („Ein Fügen-Signatur“). Deshalb darf zwischen
    /// zwei Buchstaben eines Befehlsworts ein Leerzeichen oder Bindestrich stehen.</summary>
    private static string Loose(string word)
        => string.Join(@"[\s\-]?", word.Where(c => !char.IsWhiteSpace(c)).Select(c => Regex.Escape(c.ToString())));

    /// <summary>Hinweis für die Spracherkennung: die Befehle so, wie sie gesprochen werden.
    /// Ohne ihn schreibt Whisper kurze Befehle gern falsch („ein Fügen“).</summary>
    public static string RecognitionHint(IEnumerable<Snippet> snippets, string prefix)
    {
        var p = prefix.Trim();
        var parts = new List<string>();
        foreach (var s in snippets.Where(s => !string.IsNullOrWhiteSpace(s.Trigger)).Take(12))
            parts.Add(p.Length > 0 ? $"{Capitalize(p)} {s.Trigger.Trim()}." : s.Trigger.Trim() + ".");
        parts.Add("Neue Zeile.");
        parts.Add("Neuer Absatz.");
        return string.Join(" ", parts);
    }

    private static string Capitalize(string s) => s.Length == 0 ? s : char.ToUpper(s[0]) + s[1..];

    /// <summary>Eingebaute Befehle: „neue Zeile“, „neuer Absatz“.</summary>
    private static string Builtins(string input)
    {
        var t = Regex.Replace(input, @",?\s*\bneuer absatz\b[.,]?\s*", "\n\n", RegexOptions.IgnoreCase);
        t = Regex.Replace(t, @",?\s*\bneue zeile\b[.,]?\s*", "\n", RegexOptions.IgnoreCase);
        return t;
    }

    public static string Normalize(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var c in s.ToLowerInvariant())
            if (char.IsLetterOrDigit(c) || c == ' ') sb.Append(c);
        return string.Join(' ', sb.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }
}
