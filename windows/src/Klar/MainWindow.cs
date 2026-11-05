using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Klar.Core;

namespace Klar;

internal enum Section { Clipboard, Dictations, Meetings, Recordings, Awake, Settings }

internal static class Sections
{
    public static readonly Section[] All = [Section.Clipboard, Section.Dictations, Section.Meetings, Section.Recordings, Section.Awake, Section.Settings];

    public static string Title(this Section s) => s switch
    {
        Section.Clipboard => "Zwischenablage",
        Section.Dictations => "Diktate",
        Section.Meetings => "Meetings",
        Section.Recordings => "Aufnahmen",
        Section.Awake => "Cocaine",
        _ => "Einstellungen",
    };
}

/// <summary>Seite im Hauptfenster. Hört nur auf Änderungen, solange sie angezeigt wird.</summary>
internal abstract class Page : DockPanel
{
    private bool _attached;

    protected Page()
    {
        Loaded += (_, _) =>
        {
            if (!_attached) { _attached = true; Attach(); }
            Refresh();
        };
        Unloaded += (_, _) =>
        {
            if (_attached) { _attached = false; Detach(); }
        };
    }

    protected virtual void Attach() { }
    protected virtual void Detach() { }
    public abstract void Refresh();

    protected void Top(FrameworkElement element)
    {
        SetDock(element, Dock.Top);
        Children.Add(element);
    }
}

internal sealed class MainWindow : Window
{
    private readonly Dictionary<Section, TextBlock> _nav = [];
    private readonly Border _host = new() { Padding = new Thickness(24, 40, 56, 40) };
    private Section _section = Section.Clipboard;

    public static string VersionText
    {
        get
        {
            var v = Assembly.GetExecutingAssembly().GetName().Version;
            return v == null ? "0" : $"{v.Major}.{v.Minor}.{v.Build}";
        }
    }

    public MainWindow()
    {
        Title = "Klar";
        Width = 960;
        Height = 640;
        MinWidth = 820;
        MinHeight = 540;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Theme.Font;
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        ShowInTaskbar = AppSettings.Shared.ShowInTaskbar;
        SetResourceReference(BackgroundProperty, "Paper");
        try { Icon = BitmapFrame.Create(new Uri("pack://application:,,,/Resources/Klar.ico")); } catch { }

        var sidebar = new DockPanel { Width = 220, LastChildFill = false };
        var brand = Ui.Text(Ui.Tracked("Klar"), 15, "Ink", FontWeights.Medium);
        brand.Margin = new Thickness(48, 44, 0, 52);
        DockPanel.SetDock(brand, Dock.Top);
        sidebar.Children.Add(brand);
        foreach (var s in Sections.All)
        {
            var section = s;
            var label = Ui.Text(s.Title(), 14, "Muted");
            _nav[s] = label;
            var button = Ui.Plain(label, () => Navigate(section));
            button.Padding = new Thickness(48, 9, 0, 9);
            button.HorizontalContentAlignment = HorizontalAlignment.Left;
            button.MouseEnter += (_, _) => { if (_section != section) label.Foreground = Theme.InkBrush(0.7); };
            button.MouseLeave += (_, _) => label.SetResourceReference(TextBlock.ForegroundProperty, _section == section ? "Ink" : "Muted");
            DockPanel.SetDock(button, Dock.Top);
            sidebar.Children.Add(button);
        }
        var footer = Ui.VStack(6, Ui.Text("Jasper Felix Siebrasse", 12, "Faint"), Ui.Text("v" + VersionText, 12, "Faint"));
        footer.Margin = new Thickness(48, 0, 0, 32);
        DockPanel.SetDock(footer, Dock.Bottom);
        sidebar.Children.Add(footer);

        var layout = new DockPanel();
        DockPanel.SetDock(sidebar, Dock.Left);
        layout.Children.Add(sidebar);
        layout.Children.Add(_host);
        Content = layout;

        SourceInitialized += (_, _) => Theme.StyleTitleBar(this);
        Theme.Changed += OnThemeChanged;
        // Schließen blendet nur aus – Klar läuft im Infobereich weiter.
        Closing += (_, e) => { e.Cancel = true; Hide(); };
        Navigate(_section);
    }

    private void OnThemeChanged()
    {
        Theme.StyleTitleBar(this);
        Navigate(_section);
    }

    public void Navigate(Section section)
    {
        _section = section;
        foreach (var (s, label) in _nav)
        {
            label.FontWeight = s == section ? FontWeights.Medium : FontWeights.Normal;
            label.SetResourceReference(TextBlock.ForegroundProperty, s == section ? "Ink" : "Muted");
        }
        _host.Child = section switch
        {
            Section.Clipboard => new ClipboardPage(),
            Section.Dictations => new DictationsPage(),
            Section.Meetings => new MeetingsPage(),
            Section.Recordings => new RecordingsPage(),
            Section.Awake => new AwakePage(),
            _ => new SettingsPage(),
        };
    }

    public void Present(Section? section = null)
    {
        if (section is { } s) Navigate(s);
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        Native.ForceForeground(new System.Windows.Interop.WindowInteropHelper(this).Handle);
        Focus();
    }
}

// MARK: - Zwischenablage

internal sealed class ClipboardPage : Page
{
    private const int MaxRows = 300;
    private readonly StackPanel _list = new();
    private string _query = "";
    private Guid? _copied;

    public ClipboardPage()
    {
        Top(Ui.HeaderRow(
            Ui.PageTitle("Zwischenablage", $"{AppSettings.Shared.ClipboardHotkey.Display} öffnet das Panel in jeder App."),
            Ui.TextButton("Verlauf leeren", () => ClipboardStore.Shared.ClearUnpinned())));
        Top(Ui.UnderlinedField("Suchen", "", q => { _query = q; Refresh(); }, out _).Bottom(8));
        Children.Add(Ui.Scroll(_list));
    }

    protected override void Attach() => ClipboardStore.Shared.Changed += Refresh;
    protected override void Detach() => ClipboardStore.Shared.Changed -= Refresh;

    public override void Refresh()
    {
        _list.Children.Clear();
        var items = ClipboardStore.Shared.Ordered.Where(i => i.Matches(_query)).ToList();
        if (items.Count == 0)
        {
            _list.Children.Add(Ui.EmptyNote(_query.Length == 0 ? "Kopiere etwas mit Strg+C – es erscheint hier." : "Keine Treffer."));
            return;
        }
        foreach (var item in items.Take(MaxRows)) _list.Children.Add(Row(item));
        if (items.Count > MaxRows)
            _list.Children.Add(Ui.Small($"… {items.Count - MaxRows} weitere. Über die Suche erreichbar.", "Faint").With(new Thickness(22, 16, 0, 16)));
    }

    private async void Copy(ClipItem item)
    {
        _copied = item.Id;
        Paster.Write(item); // rückt den Eintrag nach oben und löst damit ein Neuzeichnen aus
        Refresh();
        await Task.Delay(1200);
        if (_copied != item.Id) return;
        _copied = null;
        Refresh();
    }

    private FrameworkElement Row(ClipItem item)
    {
        var dot = Ui.Dot(6, true);
        dot.StrokeThickness = 0;
        dot.VerticalAlignment = VerticalAlignment.Top;
        dot.Margin = new Thickness(0, 7, 16, 0);
        dot.Opacity = item.Pinned ? 1 : 0;

        FrameworkElement body = item.Kind == ClipKind.Image && Ui.Thumbnail(item.ImageFile) is { } thumb
            ? Ui.Picture(thumb, 120)
            : Ui.Text(item.Preview.Length > 600 ? item.Preview[..600] : item.Preview, 14, maxLines: 3);
        var meta = Ui.HStack(10, Ui.Text(Format.Relative(item.CreatedAt), 12, "Faint"),
            item.SourceApp is { Length: > 0 } app ? Ui.Text(app, 12, "Faint") : null);
        var text = Ui.VStack(6, body, meta);
        var content = new DockPanel();
        DockPanel.SetDock(dot, Dock.Left);
        content.Children.Add(dot);
        content.Children.Add(text);

        var copied = _copied == item.Id;
        var actions = Ui.HStack(18,
            copied ? Ui.Text("Kopiert", 12) : Ui.TextButton("Kopieren", () => Copy(item)),
            Ui.TextButton(item.Pinned ? "Lösen" : "Anpinnen", () => ClipboardStore.Shared.TogglePin(item.Id)),
            Ui.TextButton("Löschen", () => ClipboardStore.Shared.Remove(item.Id)));
        // Ein Klick auf die Zeile kopiert sofort; die Buttons rechts bleiben für Anpinnen und Löschen.
        return Ui.ListRow(content, actions, () => Copy(item), () => _copied == item.Id);
    }
}

// MARK: - Diktate

internal sealed class DictationsPage : Page
{
    private readonly StackPanel _list = new();
    private readonly Border _action = new();

    public DictationsPage()
    {
        Top(Ui.HeaderRow(
            Ui.PageTitle("Diktate", $"{AppSettings.Shared.DictationHotkey.Display} tippen: Start/Stopp. Halten: sprechen, loslassen, fertig."),
            _action));
        Children.Add(Ui.Scroll(_list));
    }

    protected override void Attach()
    {
        DictationStore.Shared.Changed += Refresh;
        DictationEngine.Shared.Changed += RefreshAction;
    }

    protected override void Detach()
    {
        DictationStore.Shared.Changed -= Refresh;
        DictationEngine.Shared.Changed -= RefreshAction;
    }

    private void RefreshAction()
        => _action.Child = Ui.TextButton(DictationEngine.Shared.IsListening ? "Stopp" : "Diktat starten", DictationEngine.Shared.Toggle, prominent: true);

    public override void Refresh()
    {
        RefreshAction();
        _list.Children.Clear();
        var items = DictationStore.Shared.Items;
        if (items.Count == 0)
        {
            _list.Children.Add(Ui.EmptyNote("Noch keine Diktate."));
            return;
        }
        foreach (var d in items.Take(300))
        {
            var item = d;
            var text = Ui.Text(d.Text, 14, maxLines: 3);
            var meta = Ui.HStack(10,
                Ui.Text(Format.Relative(d.CreatedAt), 12, "Faint"),
                Ui.Text($"{d.Duration:0} s", 12, "Faint"),
                d.UsedSnippet is { } s ? Ui.Text($"Befehl „{s}“", 12, "Faint") : null);
            var actions = Ui.HStack(18,
                Ui.TextButton("Kopieren", () => Paster.WriteText(item.Text)),
                Ui.TextButton("Löschen", () => DictationStore.Shared.Remove(item.Id)));
            var row = Ui.ListRow(Ui.VStack(6, text, meta), actions);
            // Beim Überfahren den ganzen Text zeigen.
            row.MouseEnter += (_, _) => text.MaxHeight = double.PositiveInfinity;
            row.MouseLeave += (_, _) => text.MaxHeight = text.LineHeight * 3;
            _list.Children.Add(row);
        }
    }
}

// MARK: - Meetings

internal sealed class MeetingsPage : Page
{
    private readonly Border _action = new();
    private readonly Border _body = new();
    private Guid? _selected;
    private TextBox? _titleBox;
    private Guid? _titleFor;

    public MeetingsPage()
    {
        Top(Ui.HeaderRow(
            Ui.PageTitle("Meetings", $"Systemton und Mikrofon werden getrennt transkribiert – {AppSettings.Shared.MeetingHotkey.Display}"),
            _action));
        Children.Add(_body);
    }

    protected override void Attach()
    {
        MeetingStore.Shared.Changed += Refresh;
        MeetingRecorder.Shared.Changed += Refresh;
        Summarizer.Shared.Changed += Refresh;
    }

    protected override void Detach()
    {
        MeetingStore.Shared.Changed -= Refresh;
        MeetingRecorder.Shared.Changed -= Refresh;
        Summarizer.Shared.Changed -= Refresh;
    }

    public override void Refresh()
    {
        var recorder = MeetingRecorder.Shared;
        _action.Child = recorder.IsFinishing
            ? Ui.Text("Wird abgeschlossen …", 12, "Muted")
            : Ui.TextButton(recorder.IsRunning ? "Transkription beenden" : "Transkription starten", recorder.Toggle, prominent: true);

        // Tippt jemand gerade im Titel, bleibt die Eingabe über das Neuzeichnen hinweg erhalten.
        var editing = _titleBox is { IsKeyboardFocused: true } ? (_titleBox.Text, _titleBox.CaretIndex, _titleFor) : ((string, int, Guid?)?)null;

        var panel = new DockPanel();
        if (recorder.ErrorMessage is { } error)
        {
            var e = Ui.Note(error, "Ink").Bottom(16);
            DockPanel.SetDock(e, Dock.Top);
            panel.Children.Add(e);
        }

        var store = MeetingStore.Shared;
        if ((recorder.IsRunning || recorder.IsFinishing) && recorder.Current is { } current)
            panel.Children.Add(Live(current, recorder.LiveMe, recorder.LiveOthers));
        else if ((_selected ?? recorder.LastFinishedId) is { } id && store.Find(id) is { } meeting)
            Detail(panel, meeting, editing);
        else if (store.Items.Count == 0)
            panel.Children.Add(Ui.EmptyNote("Noch keine Meetings transkribiert."));
        else
        {
            var list = new StackPanel();
            foreach (var m in store.Items) list.Children.Add(Row(m));
            panel.Children.Add(Ui.Scroll(list));
        }
        _body.Child = panel;
    }

    private FrameworkElement Row(MeetingTranscript m)
    {
        var meta = Ui.HStack(10,
            Ui.Text(Format.DateTimeText(m.StartedAt), 12, "Faint"),
            m.EndedAt is { } end ? Ui.Text(Format.Clock((end - m.StartedAt).TotalSeconds), 12, "Faint") : null,
            Ui.Text($"{m.Lines.Count} Abschnitte", 12, "Faint"));
        var actions = Ui.HStack(18,
            Ui.TextButton("Kopieren", () => Paster.WriteText(m.PlainText)),
            Ui.TextButton("Löschen", () => MeetingStore.Shared.Remove(m.Id)));
        return Ui.ListRow(Ui.VStack(6, Ui.Body(m.Title), meta), actions, () => { _selected = m.Id; Refresh(); });
    }

    private static FrameworkElement Line(TranscriptLine line, bool live = false)
    {
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 14) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(70) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var who = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right };
        var speaker = Ui.Text(line.Speaker, 11, live ? "Faint" : "Ink", FontWeights.Medium);
        speaker.HorizontalAlignment = HorizontalAlignment.Right;
        who.Children.Add(speaker);
        if (!live)
        {
            var clock = Ui.Text(Format.Clock(line.Time), 12, "Faint");
            clock.HorizontalAlignment = HorizontalAlignment.Right;
            clock.Margin = new Thickness(0, 2, 0, 0);
            who.Children.Add(clock);
        }
        grid.Children.Add(who);
        var text = Ui.Text(line.Text, 14, live ? "Muted" : "Ink", wrap: TextWrapping.Wrap);
        text.TextTrimming = TextTrimming.None;
        text.LineHeight = 20;
        text.Margin = new Thickness(16, 0, 0, 0);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        return grid;
    }

    private static FrameworkElement Live(MeetingTranscript t, string liveMe, string liveOthers)
    {
        var list = new StackPanel();
        foreach (var line in t.Lines) list.Children.Add(Line(line));
        if (liveOthers.Length > 0) list.Children.Add(Line(new TranscriptLine { Speaker = "Andere", Text = liveOthers }, live: true));
        if (liveMe.Length > 0) list.Children.Add(Line(new TranscriptLine { Speaker = "Ich", Text = liveMe }, live: true));
        if (list.Children.Count == 0) list.Children.Add(Ui.Body("Transkription läuft. Erkannte Abschnitte erscheinen nach jeder Sprechpause.", "Muted"));
        var scroll = Ui.Scroll(list);
        scroll.Loaded += (_, _) => scroll.ScrollToEnd();
        return scroll;
    }

    private void Detail(DockPanel panel, MeetingTranscript t, (string Text, int Caret, Guid? For)? editing)
    {
        var summarizer = Summarizer.Shared;
        var right = Ui.HStack(18,
            summarizer.IsBusy(t.Id)
                ? Ui.Text("Zusammenfassung wird erstellt …", 12, "Muted")
                : Ui.TextButton(t.Summary == null ? "Zusammenfassen" : "Neu zusammenfassen", () => _ = summarizer.SummarizeAsync(t.Id)),
            t.Summary is { } summary ? Ui.TextButton("Zusammenfassung kopieren", () => Paster.WriteText(summary)) : null,
            Ui.TextButton("Transkript kopieren", () => Paster.WriteText(t.PlainText)));
        var bar = Ui.HeaderRow(Ui.TextButton("← Zurück", () =>
        {
            _selected = null;
            MeetingRecorder.Shared.LastFinishedId = null;
            Refresh();
        }), right);
        bar.Margin = new Thickness(0, 0, 0, 24);
        DockPanel.SetDock(bar, Dock.Top);
        panel.Children.Add(bar);

        if (summarizer.LastError is { } error)
        {
            var e = Ui.Note(error, "Ink").Bottom(16);
            DockPanel.SetDock(e, Dock.Top);
            panel.Children.Add(e);
        }

        var title = Ui.Field("Titel", editing is { } ed && ed.For == t.Id ? ed.Text : t.Title, _ => { }, out var box, 18, FontWeights.Light);
        title.Margin = new Thickness(0, 0, 0, 20);
        void Commit()
        {
            var value = box.Text.Trim();
            if (value.Length > 0 && value != t.Title) MeetingStore.Shared.Rename(t.Id, value);
        }
        box.LostKeyboardFocus += (_, _) => Commit();
        box.KeyDown += (_, e) =>
        {
            if (e.Key != System.Windows.Input.Key.Enter) return;
            e.Handled = true;
            Commit();
        };
        _titleBox = box;
        _titleFor = t.Id;
        DockPanel.SetDock(title, Dock.Top);
        panel.Children.Add(title);

        var content = new StackPanel();
        if (t.Summary is { } s)
        {
            content.Children.Add(Ui.SectionLabel("Zusammenfassung"));
            content.Children.Add(SummaryView(s).Bottom(36));
            content.Children.Add(Ui.SectionLabel("Transkript"));
        }
        foreach (var line in t.Lines) content.Children.Add(Line(line));
        panel.Children.Add(Ui.Scroll(content));

        if (editing is { } restore && restore.For == t.Id)
        {
            box.Loaded += (_, _) =>
            {
                box.Focus();
                box.CaretIndex = Math.Min(restore.Caret, box.Text.Length);
            };
        }
    }

    /// <summary>Zeigt die Markdown-Zusammenfassung reduziert: Überschriften als Versalien, Punkte als Zeilen.</summary>
    private static StackPanel SummaryView(string markdown)
    {
        static string Clean(string s) => s.Replace("**", "");
        var panel = new StackPanel();
        foreach (var raw in markdown.Replace("\r\n", "\n").Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            if (line.StartsWith('#'))
            {
                var heading = Ui.Text(Ui.Tracked(line.TrimStart('#').Trim().ToUpper()), 11, "Muted", FontWeights.Medium);
                heading.Margin = new Thickness(0, panel.Children.Count == 0 ? 0 : 22, 0, 8);
                panel.Children.Add(heading);
            }
            else if (line.StartsWith("- ") || line.StartsWith("* ") || line.StartsWith("• "))
            {
                var row = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
                var dash = Ui.Body("–", "Muted");
                dash.Margin = new Thickness(0, 0, 10, 0);
                DockPanel.SetDock(dash, Dock.Left);
                row.Children.Add(dash);
                var text = Ui.Text(Clean(line[2..]), 14, wrap: TextWrapping.Wrap);
                text.TextTrimming = TextTrimming.None;
                text.LineHeight = 20;
                row.Children.Add(text);
                panel.Children.Add(row);
            }
            else
            {
                var text = Ui.Text(Clean(line), 14, wrap: TextWrapping.Wrap);
                text.TextTrimming = TextTrimming.None;
                text.LineHeight = 20;
                text.Margin = new Thickness(0, 0, 0, 8);
                panel.Children.Add(text);
            }
        }
        return panel;
    }
}

// MARK: - Aufnahmen

internal sealed class RecordingsPage : Page
{
    private readonly Border _action = new();
    private readonly Border _body = new();

    public RecordingsPage()
    {
        Top(Ui.HeaderRow(
            Ui.PageTitle("Aufnahmen", $"Bildschirm mit Systemton – {AppSettings.Shared.RecordingHotkey.Display}. Dateien liegen in Videos\\Klar."),
            _action));
        Children.Add(_body);
    }

    protected override void Attach()
    {
        ScreenRecorder.Shared.Changed += Refresh;
        ScreenRecorder.Shared.ReloadFiles();
    }

    protected override void Detach() => ScreenRecorder.Shared.Changed -= Refresh;

    public override void Refresh()
    {
        var recorder = ScreenRecorder.Shared;
        _action.Child = recorder.IsBusy
            ? Ui.Text(recorder.IsRecording ? "Wird abgeschlossen …" : "Startet …", 12, "Muted")
            : Ui.TextButton(recorder.IsRecording ? "Aufnahme beenden" : "Aufnahme starten", recorder.Toggle, prominent: true);

        var panel = new DockPanel();
        if (recorder.ErrorMessage is { } error)
        {
            var e = Ui.Note(error, "Ink").Bottom(16);
            DockPanel.SetDock(e, Dock.Top);
            panel.Children.Add(e);
        }
        if (recorder.IsRecording)
        {
            var running = Ui.HStack(10, Ui.Dot(8, true), Ui.Body("Aufnahme läuft")).Bottom(24);
            DockPanel.SetDock(running, Dock.Top);
            panel.Children.Add(running);
        }
        if (recorder.Files.Count == 0) panel.Children.Add(Ui.EmptyNote("Noch keine Aufnahmen."));
        else
        {
            var list = new StackPanel();
            foreach (var file in recorder.Files)
            {
                var path = file;
                long size = 0;
                try { size = new FileInfo(path).Length; } catch { }
                var content = Ui.VStack(6, Ui.Body(Path.GetFileNameWithoutExtension(path)), Ui.Text(Format.FileSize(size), 12, "Faint"));
                var actions = Ui.HStack(18,
                    Ui.TextButton("Öffnen", () => Shell.Open(path)),
                    Ui.TextButton("Im Explorer", () => Shell.Reveal(path)),
                    Ui.TextButton("Löschen", () => recorder.Delete(path)));
                list.Children.Add(Ui.ListRow(content, actions));
            }
            panel.Children.Add(Ui.Scroll(list));
        }
        _body.Child = panel;
    }
}

// MARK: - Wach

internal sealed class AwakePage : Page
{
    private TextBlock? _status;
    private string _signature = "";

    protected override void Attach() => AwakeManager.Shared.Changed += Refresh;
    protected override void Detach() => AwakeManager.Shared.Changed -= Refresh;

    public override void Refresh()
    {
        var awake = AwakeManager.Shared;
        var settings = AppSettings.Shared;
        // Die Restzeit tickt jede Sekunde – dann nur den Statustext erneuern, nicht die ganze Seite.
        var signature = $"{awake.IsActive}|{awake.IsHolding}|{awake.LidMode}|{awake.LidError}|{settings.AwakeKeepsDisplay}|{settings.AwakeDuringCapture}";
        if (signature == _signature && _status != null)
        {
            _status.Text = awake.StatusText;
            return;
        }
        _signature = signature;
        Children.Clear();

        Top(Ui.HeaderRow(
            Ui.PageTitle("Cocaine", $"Hält PC und Bildschirm wach – {settings.AwakeHotkey.Display} schaltet um."),
            awake.IsActive ? Ui.TextButton("Beenden", awake.Stop, prominent: true) : null));

        _status = Ui.Body(awake.StatusText);
        Top(Ui.HStack(10, Ui.Dot(8, awake.IsHolding), _status).Bottom(40));

        Top(Ui.SectionLabel(awake.IsActive ? "Dauer ändern" : "Wach halten für"));
        var durations = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 48) };
        foreach (var (label, seconds) in AwakeManager.Durations)
        {
            var s = seconds;
            Ui.Add(durations, Ui.TextButton(label, () => awake.Start(s)), 22);
        }
        Ui.Add(durations, Ui.TextButton("Unbegrenzt", () => awake.Start(null)), 22);
        Top(durations);

        Top(Ui.SectionLabel("Verhalten"));
        Top(Ui.DotToggle("Bildschirm ebenfalls wach halten", settings.AwakeKeepsDisplay, v => settings.AwakeKeepsDisplay = v).Bottom(14));
        Top(Ui.DotToggle("Während Meetings und Bildschirmaufnahmen automatisch wach halten", settings.AwakeDuringCapture, v => settings.AwakeDuringCapture = v).Bottom(14));
        Top(Ui.DotToggle("Zugeklappt weiterlaufen (Deckel-Modus)", awake.LidMode, awake.SetLidMode).Bottom(10));
        if (awake.LidError is { } error) Top(Ui.Note(error, "Ink").Bottom(10));
        Top(Ui.Note(awake.LidMode
            ? "Deckel-Modus aktiv: Der PC schläft auch zugeklappt nicht. Nicht zugeklappt in die Tasche stecken – er wird warm. Endet mit „Beenden“, nach Ablauf der Zeit oder beim Beenden von Klar."
            : "Ohne Deckel-Modus geht ein zugeklapptes Notebook in den Energiesparmodus. Der Deckel-Modus stellt in den Windows-Energieoptionen „Beim Zuklappen“ auf „Nichts unternehmen“ und setzt den alten Wert danach wieder ein."));
        Children.Add(new Border()); // füllt den Rest
    }
}
