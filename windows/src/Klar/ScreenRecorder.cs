using System.Diagnostics;
using System.Text;
using Klar.Core;

namespace Klar;

/// <summary>Bildschirmaufnahme des Hauptbildschirms inkl. Systemton als .mp4 (H.264 / AAC).
/// Die Aufnahme selbst läuft im Hilfsprogramm KlarRecorder.exe (ScreenRecorderLib, Media Foundation).</summary>
internal sealed class ScreenRecorder
{
    public static ScreenRecorder Shared { get; } = new();

    public bool IsRecording { get; private set; }
    public bool IsBusy { get; private set; }
    public DateTime? StartedAt { get; private set; }
    public string? LastFile { get; private set; }
    public string? ErrorMessage { get; private set; }
    public IReadOnlyList<string> Files { get; private set; } = [];

    public event Action? Changed;

    /// <summary>Nach dem Beenden die Datei im Explorer zeigen (im Selbsttest abgeschaltet).</summary>
    public bool RevealAfterStop { get; set; } = true;

    private Process? _process;

    private ScreenRecorder() => ReloadFiles();

    private static string HelperPath => Path.Combine(AppContext.BaseDirectory, "recorder", "KlarRecorder.exe");

    public void ReloadFiles()
    {
        try
        {
            Files = [.. new DirectoryInfo(Storage.Recordings).GetFiles("*.mp4").OrderByDescending(f => f.CreationTimeUtc).Select(f => f.FullName)];
        }
        catch { Files = []; }
    }

    public void Toggle()
    {
        if (IsRecording) Stop(); else Start();
    }

    public async void Start()
    {
        if (IsRecording || IsBusy) return;
        ErrorMessage = null;
        if (!File.Exists(HelperPath))
        {
            ErrorMessage = "Das Aufnahme-Hilfsprogramm fehlt (recorder\\KlarRecorder.exe).";
            Notify();
            return;
        }
        var baseName = "Aufnahme " + Format.FileStamp(DateTime.UtcNow);
        var path = Path.Combine(Storage.Recordings, baseName + ".mp4");
        for (var n = 2; File.Exists(path); n++) path = Path.Combine(Storage.Recordings, $"{baseName} ({n}).mp4");

        var psi = new ProcessStartInfo
        {
            FileName = HelperPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Path.GetDirectoryName(HelperPath)!,
        };
        psi.ArgumentList.Add(path);
        if (AppSettings.Shared.RecordMicInScreenRecording) psi.ArgumentList.Add("--mic");

        IsBusy = true;
        Notify();
        // Jeder Start hat seinen eigenen Zustand – späte Meldungen eines alten Prozesses dürfen den neuen nicht stören.
        var started = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        string? failure = null;
        var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is not { } line) return;
            UiThread.Post(() =>
            {
                if (line == "started") started.TrySetResult(true);
                else if (line.StartsWith("failed:", StringComparison.Ordinal))
                {
                    failure = line["failed:".Length..].Trim();
                    started.TrySetResult(false);
                    if (IsRecording && _process == process) ErrorMessage = "Aufnahme abgebrochen: " + failure;
                }
            });
        };
        process.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Log.Write("Aufnahme: " + e.Data); };
        process.Exited += (_, _) =>
        {
            // Wartet, bis auch die letzten Ausgabezeilen („failed: …“) zugestellt sind.
            try { process.WaitForExit(); } catch { }
            UiThread.Post(() =>
            {
                started.TrySetResult(false);
                OnExited(process);
            });
        };
        try
        {
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        }
        catch (Exception e)
        {
            IsBusy = false;
            ErrorMessage = "Aufnahme konnte nicht gestartet werden: " + e.Message;
            Notify();
            return;
        }
        _process = process;

        var ok = await Task.WhenAny(started.Task, Task.Delay(15000)) == started.Task && started.Task.Result;
        IsBusy = false;
        if (!ok)
        {
            if (_process == process)
            {
                try { if (!process.HasExited) process.Kill(); } catch { }
                _process = null;
            }
            ErrorMessage = "Aufnahme konnte nicht gestartet werden" + (failure != null ? ": " + failure : ".")
                + (Shell.VcRuntimeInstalled ? "" : " Die Microsoft-Visual-C++-Laufzeit fehlt (siehe Einstellungen).");
            try { if (File.Exists(path) && new FileInfo(path).Length == 0) File.Delete(path); } catch { }
            Notify();
            return;
        }
        LastFile = path;
        StartedAt = DateTime.UtcNow;
        IsRecording = true;
        Notify();
    }

    private void OnExited(Process process)
    {
        if (_process != process) { process.Dispose(); return; }
        _process = null;
        process.Dispose();
        var wasRecording = IsRecording;
        IsRecording = false;
        StartedAt = null;
        ReloadFiles();
        Notify();
        if (wasRecording && RevealAfterStop && LastFile is { } file && File.Exists(file)) Shell.Reveal(file);
    }

    public async void Stop()
    {
        if (!IsRecording || IsBusy || _process is not { } process) return;
        IsBusy = true;
        Notify();
        try
        {
            await process.StandardInput.WriteLineAsync("stop");
            await process.StandardInput.FlushAsync();
        }
        catch (Exception e) { Log.Write("Aufnahme-Stopp: " + e.Message); }
        // Das Hilfsprogramm schließt die Datei ab und beendet sich; OnExited räumt auf.
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (_process == process && DateTime.UtcNow < deadline) await Task.Delay(100);
        if (_process == process)
        {
            try { process.Kill(); } catch { }
            ErrorMessage = "Die Aufnahme ließ sich nicht sauber abschließen.";
        }
        IsBusy = false;
        Notify();
    }

    /// <summary>Beim Beenden von Klar: laufende Aufnahme noch abschließen lassen.</summary>
    public void StopOnQuit()
    {
        if (_process is not { } process) return;
        try
        {
            process.StandardInput.WriteLine("stop");
            process.StandardInput.Flush();
            process.WaitForExit(8000);
        }
        catch { }
    }

    public void Delete(string path)
    {
        Shell.Recycle(path);
        ReloadFiles();
        Notify();
    }

    private void Notify() => Changed?.Invoke();
}
