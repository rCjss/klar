using Klar.Core;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Klar;

/// <summary>Verwaltet das Sprachmodell und die eine Whisper-Instanz der App.</summary>
internal sealed class SpeechService
{
    public static SpeechService Shared { get; } = new();

    private WhisperTranscriber? _transcriber;
    private readonly System.Windows.Threading.DispatcherTimer _idle;

    private SpeechService()
    {
        // Das geladene Modell belegt mehrere hundert MB. Wird länger nicht diktiert, gibt Klar es wieder frei.
        _idle = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
        _idle.Tick += (_, _) =>
        {
            var t = _transcriber;
            if (t is not { IsLoaded: true }) return;
            var busy = DictationEngine.Shared.State is DictationEngine.Phase.Listening or DictationEngine.Phase.Finishing
                       || MeetingRecorder.Shared.IsRunning || MeetingRecorder.Shared.IsFinishing;
            if (!busy && (DateTime.UtcNow - t.LastUsedUtc).TotalMinutes >= 10) Task.Run(t.Unload);
        };
        _idle.Start();
    }

    public SpeechModel Model => SpeechModels.Find(AppSettings.Shared.WhisperModel);
    public bool IsReady => Model.IsDownloaded;

    /// <summary>Liefert die Erkennung oder – falls sie nicht bereit ist – eine Meldung für den Nutzer.</summary>
    public ITranscriber? Get(out string? problem)
    {
        problem = null;
        if (!Shell.VcRuntimeInstalled)
        {
            problem = "Die Microsoft-Visual-C++-Laufzeit fehlt. Der Download-Link steht in den Einstellungen.";
            return null;
        }
        var model = Model;
        if (!model.IsDownloaded)
        {
            _ = ModelDownloader.Shared.EnsureAsync(model);
            problem = $"Das Sprachmodell wird einmalig geladen ({model.Detail}). Den Fortschritt zeigen die Einstellungen.";
            return null;
        }
        if (_transcriber == null || _transcriber.ModelPath != model.FilePath)
        {
            var old = _transcriber;
            _transcriber = new WhisperTranscriber(model.FilePath);
            if (old != null) Task.Run(old.Dispose);
        }
        return _transcriber;
    }

    public string StatusText
    {
        get
        {
            var d = ModelDownloader.Shared;
            var model = Model;
            if (d.Active is { } active) return $"{active.Label} wird geladen … {d.Progress * 100:0} %";
            if (d.Error is { } error && !model.IsDownloaded) return error;
            return model.IsDownloaded ? $"{model.Label} ist geladen und bereit." : $"{model.Label} ist noch nicht geladen ({model.Detail}).";
        }
    }
}

/// <summary>Nimmt Mikrofon oder Systemton (Loopback) über WASAPI auf und liefert 16 kHz Mono.</summary>
internal sealed class AudioCapture : IDisposable
{
    private readonly WasapiCapture _capture;
    private readonly Resampler _resampler;
    private readonly Action<float[]> _sink;
    private readonly int _bits;
    private readonly bool _float;
    private bool _disposed;

    /// <summary>Die Aufnahme ist beendet; bei einem Fehler mit Ausnahme.</summary>
    public event Action<Exception?>? Stopped;

    public static AudioCapture Microphone(Action<float[]> sink) => new(new WasapiCapture(), sink);
    public static AudioCapture SystemAudio(Action<float[]> sink) => new(new WasapiLoopbackCapture(), sink);

    private AudioCapture(WasapiCapture capture, Action<float[]> sink)
    {
        _capture = capture;
        _sink = sink;
        var format = capture.WaveFormat;
        if (format is WaveFormatExtensible ext) format = ext.ToStandardWaveFormat();
        _float = format.Encoding == WaveFormatEncoding.IeeeFloat;
        if (!_float && format.Encoding != WaveFormatEncoding.Pcm)
        {
            capture.Dispose();
            throw new NotSupportedException("Audioformat wird nicht unterstützt: " + format.Encoding);
        }
        _bits = format.BitsPerSample;
        _resampler = new Resampler(format.SampleRate, format.Channels);
        capture.DataAvailable += OnData;
        capture.RecordingStopped += (_, e) => Stopped?.Invoke(e.Exception);
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded <= 0) return;
        try
        {
            var samples = PcmDecoder.ToFloat(e.Buffer.AsSpan(0, e.BytesRecorded), _bits, _float);
            var output = _resampler.Process(samples);
            if (output.Length > 0) _sink(output);
        }
        catch (Exception ex) { Log.Write("Audio-Verarbeitung: " + ex.Message); }
    }

    public void Start() => _capture.StartRecording();

    public void Stop()
    {
        try { if (_capture.CaptureState != CaptureState.Stopped) _capture.StopRecording(); }
        catch (Exception e) { Log.Write("Audio-Stopp: " + e.Message); }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Stop();
        // NAudio beendet den Aufnahme-Thread asynchron; erst danach freigeben.
        Task.Run(async () =>
        {
            await Task.Delay(300);
            try { _capture.Dispose(); } catch { }
        });
    }

    /// <summary>Verständliche Meldung für typische Fehler beim Öffnen eines Geräts.</summary>
    public static string Describe(Exception e, string device)
    {
        var code = (uint)e.HResult;
        if (code == 0x80070005) return $"Kein Zugriff auf {device}. Windows-Einstellungen → Datenschutz und Sicherheit → Mikrofon → Zugriff für Desktop-Apps erlauben.";
        if (code is 0x80070490 or 0x88890004) return $"Kein Gerät für {device} gefunden.";
        return $"{device} konnte nicht gestartet werden: {e.Message}";
    }
}
