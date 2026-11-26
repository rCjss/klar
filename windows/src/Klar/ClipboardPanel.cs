using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Klar.Core;
using XamlAnimatedGif;

namespace Klar;

internal enum PanelTab { History, Gifs }

/// <summary>Schwebendes Panel mit dem Verlauf. Merkt sich beim Öffnen das aktive Fenster,
/// damit nach der Auswahl direkt dort eingefügt werden kann.</summary>
internal sealed class ClipboardPanel : Window
{
    private const double PanelWidth = 600, PanelHeight = 440, ShadowMargin = 28;
    private const int MaxRows = 150, GifColumns = 3;
    private const double GifWidth = 176, GifHeight = 112, GifGap = 8;
    private static readonly FontFamily IconFont = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    private readonly TextBox _search;
    private readonly TextBlock _searchHint;
    private readonly Dictionary<PanelTab, TextBlock> _tabLabels = [];
    private readonly Grid _body = new();
    private readonly DockPanel _footer = new() { Margin = new Thickness(28, 14, 28, 14), LastChildFill = false };

    private PanelTab _tab = PanelTab.History;
    private string _query = "", _gifQuery = "";
    private int _selected, _gifSelected;
    private List<ClipItem> _items = [];
    private readonly List<Row> _rows = [];
    private List<GiphyGif> _gifs = [];
    private readonly List<Border> _gifCells = [];
    private string? _gifStatus, _gifLoadedQuery;
    private bool _gifBusy, _switchingText, _hiding;
    private CancellationTokenSource? _gifSearch;
    private IntPtr _target;
    private Point _lastMouse;

    private static readonly Dictionary<string, byte[]> PreviewCache = [];

    public ClipboardPanel()
    {
        Title = "Klar Zwischenablage";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Width = PanelWidth + 2 * ShadowMargin;
        Height = PanelHeight + 2 * ShadowMargin;
        WindowStartupLocation = WindowStartupLocation.Manual;
        FontFamily = Theme.Font;

        // Kopfzeile: Suche und Reiter
        var searchGrid = Ui.Field("Suchen", "", OnSearchChanged, out _search, 20, FontWeights.Light);
        _searchHint = (TextBlock)searchGrid.Children[0];
        var tabs = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(18, 0, 0, 3) };
        foreach (var (tab, title) in new[] { (PanelTab.History, "Verlauf"), (PanelTab.Gifs, "GIFs") })
        {
            var label = Ui.Text(Ui.Tracked(title), 12);
            _tabLabels[tab] = label;
            var button = Ui.Plain(label, () => SwitchTab(tab));
            Ui.Add(tabs, button, 18);
        }
        var header = Ui.HeaderRow(searchGrid, tabs, alignRightTop: false);
        header.Margin = new Thickness(28, 26, 28, 18);

        var layout = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        layout.Children.Add(header);
        var top = Ui.Hairline(new Thickness(28, 0, 28, 0));
        DockPanel.SetDock(top, Dock.Top);
        layout.Children.Add(top);
        DockPanel.SetDock(_footer, Dock.Bottom);
        layout.Children.Add(_footer);
        var bottom = Ui.Hairline(new Thickness(28, 0, 28, 0));
        DockPanel.SetDock(bottom, Dock.Bottom);
        layout.Children.Add(bottom);
        layout.Children.Add(_body);

        // Der Schatten liegt auf einer eigenen Fläche hinter dem Inhalt – ein Effekt auf dem Inhalt selbst
        // würde die Schrift unscharf zeichnen.
        var shadow = new Border
        {
            CornerRadius = new CornerRadius(16),
            Margin = new Thickness(ShadowMargin),
            Effect = new DropShadowEffect { BlurRadius = 28, ShadowDepth = 6, Direction = 270, Opacity = 0.22, Color = Colors.Black },
        };
        shadow.SetResourceReference(Border.BackgroundProperty, "Paper");
        var card = new Border
        {
            CornerRadius = new CornerRadius(16),
            BorderThickness = new Thickness(1),
            Margin = new Thickness(ShadowMargin),
            Child = layout,
        };
        card.SetResourceReference(Border.BackgroundProperty, "Paper");
        card.SetResourceReference(Border.BorderBrushProperty, "Line");
        var root = new Grid();
        root.Children.Add(shadow);
        root.Children.Add(card);
        Content = root;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);

        PreviewKeyDown += OnKey;
        Deactivated += (_, _) => HidePanel();
        Closing += (_, e) => { e.Cancel = true; HidePanel(); };
        ClipboardStore.Shared.Changed += () => { if (IsVisible && _tab == PanelTab.History) RenderHistory(); };
        SourceInitialized += (_, _) =>
        {
            // Kein Eintrag in Alt+Tab.
            var hwnd = new WindowInteropHelper(this).Handle;
            var style = Native.GetWindowLongPtr(hwnd, Native.GWL_EXSTYLE).ToInt64() | Native.WS_EX_TOOLWINDOW;
            Native.SetWindowLongPtr(hwnd, Native.GWL_EXSTYLE, new IntPtr(style));
        };
    }

    // MARK: Anzeigen und Verbergen

    public void Toggle()
    {
        if (IsVisible) HidePanel(); else ShowPanel();
    }

    public void ShowPanel(PanelTab tab = PanelTab.History)
    {
        _target = CurrentTarget();
        _query = "";
        _selected = 0;
        _gifSelected = 0;
        _tab = PanelTab.History;
        SetSearchText("");
        if (tab != PanelTab.History) SwitchTab(tab); else Render();

        Opacity = 0;
        Show();
        PositionOnCursorMonitor();
        Opacity = 1;
        Activate();
        // Über ein Einzeltasten-Kürzel oder das Infobereich-Menü geöffnet, bekäme das Panel sonst keinen Fokus.
        Native.ForceForeground(new WindowInteropHelper(this).Handle);
        _search.Focus();
        Keyboard.Focus(_search);
    }

    public void HidePanel()
    {
        if (_hiding || !IsVisible) return;
        _hiding = true;
        try
        {
            _gifSearch?.Cancel();
            Hide();
        }
        finally { _hiding = false; }
    }

    /// <summary>Das Fenster, in das später eingefügt wird – nicht Klar selbst und nicht die Taskleiste.</summary>
    private static IntPtr CurrentTarget()
    {
        var window = Native.GetForegroundWindow();
        if (window == IntPtr.Zero) return IntPtr.Zero;
        Native.GetWindowThreadProcessId(window, out var pid);
        if (pid == (uint)Environment.ProcessId) return IntPtr.Zero;
        var cls = Native.ClassName(window);
        return cls is "Shell_TrayWnd" or "Shell_SecondaryTrayWnd" or "NotifyIconOverflowWindow"
            or "TopLevelWindowForOverflowXamlIsland" or "Progman" or "WorkerW" ? IntPtr.Zero : window;
    }

    /// <summary>Mittig auf dem Bildschirm, auf dem die Maus steht, leicht nach oben versetzt.</summary>
    private void PositionOnCursorMonitor()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero || !Native.GetCursorPos(out var cursor)) return;
        var monitor = Native.MonitorFromPoint(cursor, 2 /* nächster Bildschirm */);
        var info = new Native.MONITORINFO { Size = System.Runtime.InteropServices.Marshal.SizeOf<Native.MONITORINFO>() };
        if (!Native.GetMonitorInfo(monitor, ref info)) return;
        var work = info.Work;
        const uint flags = Native.SWP_NOSIZE | Native.SWP_NOZORDER | Native.SWP_NOACTIVATE;
        // Erst auf den Zielbildschirm setzen – dabei passt WPF die Größe an dessen Skalierung an.
        Native.SetWindowPos(hwnd, IntPtr.Zero, work.Left, work.Top, 0, 0, flags);
        if (!Native.GetWindowRect(hwnd, out var rect)) return;
        int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
        var scale = width / Width;
        var x = work.Left + (work.Right - work.Left - width) / 2;
        var y = work.Top + (work.Bottom - work.Top - height) / 2 - (int)(40 * scale);
        Native.SetWindowPos(hwnd, IntPtr.Zero, x, Math.Max(work.Top, y), 0, 0, flags);
    }

    // MARK: Suche und Reiter

    private void SetSearchText(string text)
    {
        _switchingText = true;
        _search.Text = text;
        _search.CaretIndex = text.Length;
        _switchingText = false;
    }

    private void OnSearchChanged(string text)
    {
        if (_switchingText) return;
        if (_tab == PanelTab.Gifs)
        {
            _gifQuery = text;
            ScheduleGifSearch(immediately: false);
        }
        else
        {
            _query = text;
            _selected = 0;
            RenderHistory();
        }
    }

    internal void SwitchTab(PanelTab tab)
    {
        _tab = tab;
        SetSearchText(tab == PanelTab.Gifs ? _gifQuery : _query);
        Render();
        if (tab == PanelTab.Gifs && _gifLoadedQuery != _gifQuery) ScheduleGifSearch(immediately: true);
        _search.Focus();
    }

    private void Render()
    {
        _searchHint.Text = _tab == PanelTab.Gifs ? "GIFs suchen" : "Suchen";
        foreach (var (tab, label) in _tabLabels)
            label.SetResourceReference(TextBlock.ForegroundProperty, tab == _tab ? "Ink" : "Faint");
        if (_tab == PanelTab.Gifs) RenderGifs(); else RenderHistory();
    }

    private void RenderFooter(int count)
    {
        _footer.Children.Clear();
        var hints = new StackPanel { Orientation = Orientation.Horizontal };
        void Hint(string key, string label)
        {
            var pair = Ui.HStack(6, Ui.Text(key, 12), Ui.Small(label));
            Ui.Add(hints, pair, 22);
        }
        if (_tab == PanelTab.Gifs)
        {
            Hint("↩", "Einfügen");
            Hint("Tab", "Verlauf");
        }
        else
        {
            Hint("↩", "Einfügen");
            Hint("Strg+↩", "Kopieren");
            Hint("Strg+P", "Anpinnen");
            Hint("Umschalt+Entf", "Löschen");
            Hint("Tab", "GIFs");
        }
        DockPanel.SetDock(hints, Dock.Left);
        _footer.Children.Add(hints);
        var right = Ui.HStack(10, _tab == PanelTab.Gifs && _gifBusy ? Ui.Text("…", 12, "Faint") : null, Ui.Text(count.ToString(), 12, "Faint"));
        DockPanel.SetDock(right, Dock.Right);
        _footer.Children.Add(right);
    }

    // MARK: Verlauf

    private sealed class Row
    {
        public required Border Root;
        public required TextBlock Index, Pin, Time;
        public TextBlock? Preview;
        public required ClipItem Item;

        public void Apply(bool selected)
        {
            if (selected)
            {
                Root.Background = Theme.InkBrush();
                Index.Foreground = Theme.OnInk(0.6);
                Time.Foreground = Theme.OnInk(0.6);
                Pin.Foreground = Item.Pinned ? Theme.OnInk() : Theme.OnInk(0.35);
                if (Preview != null) Preview.Foreground = Theme.OnInk();
            }
            else
            {
                Root.Background = Brushes.Transparent;
                Index.SetResourceReference(TextBlock.ForegroundProperty, "Faint");
                Time.SetResourceReference(TextBlock.ForegroundProperty, "Faint");
                Pin.SetResourceReference(TextBlock.ForegroundProperty, Item.Pinned ? "Ink" : "Faint");
                Preview?.SetResourceReference(TextBlock.ForegroundProperty, "Ink");
            }
        }
    }

    private void RenderHistory()
    {
        _items = ClipboardStore.Shared.Ordered.Where(i => i.Matches(_query)).ToList();
        _selected = Math.Clamp(_selected, 0, Math.Max(0, _items.Count - 1));
        _rows.Clear();
        _body.Children.Clear();
        RenderFooter(_items.Count);
        if (_items.Count == 0)
        {
            _body.Children.Add(Ui.EmptyNote(_query.Length == 0 ? "Noch nichts kopiert." : "Keine Treffer."));
            return;
        }
        var list = new StackPanel { Margin = new Thickness(0, 10, 0, 10) };
        for (var i = 0; i < _items.Count && i < MaxRows; i++)
        {
            var row = BuildRow(_items[i], i);
            _rows.Add(row);
            list.Children.Add(row.Root);
        }
        if (_items.Count > MaxRows)
            list.Children.Add(Ui.Small($"… {_items.Count - MaxRows} weitere. Tippen, um zu suchen.", "Faint").With(new Thickness(28, 10, 28, 4)));
        _body.Children.Add(Ui.Scroll(list));
        ApplySelection(scroll: false);
    }

    private Row BuildRow(ClipItem item, int index)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(30) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var number = Ui.Text(index < 9 ? (index + 1).ToString() : "", 12, "Faint");
        number.HorizontalAlignment = HorizontalAlignment.Right;
        number.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(number);

        var pin = new TextBlock
        {
            Text = item.Pinned ? "" : "",
            FontFamily = IconFont,
            FontSize = 11,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var pinButton = Ui.Plain(pin, () => TogglePin(item));
        pinButton.ToolTip = item.Pinned ? "Loslösen" : "Anpinnen";
        pinButton.HorizontalContentAlignment = HorizontalAlignment.Center;
        pinButton.Padding = new Thickness(4);
        Grid.SetColumn(pinButton, 1);
        grid.Children.Add(pinButton);

        TextBlock? preview = null;
        FrameworkElement content;
        if (item.Kind == ClipKind.Image && Ui.Thumbnail(item.ImageFile, 88) is { } thumb)
            content = Ui.Picture(thumb, 44);
        else
        {
            preview = Ui.Text(item.Preview.Length > 400 ? item.Preview[..400] : item.Preview, 14, maxLines: 2);
            content = preview;
        }
        content.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(content, 2);
        grid.Children.Add(content);

        var time = Ui.Text(Format.Relative(item.CreatedAt), 12, "Faint");
        time.VerticalAlignment = VerticalAlignment.Center;
        time.Margin = new Thickness(14, 0, 0, 0);
        Grid.SetColumn(time, 3);
        grid.Children.Add(time);

        var root = new Border { Padding = new Thickness(28, 11, 28, 11), Child = grid, Background = Brushes.Transparent, Cursor = Cursors.Hand };
        root.MouseLeftButtonUp += (_, e) => { if (!e.Handled) Paste(item); };
        // Nur echte Mausbewegung wählt aus – sonst würde Scrollen per Tastatur die Auswahl verschieben.
        root.MouseMove += (_, e) =>
        {
            var p = e.GetPosition(this);
            if (p == _lastMouse) return;
            _lastMouse = p;
            if (_selected != index) { _selected = index; ApplySelection(scroll: false); }
        };
        return new Row { Root = root, Index = number, Pin = pin, Time = time, Preview = preview, Item = item };
    }

    private void ApplySelection(bool scroll)
    {
        for (var i = 0; i < _rows.Count; i++) _rows[i].Apply(i == _selected);
        if (scroll && _selected < _rows.Count) _rows[_selected].Root.BringIntoView();
    }

    private ClipItem? Current => _selected < _items.Count ? _items[_selected] : null;

    private void Paste(ClipItem? item = null)
    {
        item ??= Current;
        if (item == null) return;
        var target = _target;
        HidePanel();
        Paster.Paste(item, target);
    }

    private void CopyOnly()
    {
        if (Current is not { } item) return;
        Paster.Write(item);
        HidePanel();
    }

    private void TogglePin(ClipItem? item = null)
    {
        item ??= Current;
        if (item != null) ClipboardStore.Shared.TogglePin(item.Id);
    }

    private void DeleteCurrent()
    {
        if (Current is { } item) ClipboardStore.Shared.Remove(item.Id);
    }

    // MARK: GIFs

    private void ScheduleGifSearch(bool immediately)
    {
        if (_tab != PanelTab.Gifs) return;
        _gifSearch?.Cancel();
        var cts = _gifSearch = new CancellationTokenSource();
        var query = _gifQuery;
        _ = LoadGifsAsync(query, immediately, cts.Token);
    }

    private async Task LoadGifsAsync(string query, bool immediately, CancellationToken ct)
    {
        try
        {
            if (!immediately) await Task.Delay(350, ct);
            _gifBusy = true;
            _gifStatus = null;
            if (_tab == PanelTab.Gifs) RenderGifs();
            var result = await GiphyClient.FetchAsync(query, AppSettings.Shared.GiphyApiKey, ct: ct);
            ct.ThrowIfCancellationRequested();
            _gifs = result;
            _gifSelected = 0;
            _gifLoadedQuery = query;
            _gifStatus = result.Count == 0 ? "Keine Treffer." : null;
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            if (!ct.IsCancellationRequested)
            {
                _gifs = [];
                _gifStatus = e is GiphyException ? e.Message : "Giphy ist nicht erreichbar.";
            }
        }
        // Nur die jeweils jüngste Suche darf den Zustand zurücksetzen – auch wenn sie abgebrochen wurde.
        if (_gifSearch == null || _gifSearch.Token != ct) return;
        _gifBusy = false;
        if (!ct.IsCancellationRequested && _tab == PanelTab.Gifs && IsVisible) RenderGifs();
    }

    private void RenderGifs()
    {
        _body.Children.Clear();
        _gifCells.Clear();
        RenderFooter(_gifs.Count);
        if (_gifs.Count == 0)
        {
            var note = Ui.EmptyNote(_gifStatus ?? (_gifBusy ? "…" : "Suchbegriff eingeben."));
            note.TextWrapping = TextWrapping.Wrap;
            note.TextAlignment = TextAlignment.Center;
            note.Margin = new Thickness(28, 80, 28, 80);
            _body.Children.Add(note);
            return;
        }
        var wrap = new WrapPanel { Margin = new Thickness(28, 14, 28 - GifGap, 14), Width = GifColumns * (GifWidth + GifGap) };
        for (var i = 0; i < _gifs.Count; i++)
        {
            var index = i;
            var gif = _gifs[i];
            var image = new Image { Stretch = Stretch.UniformToFill, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            var cell = new Border
            {
                Width = GifWidth, Height = GifHeight,
                Margin = new Thickness(0, 0, GifGap, GifGap),
                BorderThickness = new Thickness(2),
                Child = image,
                Cursor = Cursors.Hand,
                Clip = new RectangleGeometry(new Rect(0, 0, GifWidth, GifHeight), 4, 4),
            };
            cell.SetResourceReference(Border.BackgroundProperty, "Hover");
            cell.MouseLeftButtonUp += (_, _) => PasteGif(gif);
            cell.MouseMove += (_, e) =>
            {
                var p = e.GetPosition(this);
                if (p == _lastMouse) return;
                _lastMouse = p;
                if (_gifSelected != index) { _gifSelected = index; ApplyGifSelection(scroll: false); }
            };
            _gifCells.Add(cell);
            wrap.Children.Add(cell);
            _ = LoadPreviewAsync(image, gif.PreviewUrl);
        }
        _body.Children.Add(Ui.Scroll(wrap));
        ApplyGifSelection(scroll: false);
    }

    private static async Task LoadPreviewAsync(Image image, string url)
    {
        try
        {
            if (!PreviewCache.TryGetValue(url, out var bytes))
            {
                if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps) return;
                bytes = await GiphyClient.DownloadBytesAsync(url);
                if (PreviewCache.Count > 120) PreviewCache.Clear();
                PreviewCache[url] = bytes;
            }
            AnimationBehavior.SetRepeatBehavior(image, RepeatBehavior.Forever);
            AnimationBehavior.SetSourceStream(image, new MemoryStream(bytes));
        }
        catch (Exception e) { Log.Write("GIF-Vorschau: " + e.Message); }
    }

    private void ApplyGifSelection(bool scroll)
    {
        for (var i = 0; i < _gifCells.Count; i++)
        {
            if (i == _gifSelected) _gifCells[i].SetResourceReference(Border.BorderBrushProperty, "Ink");
            else _gifCells[i].BorderBrush = Brushes.Transparent;
        }
        if (scroll && _gifSelected < _gifCells.Count) _gifCells[_gifSelected].BringIntoView();
    }

    private async void PasteGif(GiphyGif? gif = null)
    {
        gif ??= _gifSelected < _gifs.Count ? _gifs[_gifSelected] : null;
        if (gif == null || _gifBusy) return;
        _gifBusy = true;
        RenderFooter(_gifs.Count);
        var target = _target;
        try
        {
            var file = await GiphyClient.DownloadAsync(gif);
            _gifBusy = false;
            HidePanel();
            if (Paster.WriteGif(file)) _ = Paster.SendPasteAsync(target);
        }
        catch (Exception e)
        {
            Log.Write("GIF-Download: " + e.Message);
            _gifBusy = false;
            _gifStatus = "GIF konnte nicht geladen werden.";
            if (IsVisible && _tab == PanelTab.Gifs) RenderFooter(_gifs.Count);
        }
    }

    // MARK: Tastatur

    private void OnKey(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        if (key == Key.Tab)
        {
            SwitchTab(_tab == PanelTab.History ? PanelTab.Gifs : PanelTab.History);
            e.Handled = true;
            return;
        }
        if (key == Key.Escape) { HidePanel(); e.Handled = true; return; }
        var digit = key is >= Key.D1 and <= Key.D9 ? key - Key.D1 : key is >= Key.NumPad1 and <= Key.NumPad9 ? key - Key.NumPad1 : -1;

        if (_tab == PanelTab.Gifs)
        {
            var count = _gifs.Count;
            var old = _gifSelected;
            switch (key)
            {
                case Key.Left: _gifSelected = Math.Max(_gifSelected - 1, 0); break;
                case Key.Right: _gifSelected = Math.Min(_gifSelected + 1, Math.Max(0, count - 1)); break;
                case Key.Up: _gifSelected = Math.Max(_gifSelected - GifColumns, 0); break;
                case Key.Down: _gifSelected = Math.Min(_gifSelected + GifColumns, Math.Max(0, count - 1)); break;
                case Key.Enter: PasteGif(); e.Handled = true; return;
                default:
                    if (ctrl && digit >= 0 && digit < count) { _gifSelected = digit; PasteGif(); e.Handled = true; }
                    return;
            }
            e.Handled = true;
            if (old != _gifSelected) ApplyGifSelection(scroll: true);
            return;
        }

        var last = Math.Max(0, Math.Min(_items.Count, MaxRows) - 1);
        switch (key)
        {
            case Key.Down:
                _selected = Math.Min(_selected + 1, last);
                ApplySelection(scroll: true);
                e.Handled = true;
                break;
            case Key.Up:
                _selected = Math.Max(_selected - 1, 0);
                ApplySelection(scroll: true);
                e.Handled = true;
                break;
            case Key.Enter:
                if (ctrl) CopyOnly(); else Paste();
                e.Handled = true;
                break;
            case Key.Delete when shift:
                DeleteCurrent();
                e.Handled = true;
                break;
            case Key.P when ctrl:
                TogglePin();
                e.Handled = true;
                break;
            default:
                if (ctrl && digit >= 0 && digit < _items.Count)
                {
                    _selected = digit;
                    Paste();
                    e.Handled = true;
                }
                break;
        }
    }
}
