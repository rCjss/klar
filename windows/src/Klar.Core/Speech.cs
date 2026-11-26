using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Channels;
using SherpaOnnx;
using Whisper.net;

namespace Klar.Core;

// MARK: - Sprachmodelle

/// <summary>Womit ein Modell gerechnet wird.</summary>
public enum SpeechModelKind
{
    /// <summary>whisper.cpp, eine einzelne ggml-Datei.</summary>
    Whisper,
    /// <summary>NVIDIA Parakeet über sherpa-onnx, ein Ordner mit Encoder, Decoder, Joiner und Tokens.</summary>
    Parakeet,
}

/// <summary>Eine Datei eines Modells. Die Prüfsumme stellt sicher, dass genau diese Datei ankommt.</summary>
public sealed record SpeechModelFile(string Name, long Bytes, string Sha256);

/// <summary>Lokales Sprachmodell. Wird einmalig von Hugging Face geladen und liegt danach auf dem Gerät.
/// Dieselbe Liste führt die Mac- und iPhone-Fassung in Sources/KlarSpeech/SpeechModels.swift.</summary>
public sealed record SpeechModel(string Id, string Label, SpeechModelKind Kind, string BaseUrl,
    IReadOnlyList<SpeechModelFile> Files, IReadOnlySet<string>? Languages)
{
    public long Bytes => Files.Sum(f => f.Bytes);

    /// <summary>„574 MB“, „1,1 GB“.</summary>
    public string Detail => Bytes < 1_000_000_000
        ? $"{Math.Round(Bytes / 1e6):0} MB"
        : (Bytes / 1e9).ToString("0.0", System.Globalization.CultureInfo.GetCultureInfo("de-DE")) + " GB";

    /// <summary>Datei (Whisper) oder Ordner (Parakeet), den die Erkennung öffnet.</summary>
    public string Path => Kind == SpeechModelKind.Whisper
        ? System.IO.Path.Combine(Storage.Models, Files[0].Name)
        : System.IO.Path.Combine(Storage.Models, Id);

    public string FilePath(SpeechModelFile file) => Kind == SpeechModelKind.Whisper
        ? System.IO.Path.Combine(Storage.Models, file.Name)
        : System.IO.Path.Combine(Path, file.Name);

    public string Url(SpeechModelFile file) => BaseUrl + file.Name;

    public bool Supports(string languageCode) => Languages?.Contains(languageCode) ?? true;

    /// <summary>Alle Dateien vorhanden und vollständig.</summary>
    public bool IsDownloaded
    {
        get
        {
            try { return Files.All(f => new FileInfo(FilePath(f)) is { Exists: true } info && info.Length == f.Bytes); }
            catch { return false; }
        }
    }
}

public static class SpeechModels
{
    private const string WhisperBase =
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/";
    private const string ParakeetBase =
        "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/ed5d745623472f97cfc2e6c2916ee248798fc5a8/";

    /// <summary>Die 25 europäischen Sprachen von Parakeet TDT 0.6B v3. Türkisch gehört nicht dazu.</summary>
    public static readonly IReadOnlySet<string> ParakeetLanguages = new HashSet<string>
    {
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt",
        "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    };

    public static readonly SpeechModel LargeV3 = new("large-v3", "Whisper Large-v3", SpeechModelKind.Whisper, WhisperBase,
        [new("ggml-large-v3-q5_0.bin", 1_081_140_203, "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1")], null);

    public static readonly SpeechModel LargeV3Turbo = new("large-v3-turbo", "Whisper Large-v3 Turbo", SpeechModelKind.Whisper, WhisperBase,
        [new("ggml-large-v3-turbo-q5_0.bin", 574_041_195, "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")], null);

    public static readonly SpeechModel ParakeetV3 = new("parakeet-tdt-0.6b-v3", "Parakeet TDT 0.6B v3", SpeechModelKind.Parakeet, ParakeetBase,
        [
            new("encoder.int8.onnx", 652_282_294, "1afbe69c1ffdabee94755f42e4daf1d93549131a3da11356bda84fcef0f2c479"),
            new("decoder.int8.onnx", 11_845_274, "0222a86147299d4dee90edf95b6d13827edb42ad8b7c9cf0b2582f030937c0b5"),
            new("joiner.int8.onnx", 6_355_277, "cbd02f3696e9944970111fb439d9c3fd365a80374565f13f2b9c7007d253fc98"),
            new("tokens.txt", 93_939, "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"),
        ], ParakeetLanguages);

    public static readonly SpeechModel Default = LargeV3Turbo;
    public static readonly IReadOnlyList<SpeechModel> All = [LargeV3, LargeV3Turbo, ParakeetV3];

    /// <summary>Frühere Modelle („base“, „small“) gibt es nicht mehr; sie werden zum Turbo-Modell.</summary>
    public static SpeechModel Find(string? id) => All.FirstOrDefault(m => m.Id == id) ?? Default;
}

/// <summary>Sprachen, in denen Klar diktiert.</summary>
public sealed record SpeechLanguage(string Id, string Name)
{
    public string Code => Id.Split('-')[0].ToLowerInvariant();
}

public static class SpeechLanguages
{
    public static readonly IReadOnlyList<SpeechLanguage> All =
    [
        new("de-DE", "Deutsch"),
        new("en-US", "Englisch"),
        new("ro-RO", "Rumänisch"),
        new("pl-PL", "Polnisch"),
        new("tr-TR", "Türkisch"),
    ];

    /// <summary>Unbekannte oder nicht mehr angebotene Einstellungen werden zur passenden Sprache oder zu Deutsch.</summary>
    public static SpeechLanguage Find(string? id)
    {
        var exact = All.FirstOrDefault(l => l.Id == id);
        if (exact != null) return exact;
        var code = (id ?? "").Split('-')[0].ToLowerInvariant();
        return All.FirstOrDefault(l => l.Code == code) ?? All[0];
    }
}

/// <summary>Lädt Sprachmodelle herunter. Ereignisse kommen über <see cref="UiThread"/>.</summary>
public sealed class ModelDownloader
{
    public static ModelDownloader Shared { get; } = new();

    private static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };
    private readonly object _gate = new();
    private Task? _task;

    public event Action? Changed;
    public SpeechModel? Active { get; private set; }
    /// <summary>0 bis 1.</summary>
    public double Progress { get; private set; }
    public string? Error { get; private set; }
    public bool IsBusy => Active != null;

    /// <summary>Startet den Download, falls das Modell fehlt. Läuft bereits einer, wird dieser zurückgegeben.</summary>
    public Task EnsureAsync(SpeechModel model)
    {
        lock (_gate)
        {
            if (model.IsDownloaded) return Task.CompletedTask;
            if (_task is { IsCompleted: false }) return _task;
            Active = model;
            Progress = 0;
            Error = null;
            _task = Task.Run(() => DownloadAsync(model));
            Notify();
            return _task;
        }
    }

    private async Task DownloadAsync(SpeechModel model)
    {
        try
        {
            if (model.Kind == SpeechModelKind.Parakeet) Directory.CreateDirectory(model.Path);
            long before = 0;
            var lastStep = -1;
            foreach (var file in model.Files)
            {
                var target = model.FilePath(file);
                if (new FileInfo(target) is not { Exists: true } info || info.Length != file.Bytes)
                {
                    var offset = before;
                    await DownloadFileAsync(model.Url(file), target, file, done =>
                    {
                        var step = (int)((offset + done) * 100 / Math.Max(1, model.Bytes));
                        if (step == lastStep) return;
                        lastStep = step;
                        Progress = Math.Min(1, (offset + done) / (double)Math.Max(1, model.Bytes));
                        Notify();
                    }).ConfigureAwait(false);
                }
                before += file.Bytes;
            }
            Progress = 1;
        }
        catch (Exception e)
        {
            Error = "Sprachmodell konnte nicht geladen werden: " + e switch
            {
                OperationCanceledException => "Die Verbindung steht still.",
                InvalidDataException => "Die Datei ist beschädigt angekommen.",
                _ => e.Message,
            };
            Log.Write(Error);
        }
        finally
        {
            Active = null;
            Notify();
        }
    }

    /// <summary>Eine Datei laden, Größe und SHA-256 prüfen, dann an ihren Platz legen.</summary>
    private static async Task DownloadFileAsync(string url, string target, SpeechModelFile file, Action<long> progress)
    {
        var part = target + ".part";
        try
        {
            // Bleibt die Verbindung eine Minute lang stehen, bricht der Download ab und lässt sich neu starten.
            using var stall = new CancellationTokenSource();
            stall.CancelAfter(TimeSpan.FromSeconds(60));
            using var response = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, stall.Token).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            using var sha = System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256);
            await using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
            await using (var output = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
            {
                var buffer = new byte[1 << 16];
                long done = 0;
                int n;
                while ((n = await input.ReadAsync(buffer, stall.Token).ConfigureAwait(false)) > 0)
                {
                    stall.CancelAfter(TimeSpan.FromSeconds(60));
                    await output.WriteAsync(buffer.AsMemory(0, n)).ConfigureAwait(false);
                    sha.AppendData(buffer, 0, n);
                    done += n;
                    progress(done);
                }
                if (done != file.Bytes) throw new IOException("Download unvollständig.");
            }
            if (Convert.ToHexStringLower(sha.GetHashAndReset()) != file.Sha256) throw new InvalidDataException("Prüfsumme stimmt nicht.");
            File.Move(part, target, overwrite: true);
        }
        catch
        {
            try { File.Delete(part); } catch { }
            throw;
        }
    }

    private void Notify() => UiThread.Post(() => Changed?.Invoke());
}

// MARK: - Audio-Aufbereitung

/// <summary>Wandelt beliebiges PCM (Float, verschachtelte Kanäle) in 16 kHz Mono um – das Format,
/// das Whisper erwartet. Tiefpass per gefenstertem Sinc, danach lineare Interpolation.</summary>
public sealed class Resampler
{
    public const int TargetRate = 16000;

    private readonly int _channels;
    private readonly bool _passthrough;
    private readonly double _step;
    private readonly float[] _taps;
    private float[] _history;
    private double _pos;
    private float _prev;

    public Resampler(int sourceRate, int channels)
    {
        if (sourceRate <= 0 || channels <= 0) throw new ArgumentException("Ungültiges Audioformat.");
        _channels = channels;
        _passthrough = sourceRate == TargetRate;
        _step = sourceRate / (double)TargetRate;
        _taps = _passthrough || sourceRate < TargetRate ? [1f] : LowPass(sourceRate);
        _history = new float[_taps.Length - 1];
    }

    private static float[] LowPass(int sourceRate)
    {
        const int n = 63;
        var fc = 7200.0 / sourceRate; // Grenzfrequenz knapp unter Nyquist des Zielformats
        var taps = new double[n];
        double sum = 0;
        for (var i = 0; i < n; i++)
        {
            var m = i - (n - 1) / 2.0;
            var sinc = m == 0 ? 2 * fc : Math.Sin(2 * Math.PI * fc * m) / (Math.PI * m);
            var window = 0.54 - 0.46 * Math.Cos(2 * Math.PI * i / (n - 1));
            taps[i] = sinc * window;
            sum += taps[i];
        }
        return taps.Select(t => (float)(t / sum)).ToArray();
    }

    public float[] Process(ReadOnlySpan<float> interleaved)
    {
        var frames = interleaved.Length / _channels;
        if (frames == 0) return [];
        var mono = new float[frames];
        if (_channels == 1) interleaved[..frames].CopyTo(mono);
        else
        {
            for (var f = 0; f < frames; f++)
            {
                float acc = 0;
                var o = f * _channels;
                for (var c = 0; c < _channels; c++) acc += interleaved[o + c];
                mono[f] = acc / _channels;
            }
        }
        if (_passthrough) return mono;

        float[] filtered;
        if (_taps.Length == 1) filtered = mono;
        else
        {
            var h = _history.Length;
            var buf = new float[h + frames];
            _history.CopyTo(buf, 0);
            mono.CopyTo(buf, h);
            filtered = new float[frames];
            var taps = _taps;
            for (var i = 0; i < frames; i++)
            {
                float acc = 0;
                var end = i + h;
                for (var k = 0; k < taps.Length; k++) acc += taps[k] * buf[end - k];
                filtered[i] = acc;
            }
            _history = buf[^h..];
        }

        var output = new List<float>((int)(frames / _step) + 2);
        while (true)
        {
            var i = (int)Math.Floor(_pos);
            if (i + 1 >= frames) break;
            var frac = (float)(_pos - i);
            var a = i >= 0 ? filtered[i] : _prev;
            var b = filtered[i + 1];
            output.Add(a + (b - a) * frac);
            _pos += _step;
        }
        _pos -= frames;
        _prev = filtered[frames - 1];
        return output.ToArray();
    }
}

/// <summary>Wandelt rohe PCM-Bytes der Soundkarte in Float-Samples um (weiterhin verschachtelte Kanäle).</summary>
public static class PcmDecoder
{
    public static float[] ToFloat(ReadOnlySpan<byte> bytes, int bitsPerSample, bool isFloat)
    {
        var width = bitsPerSample / 8;
        if (width <= 0) return [];
        var count = bytes.Length / width;
        var result = new float[count];
        switch (bitsPerSample)
        {
            case 32 when isFloat:
                System.Runtime.InteropServices.MemoryMarshal.Cast<byte, float>(bytes[..(count * 4)]).CopyTo(result);
                break;
            case 16:
                for (var i = 0; i < count; i++) result[i] = BitConverter.ToInt16(bytes.Slice(i * 2, 2)) / 32768f;
                break;
            case 24:
                for (var i = 0; i < count; i++)
                {
                    var o = i * 3;
                    var v = bytes[o] | (bytes[o + 1] << 8) | ((sbyte)bytes[o + 2] << 16);
                    result[i] = v / 8388608f;
                }
                break;
            case 32:
                for (var i = 0; i < count; i++) result[i] = BitConverter.ToInt32(bytes.Slice(i * 4, 4)) / 2147483648f;
                break;
            case 8:
                for (var i = 0; i < count; i++) result[i] = (bytes[i] - 128) / 128f;
                break;
            default:
                throw new NotSupportedException($"Audioformat mit {bitsPerSample} Bit wird nicht unterstützt.");
        }
        return result;
    }
}

public sealed class SegmenterOptions
{
    /// <summary>Sprechpause, die einen Abschnitt beendet.</summary>
    public double PauseSeconds { get; init; } = 0.7;
    /// <summary>Ab dieser Länge genügt eine kurze Pause zum Trennen.</summary>
    public double SoftLimitSeconds { get; init; } = 18;
    public double SoftPauseSeconds { get; init; } = 0.3;
    /// <summary>Whisper verarbeitet 30-Sekunden-Fenster; spätestens hier wird getrennt.</summary>
    public double HardLimitSeconds { get; init; } = 28;
    public double MinSpeechSeconds { get; init; } = 0.24;
    public double PreRollSeconds { get; init; } = 0.3;
    public double KeepTrailingSeconds { get; init; } = 0.2;
    public float MinThreshold { get; init; } = 0.006f;
}

public readonly record struct SpeechSegment(float[] Samples, TimeSpan Start);

/// <summary>Teilt einen 16-kHz-Mono-Strom an Sprechpausen in Abschnitte. Nicht threadsicher.</summary>
public sealed class SpeechSegmenter
{
    private const int Rate = Resampler.TargetRate;
    private const int Frame = 320; // 20 ms
    private const double FrameSeconds = Frame / (double)Rate;

    private readonly SegmenterOptions _o;
    private readonly float[] _frame = new float[Frame];
    private int _frameFill;
    private readonly Queue<float[]> _preRoll = new();
    private readonly int _preRollFrames;
    private List<float>? _segment;
    private TimeSpan _segmentStart;
    private int _speechFrames, _silenceRun, _onsetRun;
    private float _noise = 0.002f;
    private readonly float[] _recent = new float[200]; // Pegel der letzten vier Sekunden
    private int _recentIndex, _recentCount;

    public SpeechSegmenter(SegmenterOptions? options = null)
    {
        _o = options ?? new SegmenterOptions();
        _preRollFrames = Math.Max(2, (int)Math.Round(_o.PreRollSeconds / FrameSeconds));
    }

    /// <summary>Geglätteter Pegel 0 bis 1 für die Anzeige.</summary>
    public float Level { get; private set; }
    public bool InSegment => _segment != null;

    /// <param name="samples">16 kHz Mono.</param>
    /// <param name="now">Zeitpunkt am Ende dieses Blocks.</param>
    public List<SpeechSegment> Append(ReadOnlySpan<float> samples, TimeSpan now)
    {
        var done = new List<SpeechSegment>();
        var offset = 0;
        while (offset < samples.Length)
        {
            var take = Math.Min(Frame - _frameFill, samples.Length - offset);
            samples.Slice(offset, take).CopyTo(_frame.AsSpan(_frameFill));
            _frameFill += take;
            offset += take;
            if (_frameFill < Frame) break;
            _frameFill = 0;
            var remaining = samples.Length - offset;
            var frameEnd = now - TimeSpan.FromSeconds(remaining / (double)Rate);
            if (ProcessFrame(frameEnd) is { } seg) done.Add(seg);
        }
        return done;
    }

    private SpeechSegment? ProcessFrame(TimeSpan frameEnd)
    {
        double sum = 0;
        for (var i = 0; i < Frame; i++) sum += _frame[i] * _frame[i];
        var rms = (float)Math.Sqrt(sum / Frame);
        Level = Level * 0.6f + Math.Min(1f, rms * 8f) * 0.4f;

        // Grundrauschen: langsam nachgeführter Wert aus den leisen Phasen, mindestens aber das Minimum
        // der letzten vier Sekunden. So zählt gleichmäßiges Rauschen (Lüfter) nicht als Dauersprache;
        // echte Sprache fällt zwischen Silben immer wieder fast auf das Grundrauschen ab.
        _recent[_recentIndex] = rms;
        _recentIndex = (_recentIndex + 1) % _recent.Length;
        if (_recentCount < _recent.Length) _recentCount++;
        var windowMin = 0f;
        if (_recentCount >= 50)
        {
            windowMin = float.MaxValue;
            for (var i = 0; i < _recentCount; i++) windowMin = Math.Min(windowMin, _recent[i]);
        }
        var floor = Math.Clamp(Math.Max(_noise, windowMin), 0.0003f, 0.05f);
        var threshold = Math.Max(_o.MinThreshold, floor * 3f);
        var speech = rms > threshold;
        if (!speech)
        {
            _noise = rms < _noise ? _noise * 0.7f + rms * 0.3f : _noise * 0.995f + rms * 0.005f;
            _noise = Math.Clamp(_noise, 0.0003f, 0.03f);
        }

        if (_segment == null)
        {
            _preRoll.Enqueue((float[])_frame.Clone());
            while (_preRoll.Count > _preRollFrames) _preRoll.Dequeue();
            _onsetRun = speech ? _onsetRun + 1 : 0;
            if (_onsetRun < 2) return null;
            _segment = new List<float>(Rate * 8);
            foreach (var f in _preRoll) _segment.AddRange(f);
            _segmentStart = frameEnd - TimeSpan.FromSeconds(_preRoll.Count * FrameSeconds);
            if (_segmentStart < TimeSpan.Zero) _segmentStart = TimeSpan.Zero;
            _preRoll.Clear();
            _speechFrames = _onsetRun;
            _silenceRun = 0;
            _onsetRun = 0;
            return null;
        }

        _segment.AddRange(_frame);
        if (speech) { _speechFrames++; _silenceRun = 0; } else _silenceRun++;

        var length = _segment.Count / (double)Rate;
        var silence = _silenceRun * FrameSeconds;
        if (silence >= _o.PauseSeconds
            || (length >= _o.SoftLimitSeconds && silence >= _o.SoftPauseSeconds)
            || length >= _o.HardLimitSeconds)
            return Close();
        return null;
    }

    /// <summary>Kommt kein Ton mehr (z. B. Systemton pausiert), endet der laufende Abschnitt.</summary>
    public SpeechSegment? CloseIfIdle(TimeSpan idleFor)
        => _segment != null && idleFor.TotalSeconds >= _o.PauseSeconds ? Close() : null;

    /// <summary>Am Ende der Aufnahme: den offenen Abschnitt abschließen.</summary>
    public SpeechSegment? Flush()
    {
        _frameFill = 0;
        _onsetRun = 0;
        _preRoll.Clear();
        return _segment != null ? Close() : null;
    }

    private SpeechSegment? Close()
    {
        var samples = _segment!;
        var start = _segmentStart;
        var speech = _speechFrames * FrameSeconds;
        var trailing = _silenceRun * Frame;
        _segment = null;
        _speechFrames = 0;
        _silenceRun = 0;
        if (speech < _o.MinSpeechSeconds) return null;
        var keep = (int)(_o.KeepTrailingSeconds * Rate);
        var cut = Math.Max(0, trailing - keep);
        var length = samples.Count - cut;
        var result = new float[length];
        samples.CopyTo(0, result, 0, length);
        return new SpeechSegment(result, start);
    }
}

// MARK: - Erkennung

public interface ITranscriber
{
    /// <param name="samples">16 kHz Mono.</param>
    /// <param name="language">Sprachcode, z. B. „de“.</param>
    /// <param name="hint">Wörter, die wahrscheinlich vorkommen (Befehle, Namen) – verbessert deren Schreibweise.</param>
    Task<string> TranscribeAsync(float[] samples, string language, string? hint, CancellationToken ct);
}

/// <summary>Whisper erfindet bei Stille gern Abspänne. Solche Ausgaben werden verworfen.</summary>
public static class HallucinationFilter
{
    private static readonly Regex Annotation = new(
        @"\[[^\]]{0,40}\]|\*[^*]{0,40}\*|\((?:musik|music|applaus|applause|lachen|laughter|laughs|stille|silence|räuspern|husten)[^)]{0,20}\)|♪+",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static readonly string[] Phrases =
    [
        "vielen dank fürs zuschauen", "vielen dank für s zuschauen", "danke fürs zuschauen",
        "thanks for watching", "thank you for watching", "bis zum nächsten mal",
        "sous titres réalisés para la communauté d amara org", "sous titres réalisés par la communauté d amara org",
        "sottotitoli creati dalla comunità amara org", "subtítulos realizados por la comunidad de amara org",
        "subtitles by the amara org community",
    ];

    public static string Clean(string text)
    {
        var t = Annotation.Replace(text, " ");
        t = Regex.Replace(t, @"[ \t]{2,}", " ").Trim();
        if (t.Length == 0) return "";
        var n = VoiceCommands.Normalize(t);
        if (n.Length == 0) return "";
        if (n.Length < 90 && (n.StartsWith("untertitel", StringComparison.Ordinal) || n.Contains("amara org"))) return "";
        if (Phrases.Contains(n)) return "";
        return t;
    }
}

/// <summary>Nimmt Ton entgegen, teilt ihn an Sprechpausen und lässt die Abschnitte der Reihe nach
/// transkribieren. <see cref="Append"/> darf von Audio-Threads kommen; Ereignisse kommen vom Arbeits-Thread.</summary>
public sealed class TranscriptionSession
{
    private readonly ITranscriber _transcriber;
    private readonly string _language;
    private readonly string? _hint;
    private readonly Func<TimeSpan> _clock;
    private readonly SpeechSegmenter _segmenter;
    private readonly object _gate = new();
    private readonly Channel<SpeechSegment> _queue = Channel.CreateUnbounded<SpeechSegment>(new UnboundedChannelOptions { SingleReader = true });
    private readonly CancellationTokenSource _cts = new();
    private readonly Task _worker;
    private readonly Timer _idleTimer;
    private TimeSpan _lastAppend;
    private bool _stopped;
    private int _pending;

    /// <summary>Text eines fertig erkannten Abschnitts und dessen Beginn.</summary>
    public event Action<string, TimeSpan>? Committed;
    /// <summary>Anzahl der Abschnitte, die noch erkannt werden.</summary>
    public event Action<int>? PendingChanged;
    public event Action<Exception>? Failed;

    public TranscriptionSession(ITranscriber transcriber, string language, Func<TimeSpan>? clock = null,
                                SegmenterOptions? options = null, string? hint = null)
    {
        _transcriber = transcriber;
        _language = language;
        _hint = hint;
        if (clock == null)
        {
            var sw = Stopwatch.StartNew();
            clock = () => sw.Elapsed;
        }
        _clock = clock;
        _segmenter = new SpeechSegmenter(options);
        _lastAppend = _clock();
        _worker = Task.Run(WorkAsync);
        _idleTimer = new Timer(_ => CheckIdle(), null, 250, 250);
    }

    public float Level => _segmenter.Level;
    public int Pending => Volatile.Read(ref _pending);

    public void Append(ReadOnlySpan<float> samples16k)
    {
        List<SpeechSegment> done;
        lock (_gate)
        {
            if (_stopped) return;
            _lastAppend = _clock();
            done = _segmenter.Append(samples16k, _lastAppend);
        }
        foreach (var s in done) Enqueue(s);
    }

    private void CheckIdle()
    {
        SpeechSegment? seg;
        lock (_gate)
        {
            if (_stopped) return;
            seg = _segmenter.CloseIfIdle(_clock() - _lastAppend);
        }
        if (seg is { } s) Enqueue(s);
    }

    private void Enqueue(SpeechSegment s)
    {
        PendingChanged?.Invoke(Interlocked.Increment(ref _pending));
        _queue.Writer.TryWrite(s);
    }

    /// <summary>Schließt den offenen Abschnitt ab und wartet, bis alles erkannt ist.</summary>
    public async Task StopAsync()
    {
        SpeechSegment? last;
        lock (_gate)
        {
            if (_stopped) { last = null; }
            else
            {
                _stopped = true;
                last = _segmenter.Flush();
            }
        }
        if (last is { } s) Enqueue(s);
        _queue.Writer.TryComplete();
        await _idleTimer.DisposeAsync().ConfigureAwait(false);
        await _worker.ConfigureAwait(false);
    }

    /// <summary>Verwirft alles Ausstehende.</summary>
    public void Cancel()
    {
        lock (_gate) _stopped = true;
        _cts.Cancel();
        _queue.Writer.TryComplete();
        _idleTimer.Dispose();
    }

    private async Task WorkAsync()
    {
        try
        {
            await foreach (var seg in _queue.Reader.ReadAllAsync(_cts.Token).ConfigureAwait(false))
            {
                try
                {
                    var text = await _transcriber.TranscribeAsync(seg.Samples, _language, _hint, _cts.Token).ConfigureAwait(false);
                    text = HallucinationFilter.Clean(text);
                    if (text.Length > 0) Committed?.Invoke(text, seg.Start);
                }
                catch (OperationCanceledException) { return; }
                catch (Exception e)
                {
                    Log.Write("Erkennung fehlgeschlagen: " + e);
                    Failed?.Invoke(e);
                }
                finally
                {
                    PendingChanged?.Invoke(Interlocked.Decrement(ref _pending));
                }
            }
        }
        catch (OperationCanceledException) { }
    }
}

/// <summary>Eine lokale Erkennung mit geladenem Modell (Whisper oder Parakeet).</summary>
public interface ILocalTranscriber : ITranscriber, IDisposable
{
    /// <summary>Datei (Whisper) oder Ordner (Parakeet).</summary>
    string ModelPath { get; }
    /// <summary>Zeitpunkt der letzten Erkennung – danach richtet sich, wann das Modell wieder entladen wird.</summary>
    DateTime LastUsedUtc { get; }
    bool IsLoaded { get; }
    /// <summary>Lädt das Modell vorab, damit das erste Diktat nicht darauf warten muss.</summary>
    Task WarmUpAsync();
    /// <summary>Gibt das Modell frei. Beim nächsten Aufruf wird es neu geladen.</summary>
    void Unload();
}

public static class LocalTranscriber
{
    public static ILocalTranscriber Create(SpeechModel model) => Create(model.Path);

    /// <summary>Ein Ordner ist ein Parakeet-Modell, eine Datei ein Whisper-Modell.</summary>
    public static ILocalTranscriber Create(string path) =>
        Directory.Exists(path) ? new ParakeetTranscriber(path) : new WhisperTranscriber(path);
}

/// <summary>Lokale Spracherkennung mit Whisper (whisper.cpp). Ein Modell, Aufrufe laufen nacheinander.</summary>
public sealed class WhisperTranscriber(string modelPath) : ILocalTranscriber
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private WhisperFactory? _factory;
    private WhisperProcessor? _processor;
    private string? _processorKey;
    private bool _disposed;

    public string ModelPath { get; } = modelPath;
    /// <summary>Zeitpunkt der letzten Erkennung – danach richtet sich, wann das Modell wieder entladen wird.</summary>
    public DateTime LastUsedUtc { get; private set; } = DateTime.UtcNow;
    public bool IsLoaded => _factory != null;

    private static int Threads => Math.Clamp(Environment.ProcessorCount / 2, 2, 8);

    /// <summary>Lädt das Modell vorab, damit das erste Diktat nicht darauf warten muss.</summary>
    public Task WarmUpAsync() => TranscribeAsync(new float[Resampler.TargetRate], "de", null, CancellationToken.None);

    public async Task<string> TranscribeAsync(float[] samples, string language, string? hint, CancellationToken ct)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            LastUsedUtc = DateTime.UtcNow;
            return await Task.Run(async () =>
            {
                _factory ??= WhisperFactory.FromPath(ModelPath);
                var key = language + "\n" + hint;
                if (_processor == null || _processorKey != key)
                {
                    _processor?.Dispose();
                    var builder = _factory.CreateBuilder()
                        .WithLanguage(language)
                        .WithThreads(Threads)
                        .WithNoContext();
                    if (!string.IsNullOrWhiteSpace(hint)) builder = builder.WithPrompt(hint);
                    _processor = builder.Build();
                    _processorKey = key;
                }
                // whisper.cpp verwirft Eingaben unter einer Sekunde – kurze Abschnitte mit Stille auffüllen.
                var minimum = (int)(Resampler.TargetRate * 1.25);
                var input = samples;
                if (input.Length < minimum)
                {
                    input = new float[minimum];
                    samples.CopyTo(input, 0);
                }
                var sb = new StringBuilder();
                await foreach (var seg in _processor.ProcessAsync(input, ct).ConfigureAwait(false))
                {
                    if (seg.NoSpeechProbability > 0.8f) continue;
                    sb.Append(seg.Text);
                }
                return sb.ToString().Trim();
            }, ct).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    /// <summary>Gibt das Modell frei (mehrere hundert MB Arbeitsspeicher). Beim nächsten Aufruf wird es neu geladen.</summary>
    public void Unload()
    {
        _gate.Wait();
        try
        {
            _processor?.Dispose();
            _factory?.Dispose();
            _processor = null;
            _factory = null;
            _processorKey = null;
        }
        finally { _gate.Release(); }
    }

    public void Dispose()
    {
        _gate.Wait();
        try
        {
            _disposed = true;
            _processor?.Dispose();
            _factory?.Dispose();
            _processor = null;
            _factory = null;
        }
        finally { _gate.Release(); }
    }
}

/// <summary>Lokale Spracherkennung mit NVIDIA Parakeet TDT 0.6B v3 über sherpa-onnx. Erkennt die Sprache selbst
/// (25 europäische Sprachen) und setzt Satzzeichen. Aufrufe laufen nacheinander.</summary>
public sealed class ParakeetTranscriber(string modelDirectory) : ILocalTranscriber
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private OfflineRecognizer? _recognizer;
    private bool _disposed;

    public string ModelPath { get; } = modelDirectory;
    public DateTime LastUsedUtc { get; private set; } = DateTime.UtcNow;
    public bool IsLoaded => _recognizer != null;

    private static int Threads => Math.Clamp(Environment.ProcessorCount / 2, 2, 8);

    public Task WarmUpAsync() => TranscribeAsync(new float[Resampler.TargetRate], "de", null, CancellationToken.None);

    private OfflineRecognizer Load()
    {
        var config = new OfflineRecognizerConfig();
        config.FeatConfig.SampleRate = Resampler.TargetRate;
        config.FeatConfig.FeatureDim = 80;
        config.ModelConfig.Transducer.Encoder = Path.Combine(ModelPath, "encoder.int8.onnx");
        config.ModelConfig.Transducer.Decoder = Path.Combine(ModelPath, "decoder.int8.onnx");
        config.ModelConfig.Transducer.Joiner = Path.Combine(ModelPath, "joiner.int8.onnx");
        config.ModelConfig.Tokens = Path.Combine(ModelPath, "tokens.txt");
        config.ModelConfig.ModelType = "nemo_transducer";
        config.ModelConfig.Provider = "cpu";
        config.ModelConfig.NumThreads = Threads;
        config.ModelConfig.Debug = 0;
        config.DecodingMethod = "greedy_search";
        foreach (var file in new[] { config.ModelConfig.Transducer.Encoder, config.ModelConfig.Transducer.Decoder,
                     config.ModelConfig.Transducer.Joiner, config.ModelConfig.Tokens })
        {
            if (!File.Exists(file)) throw new FileNotFoundException("Parakeet-Modell unvollständig.", file);
        }
        return new OfflineRecognizer(config);
    }

    /// <param name="language">Wird nicht gebraucht – Parakeet erkennt die Sprache selbst.</param>
    /// <param name="hint">Wird nicht gebraucht – Parakeet kennt keinen Hinweis auf erwartete Wörter.</param>
    public async Task<string> TranscribeAsync(float[] samples, string language, string? hint, CancellationToken ct)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            LastUsedUtc = DateTime.UtcNow;
            return await Task.Run(() =>
            {
                _recognizer ??= Load();
                // Etwas Stille anhängen, sonst fehlt das letzte Wort gelegentlich.
                var input = new float[samples.Length + Resampler.TargetRate / 4];
                samples.CopyTo(input, 0);
                using var stream = _recognizer.CreateStream();
                stream.AcceptWaveform(Resampler.TargetRate, input);
                _recognizer.Decode(stream);
                return (stream.Result.Text ?? "").Trim();
            }, ct).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    public void Unload()
    {
        _gate.Wait();
        try
        {
            _recognizer?.Dispose();
            _recognizer = null;
        }
        finally { _gate.Release(); }
    }

    public void Dispose()
    {
        _gate.Wait();
        try
        {
            _disposed = true;
            _recognizer?.Dispose();
            _recognizer = null;
        }
        finally { _gate.Release(); }
    }
}
