using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Klar.Core;

namespace Klar;

internal sealed class SettingsPage : Page
{
    private static readonly (string Id, string Name)[] Locales =
    [
        ("de-DE", "Deutsch"), ("en-US", "English (US)"), ("en-GB", "English (UK)"),
        ("fr-FR", "Français"), ("es-ES", "Español"), ("it-IT", "Italiano"),
    ];

    private readonly ScrollViewer _scroll;
    private readonly StackPanel _content = new();
    private TextBlock? _modelStatus;
    private string? _loginError;

    public SettingsPage()
    {
        _scroll = Ui.Scroll(_content);
        Children.Add(_scroll);
    }

    protected override void Attach()
    {
        ModelDownloader.Shared.Changed += OnDownload;
        HotkeyManager.Shared.Changed += Refresh;
    }

    protected override void Detach()
    {
        ModelDownloader.Shared.Changed -= OnDownload;
        HotkeyManager.Shared.Changed -= Refresh;
    }

    private void OnDownload()
    {
        // Während des Ladens nur den Statustext erneuern; am Ende die Seite neu aufbauen.
        if (ModelDownloader.Shared.IsBusy && _modelStatus != null) _modelStatus.Text = SpeechService.Shared.StatusText;
        else Refresh();
    }

    private void Add(FrameworkElement element, double bottom = 0)
    {
        if (bottom > 0) element.Bottom(bottom);
        _content.Children.Add(element);
    }

    private static StackPanel Choice<T>(IEnumerable<(T Value, string Label)> options, T current, Action<T> pick, double spacing = 28)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (value, label) in options)
        {
            var v = value;
            Ui.Add(row, Ui.TextButton(label, () => pick(v), prominent: EqualityComparer<T>.Default.Equals(value, current)), spacing);
        }
        return row;
    }

    public override void Refresh()
    {
        var offset = _scroll.VerticalOffset;
        var settings = AppSettings.Shared;
        var summarizer = Summarizer.Shared;
        _content.Children.Clear();

        Add(Ui.PageTitle("Einstellungen"));

        // Tastenkürzel
        Add(Ui.SectionLabel("Tastenkürzel"));
        HotkeyRow("Zwischenablage öffnen", HotkeyId.Clipboard, () => settings.ClipboardHotkey, h => settings.ClipboardHotkey = h);
        HotkeyRow("Diktat (tippen oder halten)", HotkeyId.Dictation, () => settings.DictationHotkey, h => settings.DictationHotkey = h);
        HotkeyRow("Meeting transkribieren", HotkeyId.Meeting, () => settings.MeetingHotkey, h => settings.MeetingHotkey = h);
        HotkeyRow("Bildschirmaufnahme", HotkeyId.Recording, () => settings.RecordingHotkey, h => settings.RecordingHotkey = h);
        HotkeyRow("Cocaine – wach halten (an/aus)", HotkeyId.Awake, () => settings.AwakeHotkey, h => settings.AwakeHotkey = h);
        Add(Ui.Note("Klicken, dann Kombination drücken. Auch eine einzelne Taste wie die rechte Strg-Taste ist möglich. Strg+Alt entspricht AltGr – Buchstaben mit AltGr-Zeichen (Q, E, M) besser meiden.")
            .With(new Thickness(0, 12, 0, 0)), 48);

        // Sprache
        Add(Ui.SectionLabel("Sprache"));
        Add(Choice(Locales.Select(l => (l.Id, l.Name)), settings.LocaleIdentifier, id => { settings.LocaleIdentifier = id; Refresh(); }), 14);
        Add(Ui.DotToggle("Diktat direkt in die aktive App einfügen", settings.PasteAfterDictation, v => settings.PasteAfterDictation = v), 14);
        Add(Ui.DotToggle("Bei Bildschirmaufnahmen auch das Mikrofon aufnehmen", settings.RecordMicInScreenRecording, v => settings.RecordMicInScreenRecording = v), 48);

        // Spracherkennung
        Add(Ui.SectionLabel("Spracherkennung"));
        Add(Ui.Note("Diktat und Meetings werden lokal auf dem Gerät erkannt (Whisper). Das Sprachmodell wird einmalig von Hugging Face geladen; danach verlässt kein Ton den PC. Größere Modelle erkennen genauer, brauchen aber länger."), 16);
        Add(Choice(SpeechModels.All.Select(m => (m.Id, $"{m.Label} ({m.Detail})")), SpeechService.Shared.Model.Id,
            id => { settings.WhisperModel = id; Refresh(); }), 10);
        _modelStatus = Ui.Note(SpeechService.Shared.StatusText);
        var modelRow = Ui.HStack(18, _modelStatus,
            !SpeechService.Shared.IsReady && !ModelDownloader.Shared.IsBusy
                ? Ui.TextButton("Jetzt laden", () => { _ = ModelDownloader.Shared.EnsureAsync(SpeechService.Shared.Model); }, prominent: true)
                : null);
        Add(modelRow, Shell.VcRuntimeInstalled ? 48 : 12);
        if (!Shell.VcRuntimeInstalled)
        {
            Add(Ui.Note("Die Microsoft-Visual-C++-Laufzeit fehlt auf diesem PC. Spracherkennung und Bildschirmaufnahme brauchen sie.", "Ink"), 6);
            Add(Ui.TextButton("Laufzeit bei Microsoft herunterladen", () => Shell.Open(Shell.VcRuntimeUrl), prominent: true), 48);
        }

        // Sprachbefehle
        Add(Ui.SectionLabel("Sprachbefehle"));
        Add(Ui.Note($"Sag nur den Namen („Signatur“) oder mitten im Satz „{settings.CommandPrefix} Signatur“, und der Baustein wird eingefügt. „Neue Zeile“ und „neuer Absatz“ funktionieren immer."), 20);
        var prefix = Ui.Field("einfügen", settings.CommandPrefix, v => settings.CommandPrefix = v, out _);
        prefix.Width = 160;
        Add(Ui.HStack(12, Ui.Small("Befehlswort"), prefix), 20);
        foreach (var snippet in settings.Snippets.ToList()) Add(SnippetEditor(snippet));
        Add(Ui.TextButton("+ Neuer Befehl", () =>
        {
            settings.Snippets.Add(new Snippet());
            settings.SnippetsEdited();
            Refresh();
        }, prominent: true).With(new Thickness(0, 8, 0, 0)), 48);

        // Zusammenfassung
        Add(Ui.SectionLabel("Zusammenfassung"));
        Add(Ui.Note("Nach jeder Meeting-Transkription entsteht automatisch eine Zusammenfassung. „Automatisch“ nimmt Claude Code über dein Abo, sonst die Claude-API mit Schlüssel."), 16);
        Add(Ui.DotToggle("Automatisch zusammenfassen", settings.AutoSummarize, v => settings.AutoSummarize = v), 16);
        var providers = Choice(SummaryProviders.All.Select(p => (p.Key(), p.Label())), SummaryProviders.Parse(settings.SummaryProvider).Key(),
            key => { settings.SummaryProvider = key; Refresh(); }, 12);
        Add(Ui.HStack(12, Ui.Body("Zusammenfassen über"), providers), 10);
        Add(Ui.Note($"Claude Code: {summarizer.ClaudeCodeStatus} · Claude-API: {summarizer.ClaudeApiStatus}"), 16);
        Add(Ui.HStack(12, Ui.Small("Claude-API-Schlüssel"), Ui.SecretField("optional", settings.ClaudeApiKey, v => settings.ClaudeApiKey = v, 320)), 48);

        // GIFs
        Add(Ui.SectionLabel("GIFs"));
        Add(Ui.Note("Der Reiter „GIFs“ im Zwischenablage-Panel durchsucht Giphy. Ein kostenloser Schlüssel lässt sich unter developers.giphy.com anlegen (App erstellen → API Key)."), 16);
        Add(Ui.HStack(12, Ui.Small("Giphy-API-Schlüssel"), Ui.SecretField("optional", settings.GiphyApiKey, v => settings.GiphyApiKey = v, 320)), 48);

        // Berechtigungen
        Add(Ui.SectionLabel("Berechtigungen"));
        Add(Ui.Note("Windows fragt Desktop-Apps nicht einzeln nach Freigaben. Nur das Mikrofon lässt sich systemweit sperren – ist es gesperrt, meldet Klar das beim Diktat. Einfügen per Strg+V funktioniert in allen Fenstern außer solchen, die als Administrator laufen."), 10);
        Add(Ui.TextButton("Mikrofon-Einstellungen von Windows öffnen", () => Shell.Open("ms-settings:privacy-microphone"), prominent: true), 48);

        // Allgemein
        Add(Ui.SectionLabel("Allgemein"));
        Add(Ui.DotToggle("Beim Anmelden starten", Autostart.IsEnabled, v =>
        {
            _loginError = Autostart.Set(v);
            Refresh();
        }), _loginError == null ? 14 : 6);
        if (_loginError != null) Add(Ui.Note($"Autostart fehlgeschlagen: {_loginError}"), 14);
        Add(Ui.DotToggle("Fenster in der Taskleiste anzeigen", settings.ShowInTaskbar, v => settings.ShowInTaskbar = v), 14);
        Add(Ui.HStack(12, Ui.Body("Verlauf behalten"),
            Choice(new[] { 100, 500, 2000 }.Select(n => (n, n.ToString())), settings.HistoryLimit, n => { settings.HistoryLimit = n; Refresh(); }, 12)), 40);

        _scroll.ScrollToVerticalOffset(offset);
    }

    private void HotkeyRow(string label, int id, Func<Hotkey> get, Action<Hotkey> set)
    {
        var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(Ui.Body(label));
        if (HotkeyManager.Shared.Error(id) is { } error)
            left.Children.Add(Ui.Text("Kürzel ist " + error + ".", 12, "Muted").With(new Thickness(0, 3, 0, 0)));
        var row = Ui.HeaderRow(left, new HotkeyRecorder(get, set), alignRightTop: false);
        row.Margin = new Thickness(0, 10, 0, 10);
        _content.Children.Add(row);
        _content.Children.Add(Ui.Hairline());
    }

    private FrameworkElement SnippetEditor(Snippet snippet)
    {
        var settings = AppSettings.Shared;
        var trigger = Ui.Field("Befehl, z. B. Signatur", snippet.Trigger, v =>
        {
            snippet.Trigger = v;
            settings.SnippetsEdited();
        }, out _, 14, FontWeights.Medium);
        var remove = Ui.TextButton("Entfernen", () =>
        {
            settings.Snippets.Remove(snippet);
            settings.SnippetsEdited();
            Refresh();
        });
        remove.Opacity = 0;
        var text = Ui.Field("Text, der eingefügt wird", snippet.Text, v =>
        {
            snippet.Text = v;
            settings.SnippetsEdited();
        }, out var box, multiline: true);
        box.MinHeight = 44;
        box.MaxHeight = 140;
        box.VerticalContentAlignment = VerticalAlignment.Top;
        box.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        var panel = new StackPanel { Margin = new Thickness(0, 10, 0, 10), Background = Brushes.Transparent };
        panel.Children.Add(Ui.HeaderRow(trigger, remove));
        panel.Children.Add(text.With(new Thickness(0, 10, 0, 10)));
        panel.Children.Add(Ui.Hairline());
        panel.MouseEnter += (_, _) => remove.Opacity = 1;
        panel.MouseLeave += (_, _) => remove.Opacity = 0;
        return panel;
    }
}

/// <summary>Klick, dann Tastenkombination drücken.</summary>
internal sealed class HotkeyRecorder : Border
{
    private readonly Func<Hotkey> _get;
    private readonly Action<Hotkey> _set;
    private readonly TextBlock _label;
    private readonly Border _line;
    private readonly HashSet<uint> _modifiersDown = [];
    private uint? _pendingModifier;
    private bool _recording;

    public HotkeyRecorder(Func<Hotkey> get, Action<Hotkey> set)
    {
        _get = get;
        _set = set;
        Focusable = true;
        FocusVisualStyle = null;
        Background = Brushes.Transparent;
        Cursor = Cursors.Hand;
        MinWidth = 150;
        VerticalAlignment = VerticalAlignment.Center;
        _label = Ui.Text("", 13);
        _label.HorizontalAlignment = HorizontalAlignment.Right;
        _line = new Border { Height = 1, Margin = new Thickness(0, 4, 0, 0) };
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right };
        stack.Children.Add(_label);
        stack.Children.Add(_line);
        Child = stack;
        Update();

        MouseLeftButtonDown += (_, e) =>
        {
            e.Handled = true;
            Focus();
            Keyboard.Focus(this);
            Begin();
        };
        LostKeyboardFocus += (_, _) => End();
        Unloaded += (_, _) => End();
        PreviewKeyDown += OnKeyDown;
        PreviewKeyUp += OnKeyUp;
    }

    private void Begin()
    {
        if (_recording) return;
        _recording = true;
        _pendingModifier = null;
        _modifiersDown.Clear();
        HotkeyManager.Shared.Pause();
        Update();
    }

    private void End()
    {
        if (!_recording) return;
        _recording = false;
        HotkeyManager.Shared.Resume();
        Update();
    }

    private void Accept(Hotkey hotkey)
    {
        End();
        _set(hotkey);
        Update();
        Keyboard.ClearFocus();
    }

    private static Key RealKey(KeyEventArgs e) => e.Key switch
    {
        Key.System => e.SystemKey,
        Key.ImeProcessed => e.ImeProcessedKey,
        Key.DeadCharProcessed => e.DeadCharProcessedKey,
        _ => e.Key,
    };

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (!_recording) return;
        e.Handled = true;
        var key = RealKey(e);
        var vk = (uint)KeyInterop.VirtualKeyFromKey(key);
        if (Hotkey.ModifierKeyNames.ContainsKey(vk))
        {
            if (e.IsRepeat) return;
            _modifiersDown.Add(vk);
            // Nur eine allein gedrückte Modifier-Taste kann ein Einzeltasten-Kürzel werden.
            _pendingModifier = _modifiersDown.Count == 1 ? vk : null;
            return;
        }
        _pendingModifier = null;
        if (key == Key.Escape) { End(); Keyboard.ClearFocus(); return; }
        if (vk == 0) return;
        var mods = HotkeyModifiers.None;
        var m = Keyboard.Modifiers;
        if (m.HasFlag(ModifierKeys.Control)) mods |= HotkeyModifiers.Control;
        if (m.HasFlag(ModifierKeys.Alt)) mods |= HotkeyModifiers.Alt;
        if (m.HasFlag(ModifierKeys.Shift)) mods |= HotkeyModifiers.Shift;
        if (m.HasFlag(ModifierKeys.Windows)) mods |= HotkeyModifiers.Win;
        if (Hotkey.IsAcceptable(vk, mods)) Accept(new Hotkey(vk, mods));
    }

    private void OnKeyUp(object sender, KeyEventArgs e)
    {
        if (!_recording) return;
        e.Handled = true;
        var vk = (uint)KeyInterop.VirtualKeyFromKey(RealKey(e));
        if (!_modifiersDown.Remove(vk)) return;
        if (_pendingModifier == vk && _modifiersDown.Count == 0) Accept(new Hotkey(vk, HotkeyModifiers.None));
        else if (_modifiersDown.Count == 0) _pendingModifier = null;
    }

    private void Update()
    {
        _label.Text = _recording ? "Taste drücken …" : _get().Display;
        _label.Opacity = _recording ? 0.4 : 1;
        _line.SetResourceReference(BackgroundProperty, _recording ? "Ink" : "Faint");
    }
}
