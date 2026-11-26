using System.Collections.Specialized;
using System.Diagnostics;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Klar.Core;

namespace Klar;

/// <summary>Beobachtet die System-Zwischenablage über WM_CLIPBOARDUPDATE.</summary>
internal sealed class ClipboardMonitor
{
    public static ClipboardMonitor Shared { get; } = new();

    /// <summary>Kopien aus Passwortmanagern landen nie im Verlauf.</summary>
    private static readonly string[] SensitiveSources =
    [
        "1password", "bitwarden", "keepass", "enpass", "dashlane", "lastpass", "nordpass", "protonpass",
        "proton pass", "keeper", "strongbox", "roboform", "passwordsafe", "credentialuibroker",
    ];

    private const int MaxTextLength = 500_000;

    private readonly DispatcherTimer _settle;
    private uint _ownSequence;
    private DateTime _ignoreUntil;
    private bool _started;

    private ClipboardMonitor()
    {
        // Viele Programme füllen die Zwischenablage in mehreren Schritten – kurz warten, dann einmal lesen.
        _settle = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
        _settle.Tick += (_, _) => { _settle.Stop(); Check(); };
    }

    public void Start()
    {
        if (_started) return;
        _started = true;
        _ownSequence = Native.GetClipboardSequenceNumber();
        MessageWindow.Source.AddHook(WndProc);
        if (!Native.AddClipboardFormatListener(MessageWindow.Handle))
            Log.Write("Zwischenablage kann nicht beobachtet werden.");
    }

    public void Stop()
    {
        if (!_started) return;
        _started = false;
        Native.RemoveClipboardFormatListener(MessageWindow.Handle);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WM_CLIPBOARDUPDATE)
        {
            _settle.Stop();
            _settle.Start();
        }
        return IntPtr.Zero;
    }

    /// <summary>Nach eigenem Schreiben aufrufen, damit der Inhalt nicht als neue Kopie zählt.</summary>
    public void NoteOwnChange()
    {
        _ownSequence = Native.GetClipboardSequenceNumber();
        _ignoreUntil = DateTime.UtcNow.AddMilliseconds(400);
    }

    private void Check()
    {
        var sequence = Native.GetClipboardSequenceNumber();
        if (sequence == _ownSequence || DateTime.UtcNow < _ignoreUntil)
        {
            _ownSequence = sequence;
            return;
        }
        try { Read(); }
        catch (Exception e) { Log.Write("Zwischenablage nicht lesbar: " + e.Message); }
        // Das Lesen verzögert bereitgestellter Formate zählt die Folgenummer hoch und meldet sich erneut –
        // diesen Stand als bekannt merken, sonst entstünde derselbe Eintrag doppelt.
        _ownSequence = Native.GetClipboardSequenceNumber();
    }

    private static void Read()
    {
        var data = Clipboard.GetDataObject();
        if (data == null) return;

        // Passwortmanager und transiente Inhalte respektieren (Windows-Konvention für Verlaufs-Programme).
        if (data.GetDataPresent("ExcludeClipboardContentFromMonitorProcessing")) return;
        if (ReadFlag(data, "CanIncludeInClipboardHistory") == 0) return;
        if (data.GetDataPresent("Clipboard Viewer Ignore")) return;

        var (source, process) = SourceApp();
        if (process != null && SensitiveSources.Any(s => process.Contains(s, StringComparison.OrdinalIgnoreCase))) return;
        if (source != null && SensitiveSources.Any(s => source.Contains(s, StringComparison.OrdinalIgnoreCase))) return;

        if (data.GetDataPresent(DataFormats.FileDrop) && data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files)
        {
            ClipboardStore.Shared.Add(new ClipItem { Kind = ClipKind.Files, Files = [.. files], SourceApp = source });
            return;
        }
        if (data.GetDataPresent(DataFormats.UnicodeText) && data.GetData(DataFormats.UnicodeText) is string text
            && !string.IsNullOrWhiteSpace(text))
        {
            if (text.Length > MaxTextLength) return;
            ClipboardStore.Shared.Add(new ClipItem { Kind = ClipKind.Text, Text = text, SourceApp = source });
            return;
        }
        if (SaveImage(data) is { } name)
        {
            // Dasselbe Bild noch einmal (z. B. über eine geteilte Zwischenablage) nicht doppelt ablegen.
            if (ClipboardStore.Shared.Items.FirstOrDefault() is { Kind: ClipKind.Image, ImageFile: { } previous } && SameImage(previous, name))
            {
                try { File.Delete(Path.Combine(Storage.Images, name)); } catch { }
                return;
            }
            ClipboardStore.Shared.Add(new ClipItem { Kind = ClipKind.Image, ImageFile = name, SourceApp = source });
        }
    }

    private static bool SameImage(string a, string b)
    {
        try
        {
            var first = new FileInfo(Path.Combine(Storage.Images, Path.GetFileName(a)));
            var second = new FileInfo(Path.Combine(Storage.Images, Path.GetFileName(b)));
            if (!first.Exists || !second.Exists || first.Length != second.Length) return false;
            return File.ReadAllBytes(first.FullName).AsSpan().SequenceEqual(File.ReadAllBytes(second.FullName));
        }
        catch { return false; }
    }

    private static int? ReadFlag(IDataObject data, string format)
    {
        try
        {
            if (!data.GetDataPresent(format)) return null;
            if (data.GetData(format) is Stream { Length: >= 4 } s)
            {
                var b = new byte[4];
                s.Position = 0;
                s.ReadExactly(b);
                return BitConverter.ToInt32(b, 0);
            }
        }
        catch { }
        return null;
    }

    private static string? SaveImage(IDataObject data)
    {
        var name = Guid.NewGuid().ToString("D").ToUpperInvariant() + ".png";
        var file = Path.Combine(Storage.Images, name);

        // Viele Programme legen zusätzlich ein PNG ab – das erhält Transparenz verlustfrei.
        if (data.GetDataPresent("PNG") && data.GetData("PNG") is Stream { Length: > 8 and < 80_000_000 } png)
        {
            png.Position = 0;
            using var output = File.Create(file);
            png.CopyTo(output);
            return name;
        }
        if (!data.GetDataPresent(DataFormats.Bitmap)) return null;
        var image = Clipboard.GetImage();
        if (image == null || image.PixelWidth * (long)image.PixelHeight > 60_000_000) return null;
        // Bitmaps aus der Zwischenablage tragen oft einen leeren Alphakanal und wären sonst unsichtbar.
        BitmapSource opaque = new FormatConvertedBitmap(image, PixelFormats.Bgr24, null, 0);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(opaque));
        using (var output = File.Create(file)) encoder.Save(output);
        return name;
    }

    /// <summary>Anzeigename und Prozessname des Programms, das zuletzt kopiert hat.</summary>
    private static (string? Display, string? Process) SourceApp()
    {
        try
        {
            var window = Native.GetClipboardOwner();
            if (window == IntPtr.Zero) window = Native.GetForegroundWindow();
            if (window == IntPtr.Zero) return (null, null);
            Native.GetWindowThreadProcessId(window, out var pid);
            if (pid == 0) return (null, null);
            using var p = Process.GetProcessById((int)pid);
            var name = p.ProcessName;
            string? description = null;
            try { description = p.MainModule?.FileVersionInfo.FileDescription; } catch { }
            return (string.IsNullOrWhiteSpace(description) ? name : description!.Trim(), name);
        }
        catch { return (null, null); }
    }
}

/// <summary>Schreibt Inhalte in die Zwischenablage und löst Strg+V in der aktiven App aus.</summary>
internal static class Paster
{
    /// <summary>Liefert false, wenn die Zwischenablage gesperrt war – dann darf nicht eingefügt werden,
    /// sonst landete der alte Inhalt im Zielfenster.</summary>
    private static bool Set(DataObject data)
    {
        var ok = true;
        try
        {
            Clipboard.SetDataObject(data, true);
        }
        catch (Exception e)
        {
            ok = false;
            Log.Write("Zwischenablage nicht beschreibbar: " + e.Message);
        }
        ClipboardMonitor.Shared.NoteOwnChange();
        return ok;
    }

    public static bool Write(ClipItem item)
    {
        var data = new DataObject();
        switch (item.Kind)
        {
            case ClipKind.Text:
                data.SetText(item.Text ?? "", TextDataFormat.UnicodeText);
                break;
            case ClipKind.Image:
                var path = Path.Combine(Storage.Images, Path.GetFileName(item.ImageFile ?? ""));
                if (!File.Exists(path)) return false;
                try
                {
                    var bytes = File.ReadAllBytes(path);
                    var bmp = new BitmapImage();
                    bmp.BeginInit();
                    bmp.CacheOption = BitmapCacheOption.OnLoad;
                    bmp.StreamSource = new MemoryStream(bytes);
                    bmp.EndInit();
                    bmp.Freeze();
                    data.SetImage(bmp);
                    data.SetData("PNG", new MemoryStream(bytes));
                }
                catch (Exception e)
                {
                    Log.Write("Bild nicht lesbar: " + e.Message);
                    return false;
                }
                break;
            case ClipKind.Files:
                var list = new StringCollection();
                list.AddRange([.. item.Files ?? []]);
                if (list.Count == 0) return false;
                data.SetFileDropList(list);
                break;
        }
        if (!Set(data)) return false;
        // Der Eintrag gilt wieder als zuletzt kopiert.
        ClipboardStore.Shared.Touch(item.Id);
        return true;
    }

    public static bool WriteText(string text)
    {
        var data = new DataObject();
        data.SetText(text, TextDataFormat.UnicodeText);
        return Set(data);
    }

    /// <summary>Legt ein GIF als Datei in die Zwischenablage und merkt es im Verlauf.</summary>
    public static bool WriteGif(string file)
    {
        var data = new DataObject();
        data.SetFileDropList(new StringCollection { file });
        if (!Set(data)) return false;
        ClipboardStore.Shared.Add(new ClipItem { Kind = ClipKind.Files, Files = [file], SourceApp = "Giphy" });
        return true;
    }

    private static bool ModifierDown()
        => Native.IsKeyDown(Native.VK_CONTROL) || Native.IsKeyDown(Native.VK_SHIFT) || Native.IsKeyDown(Native.VK_MENU)
           || Native.IsKeyDown(Native.VK_LWIN) || Native.IsKeyDown(Native.VK_RWIN);

    /// <summary>Sendet Strg+V an das Zielfenster (oder das aktive Fenster). In Fenster, die als
    /// Administrator laufen, lässt Windows das nicht zu – der Inhalt bleibt dann in der Zwischenablage.</summary>
    public static async Task<bool> SendPasteAsync(IntPtr target = default)
    {
        // Noch gehaltene Tasten des Kürzels würden aus Strg+V etwas anderes machen.
        for (var i = 0; i < 40 && ModifierDown(); i++) await Task.Delay(20);

        if (target != IntPtr.Zero && Native.IsWindow(target))
        {
            if (Native.GetForegroundWindow() != target)
            {
                Native.SetForegroundWindow(target);
                await Task.Delay(80);
            }
            // Ließ sich das Ziel nicht nach vorn holen, lieber nicht einfügen als ins falsche Fenster.
            if (Native.GetForegroundWindow() != target) return false;
        }
        else await Task.Delay(40);

        var foreground = Native.GetForegroundWindow();
        if (foreground == IntPtr.Zero) return false;
        Native.GetWindowThreadProcessId(foreground, out var pid);
        if (pid == (uint)Environment.ProcessId) return false; // nicht in Klar selbst einfügen

        Native.INPUT[] inputs =
        [
            Native.Key(Native.VK_CONTROL, false), Native.Key(Native.VK_V, false),
            Native.Key(Native.VK_V, true), Native.Key(Native.VK_CONTROL, true),
        ];
        var sent = Native.SendInput((uint)inputs.Length, inputs, System.Runtime.InteropServices.Marshal.SizeOf<Native.INPUT>());
        return sent == inputs.Length;
    }

    public static void Paste(ClipItem item, IntPtr target = default)
    {
        if (Write(item)) _ = SendPasteAsync(target);
    }
}
