using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Klar.Core;

/// <summary>Ablage aller Daten im Benutzerprofil (%AppData%\Klar). Der Profilordner ist unter Windows
/// bereits nur für den eigenen Benutzer lesbar.</summary>
public static class Storage
{
    private static string? _root, _recordings, _models;

    /// <summary>Für Tests oder abweichende Speicherorte. Muss vor dem ersten Zugriff gesetzt werden.</summary>
    public static void Configure(string root, string? recordings = null, string? models = null)
    {
        _root = MakeDir(root);
        _recordings = recordings == null ? null : MakeDir(recordings);
        _models = models == null ? null : MakeDir(models);
    }

    public static string MakeDir(string dir)
    {
        Directory.CreateDirectory(dir);
        return dir;
    }

    public static string Root => _root ??= MakeDir(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Klar"));

    public static string Images => MakeDir(Path.Combine(Root, "Images"));
    public static string Gifs => MakeDir(Path.Combine(Root, "GIFs"));

    public static string Recordings => _recordings ??= MakeDir(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.MyVideos) is { Length: > 0 } v ? v : Root, "Klar"));

    /// <summary>Sprachmodelle sind groß und gehören nicht ins Roaming-Profil.</summary>
    public static string Models => _models ??= MakeDir(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) is { Length: > 0 } l ? l : Root, "Klar", "Models"));

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public static T? Load<T>(string name) where T : class
    {
        var path = Path.Combine(Root, name);
        try
        {
            if (!File.Exists(path)) return null;
            return JsonSerializer.Deserialize<T>(File.ReadAllBytes(path), Json);
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            // Unlesbare Datei nicht überschreiben, sondern zur Seite legen.
            try { File.Copy(path, path + ".defekt", overwrite: true); } catch { }
            return null;
        }
    }

    public static void Save<T>(T value, string name)
    {
        var path = Path.Combine(Root, name);
        var tmp = path + ".tmp";
        try
        {
            File.WriteAllBytes(tmp, JsonSerializer.SerializeToUtf8Bytes(value, Json));
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Write("Speichern fehlgeschlagen: " + name + " – " + e.Message);
        }
    }
}

/// <summary>Verzögert Schreibvorgänge, damit schnelle Änderungen nicht jedes Mal die Datei treffen.</summary>
public sealed class Debouncer
{
    private static readonly List<WeakReference<Debouncer>> All = [];
    private readonly object _gate = new();
    private readonly TimeSpan _delay;
    private readonly Timer _timer;
    private Action? _pending;

    public Debouncer(double delaySeconds = 0.4)
    {
        _delay = TimeSpan.FromSeconds(delaySeconds);
        _timer = new Timer(_ => UiThread.Post(Flush), null, Timeout.Infinite, Timeout.Infinite);
        lock (All) All.Add(new WeakReference<Debouncer>(this));
    }

    public void Call(Action block)
    {
        lock (_gate) _pending = block;
        _timer.Change(_delay, Timeout.InfiniteTimeSpan);
    }

    public void Flush()
    {
        Action? work;
        lock (_gate) { work = _pending; _pending = null; }
        work?.Invoke();
    }

    /// <summary>Beim Beenden der App: nichts Ungespeichertes zurücklassen.</summary>
    public static void FlushAll()
    {
        List<Debouncer> live = [];
        lock (All)
            foreach (var w in All)
                if (w.TryGetTarget(out var d)) live.Add(d);
        foreach (var d in live) d.Flush();
    }
}

/// <summary>Bringt Arbeit auf den UI-Thread. Die Windows-App setzt hier ihren Dispatcher ein;
/// ohne Oberfläche (Tests) läuft die Aktion direkt.</summary>
public static class UiThread
{
    public static Action<Action> Post { get; set; } = a => a();
}

public static class Log
{
    private static readonly object Gate = new();

    public static void Write(string message)
    {
        try
        {
            var path = Path.Combine(Storage.Root, "klar.log");
            lock (Gate)
            {
                var info = new FileInfo(path);
                if (info.Exists && info.Length > 512 * 1024) File.Delete(path);
                File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
            }
        }
        catch { }
    }
}
