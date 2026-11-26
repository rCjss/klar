using System.Diagnostics;
using Klar.Core;

namespace Klar;

/// <summary>Transkribiert Systemton (andere Teilnehmer) und Mikrofon (ich) getrennt
/// und führt beides zeitlich sortiert zusammen.</summary>
internal sealed class MeetingRecorder
{
    public static MeetingRecorder Shared { get; } = new();

    public bool IsRunning { get; private set; }
    public bool IsFinishing { get; private set; }
    public MeetingTranscript? Current { get; private set; }
    public string LiveMe { get; private set; } = "";
    public string LiveOthers { get; private set; } = "";
    public string? ErrorMessage { get; private set; }
    public Guid? LastFinishedId { get; set; }

    public event Action? Changed;

    private AudioCapture? _microphone, _system;
    private TranscriptionSession? _me, _others;
    private int _generation;

    public void Toggle()
    {
        if (IsRunning) Stop(); else Start();
    }

    public void Start()
    {
        if (IsRunning || IsFinishing) return;
        ErrorMessage = null;
        var transcriber = SpeechService.Shared.Get(out var problem);
        if (transcriber == null)
        {
            ErrorMessage = problem ?? "Spracherkennung nicht verfügbar.";
            Notify();
            return;
        }

        var language = AppSettings.Shared.LanguageCode;
        var clock = Stopwatch.StartNew();
        var generation = ++_generation;
        var me = new TranscriptionSession(transcriber, language, () => clock.Elapsed);
        var others = new TranscriptionSession(transcriber, language, () => clock.Elapsed);
        me.Committed += (text, start) => UiThread.Post(() => Append(generation, "Ich", text, start));
        others.Committed += (text, start) => UiThread.Post(() => Append(generation, "Andere", text, start));
        me.PendingChanged += n => UiThread.Post(() => { if (generation == _generation) { LiveMe = n > 0 ? "…" : ""; Notify(); } });
        others.PendingChanged += n => UiThread.Post(() => { if (generation == _generation) { LiveOthers = n > 0 ? "…" : ""; Notify(); } });

        // Systemton über WASAPI-Loopback
        try
        {
            _system = AudioCapture.SystemAudio(samples => others.Append(samples));
            _system.Stopped += e =>
            {
                if (e != null) UiThread.Post(() =>
                {
                    if (generation != _generation || !IsRunning) return;
                    ErrorMessage = "Systemton-Erfassung beendet: " + e.Message;
                    Stop();
                });
            };
            _system.Start();
        }
        catch (Exception e)
        {
            Abort(me, others, "Systemton konnte nicht erfasst werden: " + e.Message);
            return;
        }

        // Mikrofon
        try
        {
            _microphone = AudioCapture.Microphone(samples => me.Append(samples));
            _microphone.Start();
        }
        catch (Exception e)
        {
            Abort(me, others, AudioCapture.Describe(e, "das Mikrofon"));
            return;
        }

        _me = me;
        _others = others;
        var transcript = new MeetingTranscript { Title = "Meeting " + Format.DateTimeText(DateTime.UtcNow) };
        Current = transcript;
        MeetingStore.Shared.Upsert(transcript);
        IsRunning = true;
        Notify();
    }

    private void Abort(TranscriptionSession me, TranscriptionSession others, string message)
    {
        me.Cancel();
        others.Cancel();
        _system?.Dispose();
        _microphone?.Dispose();
        _system = null;
        _microphone = null;
        ErrorMessage = message;
        Notify();
    }

    public async void Stop()
    {
        if (!IsRunning) return;
        IsRunning = false;
        IsFinishing = true;
        _microphone?.Dispose();
        _system?.Dispose();
        _microphone = null;
        _system = null;
        Notify();

        var me = _me;
        var others = _others;
        _me = null;
        _others = null;
        try
        {
            if (me != null) await me.StopAsync();
            if (others != null) await others.StopAsync();
        }
        catch (Exception e) { Log.Write("Meeting-Abschluss: " + e); }
        // Letzte Abschnitte kommen über den Dispatcher – erst danach abschließen.
        await System.Windows.Threading.Dispatcher.Yield(System.Windows.Threading.DispatcherPriority.Background);

        LiveMe = "";
        LiveOthers = "";
        MeetingTranscript? finished = null;
        if (Current is { } t)
        {
            t.EndedAt = DateTime.UtcNow;
            MeetingStore.Shared.Upsert(t);
            finished = t;
        }
        Current = null;
        IsFinishing = false;
        _generation++;
        if (finished != null && AppSettings.Shared.AutoSummarize && finished.Lines.Count > 0)
        {
            LastFinishedId = finished.Id;
            _ = Summarizer.Shared.SummarizeAsync(finished.Id);
        }
        Notify();
    }

    /// <summary>Beim Beenden von Klar: das laufende Meeting mit dem bisher Erkannten abschließen.</summary>
    public void FinishOnQuit()
    {
        if (Current is not { } t) return;
        _generation++;
        _microphone?.Dispose();
        _system?.Dispose();
        _me?.Cancel();
        _others?.Cancel();
        t.EndedAt = DateTime.UtcNow;
        MeetingStore.Shared.Upsert(t);
        Current = null;
        IsRunning = false;
    }

    private void Append(int generation, string speaker, string text, TimeSpan start)
    {
        if (generation != _generation || Current is not { } t) return;
        t.Lines.Add(new TranscriptLine { Time = start.TotalSeconds, Speaker = speaker, Text = text });
        t.Lines = [.. t.Lines.OrderBy(l => l.Time)];
        MeetingStore.Shared.Upsert(t);
        Notify();
    }

    private void Notify() => Changed?.Invoke();
}
