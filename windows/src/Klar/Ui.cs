using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Klar.Core;

namespace Klar;

/// <summary>Bausteine der Oberfläche: nur Schrift, Haarlinien und Weißraum.</summary>
internal static class Ui
{
    public static TextBlock Text(string text, double size = 14, string brush = "Ink", FontWeight? weight = null,
                                 TextWrapping wrap = TextWrapping.NoWrap, int maxLines = 0)
    {
        var t = new TextBlock
        {
            Text = text,
            FontFamily = Theme.Font,
            FontSize = size,
            FontWeight = weight ?? FontWeights.Normal,
            TextWrapping = wrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        if (maxLines > 0)
        {
            t.TextWrapping = TextWrapping.Wrap;
            t.LineHeight = Math.Round(size * 1.4);
            t.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
            t.MaxHeight = t.LineHeight * maxLines;
        }
        t.SetResourceReference(TextBlock.ForegroundProperty, brush);
        return t;
    }

    public static TextBlock Body(string text, string brush = "Ink") => Text(text, 14, brush);
    public static TextBlock Small(string text, string brush = "Muted") => Text(text, 12, brush);

    /// <summary>Erklärtext über mehrere Zeilen.</summary>
    public static TextBlock Note(string text, string brush = "Muted")
    {
        var t = Text(text, 12, brush, wrap: TextWrapping.Wrap);
        t.TextTrimming = TextTrimming.None;
        t.LineHeight = 18;
        return t;
    }

    /// <summary>WPF kennt keine Laufweite – dünne Leerzeichen zwischen den Buchstaben ersetzen sie.</summary>
    public static string Tracked(string text) => string.Join(" ", text.ToCharArray());

    /// <summary>Kleine Überschrift in Versalien mit viel Abstand.</summary>
    public static TextBlock SectionLabel(string text)
    {
        var t = Text(Tracked(text.ToUpper()), 11, "Muted", FontWeights.Medium);
        t.Margin = new Thickness(0, 0, 0, 14);
        return t;
    }

    public static Border Hairline(Thickness margin = default)
    {
        var b = new Border { Height = 1, Margin = margin, SnapsToDevicePixels = true };
        b.SetResourceReference(Border.BackgroundProperty, "Line");
        return b;
    }

    public static Button Plain(UIElement content, Action action)
    {
        var b = new Button { Content = content, Style = (Style)Application.Current.Resources["PlainButton"] };
        b.Click += (_, e) => { e.Handled = true; action(); };
        return b;
    }

    /// <summary>Textbutton ohne jede Dekoration – nur Schrift, die beim Überfahren dunkler wird.</summary>
    public static Button TextButton(string title, Action action, bool prominent = false)
    {
        var label = Text(title, 12, prominent ? "Ink" : "Muted");
        var b = Plain(label, action);
        if (!prominent)
        {
            b.MouseEnter += (_, _) => label.SetResourceReference(TextBlock.ForegroundProperty, "Ink");
            b.MouseLeave += (_, _) => label.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        }
        return b;
    }

    public static StackPanel HStack(double spacing, params UIElement?[] children) => Stack(Orientation.Horizontal, spacing, children);
    public static StackPanel VStack(double spacing, params UIElement?[] children) => Stack(Orientation.Vertical, spacing, children);

    private static StackPanel Stack(Orientation orientation, double spacing, UIElement?[] children)
    {
        var p = new StackPanel { Orientation = orientation };
        foreach (var c in children) Add(p, c, spacing);
        return p;
    }

    /// <summary>Hängt ein Element mit Abstand zum Vorgänger an (StackPanel kennt keinen Abstand).</summary>
    public static void Add(StackPanel panel, UIElement? child, double spacing = 0)
    {
        if (child == null) return;
        if (spacing > 0 && panel.Children.Count > 0 && child is FrameworkElement fe)
        {
            var m = fe.Margin;
            fe.Margin = panel.Orientation == Orientation.Horizontal
                ? new Thickness(m.Left + spacing, m.Top, m.Right, m.Bottom)
                : new Thickness(m.Left, m.Top + spacing, m.Right, m.Bottom);
        }
        panel.Children.Add(child);
    }

    public static T With<T>(this T element, Thickness margin) where T : FrameworkElement
    {
        element.Margin = margin;
        return element;
    }

    public static T Bottom<T>(this T element, double bottom) where T : FrameworkElement
    {
        element.Margin = new Thickness(element.Margin.Left, element.Margin.Top, element.Margin.Right, bottom);
        return element;
    }

    /// <summary>Titel links, Aktion rechts.</summary>
    public static Grid HeaderRow(UIElement left, UIElement? right, bool alignRightTop = true)
    {
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(left);
        if (right != null)
        {
            Grid.SetColumn(right, 1);
            if (alignRightTop && right is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Top;
            g.Children.Add(right);
        }
        return g;
    }

    public static StackPanel PageTitle(string title, string? subtitle = null)
    {
        var p = new StackPanel { Margin = new Thickness(0, 0, 0, 36) };
        p.Children.Add(Text(title, 26, "Ink", FontWeights.Light));
        if (subtitle != null)
        {
            var s = Note(subtitle);
            s.Margin = new Thickness(0, 8, 24, 0);
            p.Children.Add(s);
        }
        return p;
    }

    public static TextBlock EmptyNote(string text)
    {
        var t = Body(text, "Muted");
        t.HorizontalAlignment = HorizontalAlignment.Center;
        t.VerticalAlignment = VerticalAlignment.Center;
        t.Margin = new Thickness(0, 80, 0, 80);
        return t;
    }

    public static Ellipse Dot(double size, bool filled)
    {
        var e = new Ellipse { Width = size, Height = size, StrokeThickness = 1, VerticalAlignment = VerticalAlignment.Center };
        e.SetResourceReference(Shape.StrokeProperty, "Ink");
        if (filled) e.SetResourceReference(Shape.FillProperty, "Ink"); else e.Fill = Brushes.Transparent;
        return e;
    }

    /// <summary>Minimaler Schalter: ein Kreis, gefüllt oder leer.</summary>
    public static Button DotToggle(string label, bool isOn, Action<bool> changed)
    {
        var state = isOn;
        var dot = Dot(12, state);
        var text = Body(label);
        text.TextWrapping = TextWrapping.Wrap;
        text.TextTrimming = TextTrimming.None;
        text.Margin = new Thickness(12, 0, 0, 0);
        var row = new DockPanel();
        DockPanel.SetDock(dot, Dock.Left);
        row.Children.Add(dot);
        row.Children.Add(text);
        return Plain(row, () =>
        {
            state = !state;
            if (state) dot.SetResourceReference(Shape.FillProperty, "Ink"); else dot.Fill = Brushes.Transparent;
            changed(state);
        });
    }

    /// <summary>Textfeld ohne Rahmen. Der Platzhalter verschwindet, sobald Text darin steht.</summary>
    public static Grid Field(string placeholder, string text, Action<string> changed, out TextBox box, double size = 14,
                             FontWeight? weight = null, bool multiline = false)
    {
        var tb = new TextBox
        {
            Text = text,
            FontFamily = Theme.Font,
            FontSize = size,
            FontWeight = weight ?? FontWeights.Normal,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Padding = new Thickness(0),
            Margin = new Thickness(-2, 0, 0, 0),
            VerticalContentAlignment = VerticalAlignment.Center,
            AcceptsReturn = multiline,
            TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
        };
        tb.SetResourceReference(Control.ForegroundProperty, "Ink");
        tb.SetResourceReference(System.Windows.Controls.Primitives.TextBoxBase.CaretBrushProperty, "Ink");
        tb.SetResourceReference(System.Windows.Controls.Primitives.TextBoxBase.SelectionBrushProperty, "Muted");
        var hint = Text(placeholder, size, "Faint", weight);
        hint.IsHitTestVisible = false;
        hint.VerticalAlignment = multiline ? VerticalAlignment.Top : VerticalAlignment.Center;
        hint.Visibility = text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        tb.TextChanged += (_, _) =>
        {
            hint.Visibility = tb.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            changed(tb.Text);
        };
        var g = new Grid();
        g.Children.Add(hint);
        g.Children.Add(tb);
        box = tb;
        return g;
    }

    /// <summary>Textfeld ohne Rahmen, nur eine Haarlinie darunter.</summary>
    public static StackPanel UnderlinedField(string placeholder, string text, Action<string> changed, out TextBox box)
    {
        var p = new StackPanel();
        p.Children.Add(Field(placeholder, text, changed, out box));
        p.Children.Add(Hairline(new Thickness(0, 8, 0, 0)));
        return p;
    }

    /// <summary>Feld für Schlüssel: Eingabe verdeckt.</summary>
    public static Grid SecretField(string placeholder, string value, Action<string> changed, double width)
    {
        var pb = new PasswordBox
        {
            Password = value,
            FontFamily = Theme.Font,
            FontSize = 14,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Padding = new Thickness(0),
            Margin = new Thickness(-2, 0, 0, 0),
            Width = width,
        };
        pb.SetResourceReference(Control.ForegroundProperty, "Ink");
        pb.SetResourceReference(PasswordBox.CaretBrushProperty, "Ink");
        var hint = Text(placeholder, 14, "Faint");
        hint.IsHitTestVisible = false;
        hint.VerticalAlignment = VerticalAlignment.Center;
        hint.Visibility = value.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        pb.PasswordChanged += (_, _) =>
        {
            hint.Visibility = pb.Password.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            changed(pb.Password);
        };
        var g = new Grid { Width = width, HorizontalAlignment = HorizontalAlignment.Left };
        g.Children.Add(hint);
        g.Children.Add(pb);
        return g;
    }

    /// <summary>Zeile einer Liste: Inhalt links, Aktionen rechts (nur beim Überfahren sichtbar), Haarlinie darunter.</summary>
    public static FrameworkElement ListRow(UIElement content, StackPanel? actions, Action? click = null, Func<bool>? keepActionsVisible = null)
    {
        var grid = new Grid { Margin = new Thickness(0, 16, 0, 16) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(content);
        if (actions != null)
        {
            actions.Margin = new Thickness(24, 0, 0, 0);
            actions.VerticalAlignment = VerticalAlignment.Top;
            actions.Opacity = keepActionsVisible?.Invoke() == true ? 1 : 0;
            Grid.SetColumn(actions, 1);
            grid.Children.Add(actions);
        }
        var outer = new StackPanel { Background = Brushes.Transparent };
        outer.Children.Add(grid);
        outer.Children.Add(Hairline());
        if (actions != null)
        {
            outer.MouseEnter += (_, _) => actions.Opacity = 1;
            outer.MouseLeave += (_, _) => actions.Opacity = keepActionsVisible?.Invoke() == true ? 1 : 0;
        }
        if (click != null)
        {
            outer.Cursor = Cursors.Hand;
            outer.MouseLeftButtonUp += (_, e) =>
            {
                if (e.Handled) return;
                click();
            };
        }
        return outer;
    }

    /// <summary>Scrollbereich ohne sichtbare Leiste.</summary>
    public static ScrollViewer Scroll(UIElement content) => new()
    {
        Content = content,
        VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Focusable = false,
    };

    // MARK: Bilder

    private static readonly Dictionary<string, BitmapSource?> Thumbs = [];

    /// <summary>Verkleinerte Vorschau eines gespeicherten Bildes. Die Datei bleibt dabei nicht gesperrt.</summary>
    public static BitmapSource? Thumbnail(string? imageFile, int decodeHeight = 240)
    {
        if (string.IsNullOrEmpty(imageFile)) return null;
        var key = imageFile + "@" + decodeHeight;
        if (Thumbs.TryGetValue(key, out var cached)) return cached;
        BitmapSource? result = null;
        try
        {
            var path = System.IO.Path.Combine(Storage.Images, System.IO.Path.GetFileName(imageFile));
            if (File.Exists(path))
            {
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                bmp.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
                bmp.DecodePixelHeight = decodeHeight;
                bmp.UriSource = new Uri(path);
                bmp.EndInit();
                bmp.Freeze();
                result = bmp;
            }
        }
        catch (Exception e) { Log.Write("Vorschau fehlgeschlagen: " + e.Message); }
        if (Thumbs.Count > 300) Thumbs.Clear();
        Thumbs[key] = result;
        return result;
    }

    public static Image Picture(BitmapSource source, double maxHeight)
    {
        var img = new Image
        {
            Source = source,
            MaxHeight = maxHeight,
            Stretch = Stretch.Uniform,
            StretchDirection = StretchDirection.DownOnly,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.HighQuality);
        return img;
    }
}
