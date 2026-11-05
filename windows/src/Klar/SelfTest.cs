using System.Diagnostics;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Klar.Core;

namespace Klar;

/// <summary>Durchläuft unter Windows einmal alle Fenster und Systemanbindungen und schreibt einen Bericht.
/// Arbeitet in einem eigenen, temporären Datenordner – der echte Verlauf bleibt unberührt.
/// Rückgabewert: Anzahl der fehlgeschlagenen Pflichtschritte.</summary>
internal sealed class SelfTest(App app)
{
    private readonly StringBuilder _report = new();
    private int _failures;

    private void Line(string status, string name, string? detail = null)
        => _report.AppendLine($"{status,-8} {name}{(string.IsNullOrEmpty(detail) ? "" : " – " + detail)}");

    /// <summary>Pflichtschritt: Ein Fehler zählt.</summary>
    private async Task Step(string name, Func<Task<string?>> body)
    {
        try { Line("OK", name, await body()); }
        catch (Exception e)
        {
            _failures++;
            Line("FEHLER", name, e.GetType().Name + ": " + e.Message);
        }
    }

    private Task Check(string name, Func<string?> body) => Step(name, () => Task.FromResult(body()));

    /// <summary>Schritt, der von der Hardware abhängt (Mikrofon, Bildschirm): Ein Fehler ist nur ein Hinweis.</summary>
    private async Task Optional(string name, Func<Task<string?>> body)
    {
        try { Line("OK", name, await body()); }
        catch (Exception e) { Line("HINWEIS", name, e.GetType().Name + ": " + e.Message); }
    }

    public async Task<int> RunAsync(string reportPath)
    {
        var dir = Path.Combine(Path.GetTempPath(), "klar-selftest-" + Guid.NewGuid().ToString("N")[..8]);
        Storage.Configure(dir, Path.Combine(dir, "Videos"), Environment.GetEnvironmentVariable("KLAR_SELFTEST_MODELS"));
        UiThread.Post = action => app.Dispatcher.BeginInvoke(action);
        AppSettings.Secrets = new CredentialStore();
        AppSettings.FullUserName = Native.FullUserName;
        app.DispatcherUnhandledException += (_, args) =>
        {
            _failures++;
            Line("FEHLER", "Unbehandelte Ausnahme", args.Exception.ToString());
            args.Handled = true;
        };
        _report.AppendLine($"Klar {MainWindow.VersionText} Selbsttest, {DateTime.Now:yyyy-MM-dd HH:mm:ss}, {Environment.OSVersion}, .NET {Environment.Version}");

        await Check("Einstellungen", () => $"Signatur: {AppSettings.Shared.Snippets[0].Text.Replace("\n", " / ")}");
        await Check("Design", () => { Theme.Start(); return Theme.IsDark ? "dunkel" : "hell"; });

        await Check("Tastenkürzel", () =>
        {
            var s = AppSettings.Shared;
            var hk = HotkeyManager.Shared;
            (int Id, Hotkey Key)[] all =
            [
                (HotkeyId.Clipboard, s.ClipboardHotkey), (HotkeyId.Dictation, s.DictationHotkey), (HotkeyId.Meeting, s.MeetingHotkey),
                (HotkeyId.Recording, s.RecordingHotkey), (HotkeyId.Awake, s.AwakeHotkey),
            ];
            foreach (var (id, key) in all) hk.Set(id, key, () => { }, () => { });
            hk.Set(99, new Hotkey(Hotkey.VkRControl, HotkeyModifiers.None), () => { }, () => { }, () => { });
            var taken = all.Where(b => hk.Error(b.Id) != null).Select(b => b.Key.Display).ToList();
            var hook = hk.HookInstalled;
            hk.Shutdown();
            if (!hook) throw new InvalidOperationException("Tastatur-Hook ließ sich nicht installieren");
            return (taken.Count == 0 ? "alle fünf registriert" : "belegt: " + string.Join(", ", taken)) + ", Tastatur-Hook installiert";
        });

        string? before = null;
        try { if (Clipboard.ContainsText()) before = Clipboard.GetText(); } catch { }
        await Step("Zwischenablage schreiben und lesen", async () =>
        {
            var token = "Klar-Selbsttest " + Guid.NewGuid().ToString("N")[..6];
            ClipboardMonitor.Shared.Start();
            Paster.WriteText(token);
            await Task.Delay(300);
            var read = Clipboard.GetText();
            if (read != token) throw new InvalidOperationException($"gelesen „{read}“");
            var own = ClipboardStore.Shared.Items.Count;
            // Eine fremde Kopie simulieren: nach Ablauf der Schonfrist ohne Vermerk schreiben.
            await Task.Delay(500);
            Clipboard.SetDataObject(new DataObject(DataFormats.UnicodeText, token + " fremd"), true);
            await Task.Delay(600);
            var seen = ClipboardStore.Shared.Items.Any(i => i.Text == token + " fremd");
            if (own != 0) throw new InvalidOperationException("eigenes Schreiben landete im Verlauf");
            if (!seen) throw new InvalidOperationException("fremde Kopie wurde nicht erfasst");
            return "eigenes Schreiben ignoriert, fremde Kopie erfasst";
        });

        await Check("Verlauf mit Text, Datei und Bild", () =>
        {
            var name = Guid.NewGuid().ToString("D").ToUpperInvariant() + ".png";
            var bmp = new RenderTargetBitmap(64, 48, 96, 96, PixelFormats.Pbgra32);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bmp));
            using (var f = File.Create(Path.Combine(Storage.Images, name))) encoder.Save(f);
            var store = ClipboardStore.Shared;
            store.Add(new ClipItem { Kind = ClipKind.Image, ImageFile = name, SourceApp = "Selbsttest" });
            store.Add(new ClipItem { Kind = ClipKind.Files, Files = [Environment.ProcessPath ?? "Klar.exe"] });
            for (var i = 0; i < 12; i++) store.Add(new ClipItem { Kind = ClipKind.Text, Text = $"Eintrag {i}\nzweite Zeile", SourceApp = "Selbsttest" });
            store.TogglePin(store.Items[3].Id);
            var image = store.Items.First(i => i.Kind == ClipKind.Image);
            Paster.Write(image);
            if (!Clipboard.ContainsImage()) throw new InvalidOperationException("Bild kam nicht in der Zwischenablage an");
            DictationStore.Shared.Add(new Dictation { Text = "Das ist ein Testdiktat.", Duration = 3, UsedSnippet = "Signatur" });
            var m = new MeetingTranscript { Title = "Testmeeting", EndedAt = DateTime.UtcNow.AddMinutes(5), Summary = "## Kurzfassung\nKurz.\n## Aufgaben\n- **Alex** prüft die Zahlen" };
            m.Lines.Add(new TranscriptLine { Time = 3, Speaker = "Ich", Text = "Hallo zusammen." });
            m.Lines.Add(new TranscriptLine { Time = 9, Speaker = "Andere", Text = "Guten Morgen." });
            MeetingStore.Shared.Upsert(m);
            MeetingRecorder.Shared.LastFinishedId = m.Id;
            return $"{store.Items.Count} Einträge";
        });

        MainWindow? window = null;
        await Step("Hauptfenster und alle Seiten", async () =>
        {
            window = new MainWindow();
            window.Show();
            var sizes = new List<string>();
            foreach (var section in Sections.All)
            {
                window.Navigate(section);
                await Task.Delay(250);
                window.UpdateLayout();
                var page = FindPage(window) ?? throw new InvalidOperationException(section.Title() + ": keine Seite");
                if (page.ActualHeight < 50 || VisualTreeHelper.GetChildrenCount(page) == 0)
                    throw new InvalidOperationException($"{section.Title()}: leer ({page.ActualWidth:0}×{page.ActualHeight:0})");
                sizes.Add($"{section.Title()} {page.ActualWidth:0}×{page.ActualHeight:0}");
            }
            // Meetings: Liste statt Detailansicht
            MeetingRecorder.Shared.LastFinishedId = null;
            window.Navigate(Section.Meetings);
            await Task.Delay(200);
            Theme.Apply(); // Neuzeichnen nach Designwechsel
            await Task.Delay(200);
            return string.Join(", ", sizes);
        });

        await Step("Zwischenablage-Panel", async () =>
        {
            var panel = new ClipboardPanel();
            panel.ShowPanel();
            await Task.Delay(300);
            var visible = panel.IsVisible;
            var size = $"{panel.ActualWidth:0}×{panel.ActualHeight:0} bei {panel.Left:0},{panel.Top:0}";
            panel.SwitchTab(PanelTab.Gifs);
            await Task.Delay(300);
            panel.SwitchTab(PanelTab.History);
            await Task.Delay(100);
            panel.HidePanel();
            if (!visible) throw new InvalidOperationException("Panel wurde nicht sichtbar (oder verlor sofort den Fokus)");
            return size;
        });

        await Step("Diktat-Einblendung", async () =>
        {
            var overlay = new DictationOverlay();
            overlay.Present();
            await Task.Delay(250);
            var where = $"{overlay.Left:0},{overlay.Top:0}";
            overlay.Hide();
            return where;
        });

        await Step("Infobereich-Symbol", async () =>
        {
            using var tray = new TrayIcon(app);
            AwakeManager.Shared.Start(60);
            tray.Refresh();
            await Task.Delay(150);
            var status = AwakeManager.Shared.StatusText;
            AwakeManager.Shared.Stop();
            tray.Refresh();
            return status;
        });

        await Check("Anmeldeinformationen", () =>
        {
            var store = new CredentialStore();
            store.Write("selftest", "geheim-äöü");
            var read = store.Read("selftest");
            store.Write("selftest", "");
            if (read != "geheim-äöü" || store.Read("selftest") != "") throw new InvalidOperationException($"gelesen „{read}“");
            return "schreiben, lesen, löschen";
        });

        await Check("Autostart lesen", () => Autostart.IsEnabled ? "eingeschaltet" : "ausgeschaltet");
        // Fehlt auf frisch installierten PCs; dann melden die beiden Schritte darunter ebenfalls einen Hinweis.
        await Optional("Visual-C++-Laufzeit", () =>
        {
            if (!Shell.VcRuntimeInstalled) throw new InvalidOperationException("fehlt – Download: " + Shell.VcRuntimeUrl);
            return Task.FromResult<string?>("vorhanden");
        });

        await Optional("Mikrofon", () => CaptureAsync(AudioCapture.Microphone));
        await Optional("Systemton", () => CaptureAsync(AudioCapture.SystemAudio));

        await Optional("Spracherkennung", async () =>
        {
            var path = Environment.GetEnvironmentVariable("KLAR_SELFTEST_MODEL");
            if (string.IsNullOrEmpty(path)) path = SpeechService.Shared.Model.IsDownloaded ? SpeechService.Shared.Model.FilePath : null;
            if (path == null) return "übersprungen (kein Sprachmodell geladen)";
            using var whisper = new WhisperTranscriber(path);
            var wav = Environment.GetEnvironmentVariable("KLAR_SELFTEST_WAV");
            var watch = Stopwatch.StartNew();
            if (string.IsNullOrEmpty(wav))
            {
                await whisper.WarmUpAsync();
                return $"Modell geladen in {watch.Elapsed.TotalSeconds:0.0} s";
            }
            var (samples, rate, channels) = ReadWav(wav);
            var session = new TranscriptionSession(whisper, Environment.GetEnvironmentVariable("KLAR_SELFTEST_LANG") ?? "de");
            var parts = new List<string>();
            session.Committed += (t, _) => { lock (parts) parts.Add(t); };
            var resampler = new Resampler(rate, channels);
            var block = rate / 100 * channels;
            for (var o = 0; o < samples.Length; o += block)
                session.Append(resampler.Process(samples.AsSpan(o, Math.Min(block, samples.Length - o))));
            await session.StopAsync();
            var text = string.Join(" ", parts);
            if (text.Length == 0) throw new InvalidOperationException("kein Text erkannt");
            return $"„{text}“ in {watch.Elapsed.TotalSeconds:0.0} s";
        });

        await Optional("Bildschirmaufnahme", async () =>
        {
            var recorder = ScreenRecorder.Shared;
            recorder.RevealAfterStop = false;
            recorder.Start();
            for (var i = 0; i < 160 && !recorder.IsRecording && recorder.ErrorMessage == null; i++) await Task.Delay(100);
            if (!recorder.IsRecording) throw new InvalidOperationException(recorder.ErrorMessage ?? "startet nicht");
            await Task.Delay(2500);
            var file = recorder.LastFile!;
            recorder.Stop();
            for (var i = 0; i < 300 && (recorder.IsRecording || recorder.IsBusy); i++) await Task.Delay(100);
            var info = new FileInfo(file);
            if (!info.Exists || info.Length < 1000) throw new InvalidOperationException("Datei fehlt oder ist leer");
            return $"{Path.GetFileName(file)}, {Format.FileSize(info.Length)}";
        });

        window?.Hide();
        // Zwischenablage wieder so hinterlassen, wie sie war (Text) – sonst leeren.
        if (before != null) Paster.WriteText(before); else try { Clipboard.Clear(); } catch { }
        ClipboardMonitor.Shared.Stop();
        AwakeManager.Shared.ReleaseOnQuit();
        Debouncer.FlushAll();
        _report.AppendLine(_failures == 0 ? "ERGEBNIS: bestanden" : $"ERGEBNIS: {_failures} Fehler");
        File.WriteAllText(reportPath, _report.ToString(), new UTF8Encoding(false));
        try { Directory.Delete(dir, recursive: true); } catch { }
        return _failures;
    }

    private static Page? FindPage(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is Page page) return page;
            if (FindPage(child) is { } nested) return nested;
        }
        return null;
    }

    private static async Task<string?> CaptureAsync(Func<Action<float[]>, AudioCapture> open)
    {
        var samples = 0;
        float peak = 0;
        using var capture = open(data =>
        {
            Interlocked.Add(ref samples, data.Length);
            foreach (var v in data) peak = Math.Max(peak, Math.Abs(v));
        });
        capture.Start();
        await Task.Delay(700);
        capture.Stop();
        return $"{samples} Samples bei 16 kHz, Spitze {peak:0.000}";
    }

    private static (float[] Interleaved, int Rate, int Channels) ReadWav(string path)
    {
        var b = File.ReadAllBytes(path);
        int rate = 0, channels = 0, bits = 0, format = 1;
        var pos = 12;
        while (pos + 8 <= b.Length)
        {
            var id = Encoding.ASCII.GetString(b, pos, 4);
            var size = BitConverter.ToInt32(b, pos + 4);
            if (id == "fmt ")
            {
                format = BitConverter.ToInt16(b, pos + 8);
                channels = BitConverter.ToInt16(b, pos + 10);
                rate = BitConverter.ToInt32(b, pos + 12);
                bits = BitConverter.ToInt16(b, pos + 22);
            }
            else if (id == "data")
            {
                size = Math.Min(size, b.Length - pos - 8);
                return (PcmDecoder.ToFloat(b.AsSpan(pos + 8, size), bits, format == 3), rate, channels);
            }
            pos += 8 + size + (size & 1);
        }
        throw new InvalidDataException("WAV ohne Daten: " + path);
    }
}
