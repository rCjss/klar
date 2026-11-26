using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Klar.Core;

namespace Klar;

/// <summary>Diktat per Hotkey: Tippen = Start/Stopp, Halten = Push-to-Talk.</summary>
internal sealed class DictationEngine
{
    public static DictationEngine Shared { get; } = new();

    public enum Phase { Idle, Listening, Finishing, Done, Error }

    public Phase State { get; private set; } = Phase.Idle;
    /// <summary>Text zu <see cref="Phase.Done"/> oder <see cref="Phase.Error"/>.</summary>
    public string Message { get; private set; } = "";
    public string CommittedText { get; private set; } = "";
    public string PartialText { get; private set; } = "";
    public float Level => _session?.Level ?? 0;
    public bool IsListening => State == Phase.Listening;

    public event Action? Changed;

    private AudioCapture? _capture;
    private TranscriptionSession? _session;
    private readonly List<string> _committed = [];
    private DateTime _startedAt;
    private DateTime? _pressStarted;
    private DictationOverlay? _overlay;
    private int _generation;

    private DictationOverlay Overlay => _overlay ??= new DictationOverlay();
    private bool IsTerminal => State is Phase.Done or Phase.Error;

    // Hotkey-Semantik: kurz tippen schaltet um, lange halten = Push-to-Talk.
    public void HotkeyPressed()
    {
        _pressStarted = null;
        if (State == Phase.Listening) Stop();
        else if (State == Phase.Idle || IsTerminal)
        {
            Start();
            // Erst jetzt zählt die Haltezeit – das Öffnen des Mikrofons kann selbst einige Zehntel dauern
            // und darf ein kurzes Antippen nicht wie „halten und loslassen“ aussehen lassen.
            if (State == Phase.Listening) _pressStarted = DateTime.UtcNow;
        }
    }

    public void HotkeyReleased()
    {
        if (_pressStarted is not { } pressed) return;
        _pressStarted = null;
        if ((DateTime.UtcNow - pressed).TotalSeconds > 0.45 && State == Phase.Listening) Stop();
    }

    /// <summary>Während des Haltens wurde eine andere Taste gedrückt (z. B. Strg+C) – kein Diktat gemeint.</summary>
    public void HotkeyCancelled()
    {
        if (State != Phase.Listening || (DateTime.UtcNow - _startedAt).TotalSeconds >= 2) return;
        _pressStarted = null;
        Cancel();
    }

    public void Toggle()
    {
        if (State == Phase.Listening) Stop(); else Start();
    }

    public void Start()
    {
        if (State is Phase.Listening or Phase.Finishing) return;
        var transcriber = SpeechService.Shared.Get(out var problem);
        if (transcriber == null) { Fail(problem ?? "Spracherkennung nicht verfügbar."); return; }

        var settings = AppSettings.Shared;
        _committed.Clear();
        CommittedText = "";
        PartialText = "";
        var generation = ++_generation;
        var session = new TranscriptionSession(transcriber, settings.LanguageCode,
            hint: VoiceCommands.RecognitionHint(settings.Snippets, settings.CommandPrefix));
        session.Committed += (text, _) => UiThread.Post(() =>
        {
            if (generation != _generation) return;
            _committed.Add(text);
            CommittedText = string.Join(" ", _committed);
            Notify();
        });
        session.PendingChanged += pending => UiThread.Post(() =>
        {
            if (generation != _generation) return;
            PartialText = pending > 0 ? "…" : "";
            Notify();
        });
        session.Failed += e => UiThread.Post(() =>
        {
            if (generation == _generation && State is Phase.Listening or Phase.Finishing) Message = "Erkennung fehlgeschlagen: " + e.Message;
        });

        try
        {
            _capture = AudioCapture.Microphone(samples => session.Append(samples));
            _capture.Start();
        }
        catch (Exception e)
        {
            session.Cancel();
            _capture?.Dispose();
            _capture = null;
            Fail(AudioCapture.Describe(e, "das Mikrofon"));
            return;
        }
        _session = session;
        _startedAt = DateTime.UtcNow;
        Message = "";
        State = Phase.Listening;
        Overlay.Present();
        Notify();
    }

    public async void Stop()
    {
        if (State != Phase.Listening || _session is not { } session) return;
        State = Phase.Finishing;
        Notify();
        var generation = _generation;
        // Kurz nachlaufen lassen: Was die Soundkarte noch puffert, gehört zur letzten Silbe.
        await Task.Delay(150);
        if (generation != _generation) return;
        _capture?.Dispose();
        _capture = null;
        try { await session.StopAsync(); }
        catch (Exception e) { Log.Write("Diktat-Abschluss: " + e); }
        // Ausstehende Meldungen der Sitzung (über den Dispatcher) zuerst verarbeiten lassen.
        await Dispatcher.Yield(DispatcherPriority.Background);
        if (generation != _generation) return;
        await FinishAsync();
    }

    public void Cancel()
    {
        _generation++;
        _capture?.Dispose();
        _capture = null;
        _session?.Cancel();
        _session = null;
        State = Phase.Idle;
        Overlay.Hide();
        Notify();
    }

    private async Task FinishAsync()
    {
        _session = null;
        var raw = string.Join(" ", _committed).Trim();
        var duration = (DateTime.UtcNow - _startedAt).TotalSeconds;
        if (raw.Length == 0)
        {
            if (Message.Length > 0) { Fail(Message); return; }
            State = Phase.Idle;
            Overlay.Hide();
            Notify();
            return;
        }
        var settings = AppSettings.Shared;
        var result = VoiceCommands.Apply(raw, settings.Snippets, settings.CommandPrefix);
        DictationStore.Shared.Add(new Dictation { Text = result.Text, Duration = duration, UsedSnippet = result.UsedSnippet });

        string message;
        if (!Paster.WriteText(result.Text))
            message = "Zwischenablage gesperrt – der Text steht unter „Diktate“";
        else if (settings.PasteAfterDictation)
            message = await Paster.SendPasteAsync() ? "Eingefügt" : "Kopiert – zum Einfügen Strg+V drücken";
        else message = "Kopiert";

        CommittedText = result.Text;
        PartialText = "";
        Message = message;
        State = Phase.Done;
        Notify();
        var generation = _generation;
        await Task.Delay(1400);
        if (generation != _generation || State != Phase.Done) return;
        State = Phase.Idle;
        Overlay.Hide();
        Notify();
    }

    private async void Fail(string message)
    {
        var generation = ++_generation;
        _session = null;
        Message = message;
        State = Phase.Error;
        Overlay.Present();
        Notify();
        await Task.Delay(Math.Clamp(1500 + message.Length * 35, 2200, 6000));
        if (generation != _generation || State != Phase.Error) return;
        State = Phase.Idle;
        Overlay.Hide();
        Notify();
    }

    private void Notify() => Changed?.Invoke();
}

/// <summary>Kleine Kapsel am unteren Bildschirmrand mit dem erkannten Text. Nimmt nie den Fokus.</summary>
internal sealed class DictationOverlay : Window
{
    private const double PanelWidth = 560, PanelHeight = 180;
    private readonly Border _capsule;
    private readonly TextBlock _text;
    private readonly TextBlock _status;
    private readonly Grid _indicator;
    private readonly Rectangle[] _bars = new Rectangle[4];
    private readonly Ellipse _dot;
    private readonly DispatcherTimer _levelTimer;

    public DictationOverlay()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        Focusable = false;
        IsHitTestVisible = false;
        ResizeMode = ResizeMode.NoResize;
        Width = PanelWidth;
        Height = PanelHeight;
        Title = "Klar Diktat";

        _text = new TextBlock
        {
            FontFamily = Theme.Font, FontSize = 15, TextWrapping = TextWrapping.Wrap,
            LineHeight = 21, LineStackingStrategy = LineStackingStrategy.BlockLineHeight, MaxHeight = 21 * 5,
        };
        _status = new TextBlock { FontFamily = Theme.Font, FontSize = 12, Margin = new Thickness(0, 6, 0, 0), TextWrapping = TextWrapping.Wrap };
        var content = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        content.Children.Add(_text);
        content.Children.Add(_status);

        _indicator = new Grid { Width = 24, Height = 18, Margin = new Thickness(0, 3, 14, 0), VerticalAlignment = VerticalAlignment.Top };
        var bars = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        for (var i = 0; i < _bars.Length; i++)
        {
            _bars[i] = new Rectangle { Width = 3, Height = 4, RadiusX = 1.5, RadiusY = 1.5, Margin = new Thickness(i == 0 ? 0 : 3, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            bars.Children.Add(_bars[i]);
        }
        _dot = new Ellipse { Width = 8, Height = 8, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        _indicator.Children.Add(bars);
        _indicator.Children.Add(_dot);

        var row = new DockPanel();
        DockPanel.SetDock(_indicator, Dock.Left);
        row.Children.Add(_indicator);
        row.Children.Add(content);
        _capsule = new Border
        {
            CornerRadius = new CornerRadius(22),
            Padding = new Thickness(20, 14, 20, 14),
            VerticalAlignment = VerticalAlignment.Bottom,
            Child = row,
        };
        Content = _capsule;

        _levelTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(70) };
        _levelTimer.Tick += (_, _) => UpdateLevel();
        DictationEngine.Shared.Changed += Update;
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            var style = Native.GetWindowLongPtr(hwnd, Native.GWL_EXSTYLE).ToInt64();
            style |= Native.WS_EX_NOACTIVATE | Native.WS_EX_TRANSPARENT | Native.WS_EX_TOOLWINDOW;
            Native.SetWindowLongPtr(hwnd, Native.GWL_EXSTYLE, new IntPtr(style));
        };
    }

    public void Present()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - PanelWidth) / 2;
        Top = area.Bottom - PanelHeight - 48;
        Update();
        if (!IsVisible) Show();
        _levelTimer.Start();
    }

    public new void Hide()
    {
        _levelTimer.Stop();
        if (IsVisible) base.Hide();
    }

    private void UpdateLevel()
    {
        var engine = DictationEngine.Shared;
        if (engine.State != DictationEngine.Phase.Listening) return;
        var level = engine.Level;
        for (var i = 0; i < _bars.Length; i++) _bars[i].Height = 4 + level * (12 + i * 3);
    }

    private void Update()
    {
        var engine = DictationEngine.Shared;
        var paper = Theme.OnInk();
        var soft = Theme.OnInk(0.55);
        _capsule.Background = Theme.InkBrush();
        foreach (var b in _bars) b.Fill = paper;

        var listening = engine.State == DictationEngine.Phase.Listening;
        ((UIElement)_indicator.Children[0]).Visibility = listening ? Visibility.Visible : Visibility.Collapsed;
        _dot.Visibility = listening ? Visibility.Collapsed : Visibility.Visible;
        if (engine.State == DictationEngine.Phase.Finishing)
        {
            _dot.Fill = Brushes.Transparent;
            _dot.Stroke = Theme.OnInk(0.5);
            _dot.StrokeThickness = 1;
            _dot.Width = _dot.Height = 10;
        }
        else
        {
            _dot.Fill = paper;
            _dot.StrokeThickness = 0;
            _dot.Width = _dot.Height = 8;
        }

        _text.Inlines.Clear();
        _status.Text = "";
        _status.Visibility = Visibility.Collapsed;
        var hasText = engine.CommittedText.Length > 0 || engine.PartialText.Length > 0;
        switch (engine.State)
        {
            case DictationEngine.Phase.Listening when !hasText:
                _text.Inlines.Add(new Run("Sprich einfach los") { Foreground = soft });
                break;
            case DictationEngine.Phase.Finishing when !hasText:
                _text.Inlines.Add(new Run("Einen Moment …") { Foreground = soft });
                break;
            case DictationEngine.Phase.Listening or DictationEngine.Phase.Finishing:
                Flow(engine, paper);
                break;
            case DictationEngine.Phase.Done:
                Flow(engine, paper);
                _status.Text = engine.Message;
                _status.Foreground = soft;
                _status.Visibility = Visibility.Visible;
                break;
            case DictationEngine.Phase.Error:
                _text.Inlines.Add(new Run(engine.Message) { Foreground = paper });
                break;
        }
    }

    /// <summary>Bestätigter Text in voller Deckkraft, der entstehende Teil leicht abgesetzt.
    /// Bei langen Diktaten bleibt das Ende sichtbar.</summary>
    private void Flow(DictationEngine engine, Brush paper)
    {
        var committed = engine.CommittedText;
        if (committed.Length > 330) committed = "… " + committed[^320..];
        _text.Inlines.Add(new Run(committed) { Foreground = paper });
        if (engine.PartialText.Length > 0)
            _text.Inlines.Add(new Run((committed.Length == 0 ? "" : " ") + engine.PartialText) { Foreground = Theme.OnInk(0.6) });
    }
}
