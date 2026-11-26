using System.Globalization;
using System.Text.Json.Serialization;

namespace Klar.Core;

// MARK: - Hotkey

/// <summary>Werte entsprechen den Win32-Konstanten MOD_ALT, MOD_CONTROL, MOD_SHIFT, MOD_WIN.</summary>
[Flags]
public enum HotkeyModifiers
{
    None = 0,
    Alt = 1,
    Control = 2,
    Shift = 4,
    Win = 8,
}

/// <summary>Tastenkürzel: virtueller Tastencode plus Modifier. Ohne Modifier und mit einer
/// Modifier-Taste als Code ist es ein Einzeltasten-Auslöser (z. B. rechte Strg).</summary>
public readonly record struct Hotkey(uint Key, HotkeyModifiers Modifiers)
{
    public const uint VkSpace = 0x20, VkLShift = 0xA0, VkRShift = 0xA1, VkLControl = 0xA2, VkRControl = 0xA3,
        VkLMenu = 0xA4, VkRMenu = 0xA5, VkLWin = 0x5B, VkRWin = 0x5C;

    // Strg+Alt entspricht AltGr. Die gewählten Buchstaben tragen auf deutschen Tastaturen kein AltGr-Zeichen.
    public static readonly Hotkey ClipboardDefault = new('V', HotkeyModifiers.Control | HotkeyModifiers.Alt);
    public static readonly Hotkey DictationDefault = new('D', HotkeyModifiers.Control | HotkeyModifiers.Alt);
    public static readonly Hotkey MeetingDefault = new('M', HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Shift);
    public static readonly Hotkey RecordingDefault = new('R', HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Shift);
    public static readonly Hotkey AwakeDefault = new('W', HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Shift);

    /// <summary>Einzelne Modifier-Tasten als eigener Auslöser.</summary>
    public static readonly IReadOnlyDictionary<uint, string> ModifierKeyNames = new Dictionary<uint, string>
    {
        [VkRControl] = "rechte Strg", [VkLControl] = "linke Strg",
        [VkRMenu] = "rechte Alt", [VkLMenu] = "linke Alt",
        [VkRShift] = "rechte Umschalt", [VkLShift] = "linke Umschalt",
        [VkRWin] = "rechte Win", [VkLWin] = "linke Win",
    };

    [JsonIgnore]
    public bool IsModifierOnly => Modifiers == HotkeyModifiers.None && ModifierKeyNames.ContainsKey(Key);

    [JsonIgnore]
    public string Display
    {
        get
        {
            if (IsModifierOnly) return ModifierKeyNames[Key];
            var parts = new List<string>(5);
            if (Modifiers.HasFlag(HotkeyModifiers.Control)) parts.Add("Strg");
            if (Modifiers.HasFlag(HotkeyModifiers.Alt)) parts.Add("Alt");
            if (Modifiers.HasFlag(HotkeyModifiers.Shift)) parts.Add("Umschalt");
            if (Modifiers.HasFlag(HotkeyModifiers.Win)) parts.Add("Win");
            parts.Add(KeyNames.Name(Key));
            return string.Join("+", parts);
        }
    }

    /// <summary>Ein Kürzel braucht mindestens einen Modifier – außer bei Funktionstasten.</summary>
    public static bool IsAcceptable(uint key, HotkeyModifiers modifiers)
        => modifiers != HotkeyModifiers.None || (key >= 0x70 && key <= 0x87);
}

public static class KeyNames
{
    /// <summary>Wird von der Windows-App gesetzt und liefert das Zeichen laut aktuellem Tastaturlayout.</summary>
    public static Func<uint, string?>? LayoutResolver { get; set; }

    private static readonly Dictionary<uint, string> Special = new()
    {
        [0x20] = "Leertaste", [0x0D] = "Enter", [0x09] = "Tab", [0x08] = "Rück", [0x1B] = "Esc",
        [0x25] = "←", [0x26] = "↑", [0x27] = "→", [0x28] = "↓",
        [0x24] = "Pos1", [0x23] = "Ende", [0x21] = "Bild↑", [0x22] = "Bild↓", [0x2E] = "Entf", [0x2D] = "Einfg",
        [0x13] = "Pause", [0x2C] = "Druck", [0x91] = "Rollen", [0x14] = "Feststell",
    };

    public static string Name(uint key)
    {
        if (Special.TryGetValue(key, out var s)) return s;
        if (key >= 0x70 && key <= 0x87) return "F" + (key - 0x6F);
        if ((key >= 'A' && key <= 'Z') || (key >= '0' && key <= '9')) return ((char)key).ToString();
        if (key >= 0x60 && key <= 0x69) return "Num " + (key - 0x60);
        var resolved = LayoutResolver?.Invoke(key);
        if (!string.IsNullOrWhiteSpace(resolved)) return resolved!.ToUpperInvariant();
        return "Taste " + key;
    }
}

// MARK: - Clipboard

public enum ClipKind { Text, Image, Files }

public sealed class ClipItem
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public ClipKind Kind { get; set; }
    public string? Text { get; set; }
    public string? ImageFile { get; set; }
    public List<string>? Files { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public bool Pinned { get; set; }
    public string? SourceApp { get; set; }

    [JsonIgnore]
    public string Preview => Kind switch
    {
        ClipKind.Text => (Text ?? "").Trim().Replace("\r\n", "\n").Replace("\n", " ⏎ "),
        ClipKind.Image => "Bild",
        _ => string.Join(", ", (Files ?? []).Select(LastPathComponent)),
    };

    /// <summary>Letzter Pfadbestandteil – unabhängig davon, ob der Pfad mit \ oder / geschrieben ist.</summary>
    public static string LastPathComponent(string path)
    {
        var p = path.TrimEnd('\\', '/');
        var i = p.LastIndexOfAny(['\\', '/']);
        return i >= 0 ? p[(i + 1)..] : p;
    }

    public bool Matches(string query)
    {
        if (string.IsNullOrEmpty(query)) return true;
        return Preview.Contains(query, StringComparison.CurrentCultureIgnoreCase)
            || (SourceApp ?? "").Contains(query, StringComparison.CurrentCultureIgnoreCase);
    }
}

// MARK: - Dictation

public sealed class Dictation
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Text { get; set; } = "";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public double Duration { get; set; }
    public string? UsedSnippet { get; set; }
}

public sealed class Snippet
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Trigger { get; set; } = "";
    public string Text { get; set; } = "";
}

// MARK: - Meetings

public sealed class TranscriptLine
{
    public Guid Id { get; set; } = Guid.NewGuid();
    /// <summary>Sekunden seit Beginn des Meetings.</summary>
    public double Time { get; set; }
    public string Speaker { get; set; } = "";
    public string Text { get; set; } = "";
}

public sealed class MeetingTranscript
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "";
    public DateTime StartedAt { get; set; } = DateTime.UtcNow;
    public DateTime? EndedAt { get; set; }
    public List<TranscriptLine> Lines { get; set; } = [];
    public string? Summary { get; set; }

    [JsonIgnore]
    public string PlainText => string.Join("\n", Lines.Select(l => $"[{Format.Clock(l.Time)}] {l.Speaker}: {l.Text}"));
}

public static class Format
{
    private static readonly CultureInfo De = CultureInfo.GetCultureInfo("de-DE");

    public static string Clock(double seconds)
    {
        var s = (int)Math.Max(0, seconds);
        return $"{s / 3600:00}:{s % 3600 / 60:00}:{s % 60:00}";
    }

    public static string DateTimeText(DateTime utc) => utc.ToLocalTime().ToString("d. MMM yyyy, HH:mm", De);
    public static string TimeText(DateTime utc) => utc.ToLocalTime().ToString("HH:mm", De);
    public static string FileStamp(DateTime utc) => utc.ToLocalTime().ToString("yyyy-MM-dd HH.mm", CultureInfo.InvariantCulture);

    public static string Relative(DateTime utc) => Relative(utc, DateTime.UtcNow);

    public static string Relative(DateTime utc, DateTime nowUtc)
    {
        var diff = (nowUtc - utc).TotalSeconds;
        if (diff < 60) return "gerade eben";
        if (diff < 3600) return $"vor {(int)(diff / 60)} Min.";
        var local = utc.ToLocalTime();
        var today = nowUtc.ToLocalTime().Date;
        if (local.Date == today) return local.ToString("HH:mm", De);
        if (local.Date == today.AddDays(-1)) return "gestern";
        return DateTimeText(utc);
    }

    public static string FileSize(long bytes)
    {
        if (bytes >= 1L << 30) return (bytes / (double)(1L << 30)).ToString("0.0", De) + " GB";
        if (bytes >= 1L << 20) return (bytes / (double)(1L << 20)).ToString("0.0", De) + " MB";
        if (bytes >= 1L << 10) return (bytes / (double)(1L << 10)).ToString("0", De) + " KB";
        return bytes + " Byte";
    }
}
