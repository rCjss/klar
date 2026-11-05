using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Klar.Core;

public enum SummaryProvider { Auto, ClaudeCode, ClaudeApi }

public static class SummaryProviders
{
    public static readonly IReadOnlyList<SummaryProvider> All = [SummaryProvider.Auto, SummaryProvider.ClaudeCode, SummaryProvider.ClaudeApi];

    public static string Label(this SummaryProvider p) => p switch
    {
        SummaryProvider.ClaudeCode => "Claude Code",
        SummaryProvider.ClaudeApi => "Claude-API",
        _ => "Automatisch",
    };

    /// <summary>Gleiche Schlüssel wie in der Mac-Version.</summary>
    public static string Key(this SummaryProvider p) => p switch
    {
        SummaryProvider.ClaudeCode => "claudeCode",
        SummaryProvider.ClaudeApi => "claudeAPI",
        _ => "auto",
    };

    public static SummaryProvider Parse(string? key) => key switch
    {
        "claudeCode" => SummaryProvider.ClaudeCode,
        "claudeAPI" => SummaryProvider.ClaudeApi,
        _ => SummaryProvider.Auto,
    };
}

public sealed class SummaryException(string message) : Exception(message)
{
    public static SummaryException Unavailable() => new("Keine Zusammenfassung möglich: Der gewählte Weg ist nicht verfügbar (Einstellungen → Zusammenfassung).");
    public static SummaryException ClaudeCode(string detail) => new("Claude Code: " + detail);
    public static SummaryException Http(int code, string body) => new($"Claude-API antwortete mit {code}: {(body.Length > 200 ? body[..200] : body)}");
    public static SummaryException Refused() => new("Die Anfrage wurde vom Modell abgelehnt.");
    public static SummaryException Empty() => new("Leere Antwort erhalten.");
}

/// <summary>Erstellt Zusammenfassungen von Meeting-Transkripten über Claude Code (Abo) oder die Claude-API.</summary>
public sealed class Summarizer
{
    public static Summarizer Shared { get; } = new();

    public const string Instructions = """
        Du fasst Meeting-Transkripte auf Deutsch zusammen. Sprecher „Ich“ ist der Nutzer, „Andere“ sind die Gesprächspartner.
        Nutze ausschließlich Informationen aus dem Transkript, erfinde nichts. Antworte in Markdown mit genau diesen Abschnitten:
        ## Kurzfassung
        (3–5 Sätze)
        ## Themen
        (Stichpunkte)
        ## Entscheidungen
        (Stichpunkte, oder „Keine“)
        ## Aufgaben
        (Stichpunkte: Wer macht was bis wann, oder „Keine“)
        ## Offene Fragen
        (Stichpunkte, oder „Keine“)
        """;

    private readonly HashSet<Guid> _busy = [];

    public event Action? Changed;
    public string? LastError { get; private set; }
    public bool IsBusy(Guid id) => _busy.Contains(id);

    private static bool HasKey => AppSettings.Shared.ClaudeApiKey.Length > 0;

    /// <summary>Der tatsächlich genutzte Weg – bei „Automatisch“: Claude Code, sonst API-Schlüssel.</summary>
    public SummaryProvider? ResolvedProvider => SummaryProviders.Parse(AppSettings.Shared.SummaryProvider) switch
    {
        SummaryProvider.ClaudeCode => ClaudeCodeBackend.IsAvailable ? SummaryProvider.ClaudeCode : null,
        SummaryProvider.ClaudeApi => HasKey ? SummaryProvider.ClaudeApi : null,
        _ => ClaudeCodeBackend.IsAvailable ? SummaryProvider.ClaudeCode : HasKey ? SummaryProvider.ClaudeApi : null,
    };

    public string ClaudeCodeStatus => ClaudeCodeBackend.IsAvailable ? "installiert, nutzt dein Abo" : "nicht gefunden";
    public string ClaudeApiStatus => HasKey ? "Schlüssel hinterlegt" : "kein Schlüssel";

    /// <summary>Vom UI-Thread aufrufen; Änderungen an Ablage und Status passieren dort.</summary>
    public async Task SummarizeAsync(Guid id)
    {
        if (_busy.Contains(id) || MeetingStore.Shared.Find(id) is not { } meeting) return;
        if (meeting.Lines.Count == 0)
        {
            LastError = "Das Transkript ist leer.";
            Changed?.Invoke();
            return;
        }
        _busy.Add(id);
        LastError = null;
        Changed?.Invoke();
        try
        {
            var text = meeting.PlainText;
            var summary = ResolvedProvider switch
            {
                SummaryProvider.ClaudeCode => await new ClaudeCodeBackend().SummarizeAsync(text),
                SummaryProvider.ClaudeApi => await new ClaudeApiBackend(AppSettings.Shared.ClaudeApiKey).SummarizeAsync(text),
                _ => throw SummaryException.Unavailable(),
            };
            MeetingStore.Shared.SetSummary(id, summary);
        }
        catch (Exception e)
        {
            LastError = e is SummaryException ? e.Message : "Zusammenfassung fehlgeschlagen: " + e.Message;
        }
        finally
        {
            _busy.Remove(id);
            Changed?.Invoke();
        }
    }
}

// MARK: - Claude API

public sealed class ClaudeApiBackend(string apiKey)
{
    public const string Model = "claude-opus-5-5";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(600) };

    public static byte[] BuildBody(string text) => JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object>
    {
        ["model"] = Model,
        ["max_tokens"] = 8000,
        ["system"] = Summarizer.Instructions,
        ["fallbacks"] = "default",
        ["messages"] = new[] { new Dictionary<string, string> { ["role"] = "user", ["content"] = "Transkript:\n\n" + text } },
    });

    public async Task<string> SummarizeAsync(string text, CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.anthropic.com/v1/messages");
        request.Headers.Add("x-api-key", apiKey);
        request.Headers.Add("anthropic-version", "2023-06-01");
        request.Headers.Add("anthropic-beta", "server-side-fallback-2026-07-01");
        request.Content = new ByteArrayContent(BuildBody(text));
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        using var response = await Http.SendAsync(request, ct).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode) throw SummaryException.Http((int)response.StatusCode, body);
        return ParseResponse(body);
    }

    public static string ParseResponse(string body)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(body); }
        catch (JsonException) { throw SummaryException.Empty(); }
        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw SummaryException.Empty();
            if (root.TryGetProperty("stop_reason", out var stop) && stop.ValueKind == JsonValueKind.String && stop.GetString() == "refusal")
                throw SummaryException.Refused();
            var parts = new List<string>();
            if (root.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.Array)
                foreach (var block in content.EnumerateArray())
                    if (block.ValueKind == JsonValueKind.Object
                        && block.TryGetProperty("type", out var type) && type.GetString() == "text"
                        && block.TryGetProperty("text", out var t) && t.ValueKind == JsonValueKind.String)
                        parts.Add(t.GetString()!);
            var result = string.Join("\n", parts).Trim();
            if (result.Length == 0) throw SummaryException.Empty();
            return result;
        }
    }
}

// MARK: - Claude Code (Abo)

/// <summary>Nutzt die installierte Claude-Code-Kommandozeile im Print-Modus. Läuft über das Claude-Abo,
/// ohne API-Schlüssel. Werkzeuge sind abgeschaltet, die Sitzung wird nicht gespeichert.</summary>
public sealed class ClaudeCodeBackend
{
    /// <summary>Programm plus vorangestellte Argumente (bei npm-Installation: node + cli.js).</summary>
    public sealed record Command(string FileName, IReadOnlyList<string> PrefixArgs);

    private static Command? _cached;
    private static DateTime _cachedAt;

    public static bool IsAvailable => Locate() != null;

    public static Command? Locate()
    {
        if ((DateTime.UtcNow - _cachedAt).TotalSeconds < 30) return _cached;
        _cached = LocateUncached();
        _cachedAt = DateTime.UtcNow;
        return _cached;
    }

    private static IEnumerable<string> PathDirs()
        => (Environment.GetEnvironmentVariable("PATH") ?? "")
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(d => d.Trim('"'));

    private static string? FindOnPath(string file)
    {
        foreach (var dir in PathDirs())
        {
            try
            {
                var candidate = Path.Combine(dir, file);
                if (File.Exists(candidate)) return candidate;
            }
            catch (ArgumentException) { }
        }
        return null;
    }

    private static Command? LocateUncached()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!OperatingSystem.IsWindows())
        {
            string[] unix = [$"{home}/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", $"{home}/.npm-global/bin/claude"];
            var hit = unix.FirstOrDefault(File.Exists) ?? FindOnPath("claude");
            return hit == null ? null : new Command(hit, []);
        }

        // Nativer Installer.
        var native = Path.Combine(home, ".local", "bin", "claude.exe");
        if (File.Exists(native)) return new Command(native, []);
        if (FindOnPath("claude.exe") is { } exe) return new Command(exe, []);

        // npm-Installation: Die .cmd-Hülle verträgt keine mehrzeiligen Argumente – deshalb node direkt starten.
        var npmDirs = new List<string> { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm") };
        npmDirs.AddRange(PathDirs());
        foreach (var dir in npmDirs)
        {
            try
            {
                if (!File.Exists(Path.Combine(dir, "claude.cmd"))) continue;
                var cli = Path.Combine(dir, "node_modules", "@anthropic-ai", "claude-code", "cli.js");
                if (!File.Exists(cli)) continue;
                var localNode = Path.Combine(dir, "node.exe");
                var node = File.Exists(localNode) ? localNode : FindOnPath("node.exe");
                if (node != null) return new Command(node, [cli]);
            }
            catch (ArgumentException) { }
        }
        return null;
    }

    public static IReadOnlyList<string> Arguments(Command command) =>
    [
        .. command.PrefixArgs,
        "-p", "--output-format", "text", "--no-session-persistence",
        "--tools", "", "--system-prompt", Summarizer.Instructions,
    ];

    public async Task<string> SummarizeAsync(string text, CancellationToken ct = default)
    {
        var command = Locate() ?? throw SummaryException.Unavailable();
        return await RunAsync(command, "Transkript:\n\n" + text, ct).ConfigureAwait(false);
    }

    private static async Task<string> RunAsync(Command command, string input, CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = command.FileName,
            WorkingDirectory = Storage.Root,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            StandardInputEncoding = new UTF8Encoding(false),
        };
        foreach (var a in Arguments(command)) psi.ArgumentList.Add(a);
        // Keine Vererbung einer laufenden Claude-Code-Sitzung.
        foreach (var key in psi.Environment.Keys.Where(k => k.StartsWith("CLAUDE", StringComparison.OrdinalIgnoreCase)).ToList())
            psi.Environment.Remove(key);

        using var proc = new Process { StartInfo = psi };
        try { proc.Start(); }
        catch (Exception e) { throw SummaryException.ClaudeCode("Start fehlgeschlagen – " + e.Message); }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromMinutes(10));
        try
        {
            var stdout = proc.StandardOutput.ReadToEndAsync(timeout.Token);
            var stderr = proc.StandardError.ReadToEndAsync(timeout.Token);
            try
            {
                await proc.StandardInput.WriteAsync(input.AsMemory(), timeout.Token).ConfigureAwait(false);
                proc.StandardInput.Close();
            }
            catch (IOException) { /* Prozess hat die Eingabe bereits geschlossen – Fehlertext folgt unten. */ }
            await proc.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            var output = (await stdout.ConfigureAwait(false)).Trim();
            var error = (await stderr.ConfigureAwait(false)).Trim();
            if (proc.ExitCode != 0)
            {
                var detail = (error.Length == 0 ? output : error).Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).LastOrDefault();
                throw SummaryException.ClaudeCode(detail ?? $"Exit {proc.ExitCode}");
            }
            if (output.Length == 0) throw SummaryException.ClaudeCode("leere Antwort");
            if (output.StartsWith("Not logged in", StringComparison.OrdinalIgnoreCase))
                throw SummaryException.ClaudeCode("nicht angemeldet – im Terminal „claude“ starten und /login ausführen");
            return output;
        }
        catch (OperationCanceledException)
        {
            try { proc.Kill(entireProcessTree: true); } catch { }
            throw SummaryException.ClaudeCode("abgebrochen oder Zeitüberschreitung");
        }
    }
}
