using System.Drawing;
using System.Drawing.Drawing2D;
using Klar.Core;
using WinForms = System.Windows.Forms;

namespace Klar;

/// <summary>Symbol im Infobereich der Taskleiste mit dem Menü der App.</summary>
internal sealed class TrayIcon : IDisposable
{
    private enum Glyph { Idle, Recording, Dictation, Meeting, Awake }

    private readonly WinForms.NotifyIcon _icon;
    private readonly WinForms.ContextMenuStrip _menu;
    private readonly App _app;
    private Icon? _current;
    private (Glyph, bool)? _shown;

    public TrayIcon(App app)
    {
        _app = app;
        _menu = new WinForms.ContextMenuStrip { ShowImageMargin = false };
        // WinForms bricht das Öffnen eines noch leeren Menüs ab – deshalb vorab füllen und Cancel zurücknehmen.
        _menu.Opening += (_, e) => { BuildMenu(); e.Cancel = false; };
        _icon = new WinForms.NotifyIcon { Text = "Klar", ContextMenuStrip = _menu, Visible = true };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == WinForms.MouseButtons.Left) _app.ShowMainWindow();
        };
        Theme.Changed += Refresh;
        Refresh();
        BuildMenu();
    }

    public void Refresh()
    {
        Glyph glyph;
        if (ScreenRecorder.Shared.IsRecording) glyph = Glyph.Recording;
        else if (DictationEngine.Shared.IsListening) glyph = Glyph.Dictation;
        else if (MeetingRecorder.Shared.IsRunning) glyph = Glyph.Meeting;
        else if (AwakeManager.Shared.IsActive) glyph = Glyph.Awake;
        else glyph = Glyph.Idle;
        var dark = Theme.TaskbarIsDark;
        if (_shown == (glyph, dark)) return;
        _shown = (glyph, dark);

        var next = Draw(glyph, dark ? Color.White : Color.Black);
        _icon.Icon = next;
        if (_current != null)
        {
            Native.DestroyIcon(_current.Handle);
            _current.Dispose();
        }
        _current = next;
        _icon.Text = glyph switch
        {
            Glyph.Recording => "Klar – Aufnahme läuft",
            Glyph.Dictation => "Klar – Diktat läuft",
            Glyph.Meeting => "Klar – Meeting wird transkribiert",
            Glyph.Awake => "Klar – hält den PC wach",
            _ => "Klar",
        };
    }

    /// <summary>Zeichnet das Symbol: Kreis im Ruhezustand, sonst ein Zeichen für die laufende Funktion.</summary>
    private static Icon Draw(Glyph glyph, Color color)
    {
        const int s = 32;
        using var bmp = new Bitmap(s, s, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var pen = new Pen(color, 3f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            using var brush = new SolidBrush(color);
            switch (glyph)
            {
                case Glyph.Idle:
                    g.DrawEllipse(pen, 5, 5, 22, 22);
                    break;
                case Glyph.Recording:
                    g.DrawEllipse(pen, 4, 4, 24, 24);
                    g.FillEllipse(brush, 10, 10, 12, 12);
                    break;
                case Glyph.Dictation:
                    float[] heights = [8, 18, 26, 14, 8];
                    for (var i = 0; i < heights.Length; i++)
                    {
                        var x = 5 + i * 5.5f;
                        g.DrawLine(pen, x, 16 - heights[i] / 2, x, 16 + heights[i] / 2);
                    }
                    break;
                case Glyph.Meeting:
                    g.DrawEllipse(pen, 3, 3, 26, 26);
                    using (var thin = new Pen(color, 2.4f) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                    {
                        float[] bars = [6, 12, 6];
                        for (var i = 0; i < bars.Length; i++)
                        {
                            var x = 11 + i * 5f;
                            g.DrawLine(thin, x, 16 - bars[i] / 2, x, 16 + bars[i] / 2);
                        }
                    }
                    break;
                case Glyph.Awake:
                    g.DrawEllipse(pen, 10, 10, 12, 12);
                    using (var ray = new Pen(color, 2.4f) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                    {
                        for (var i = 0; i < 8; i++)
                        {
                            var a = i * Math.PI / 4;
                            g.DrawLine(ray,
                                16 + (float)(Math.Cos(a) * 10.5), 16 + (float)(Math.Sin(a) * 10.5),
                                16 + (float)(Math.Cos(a) * 14), 16 + (float)(Math.Sin(a) * 14));
                        }
                    }
                    break;
            }
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    /// <summary>Menüfarben in Schwarz-Weiß, passend zum hellen oder dunklen Modus.</summary>
    private sealed class MenuColors(bool dark) : WinForms.ProfessionalColorTable
    {
        private readonly Color _paper = dark ? Color.FromArgb(24, 24, 24) : Color.White;
        private readonly Color _hover = dark ? Color.FromArgb(52, 52, 52) : Color.FromArgb(238, 238, 238);
        private readonly Color _line = dark ? Color.FromArgb(64, 64, 64) : Color.FromArgb(222, 222, 222);

        public override Color ToolStripDropDownBackground => _paper;
        public override Color ImageMarginGradientBegin => _paper;
        public override Color ImageMarginGradientMiddle => _paper;
        public override Color ImageMarginGradientEnd => _paper;
        public override Color MenuBorder => _line;
        public override Color MenuItemBorder => _hover;
        public override Color MenuItemSelected => _hover;
        public override Color MenuItemSelectedGradientBegin => _hover;
        public override Color MenuItemSelectedGradientEnd => _hover;
        public override Color MenuItemPressedGradientBegin => _hover;
        public override Color MenuItemPressedGradientEnd => _hover;
        public override Color SeparatorDark => _line;
        public override Color SeparatorLight => _line;
    }

    private static void Style(WinForms.ToolStripItemCollection items, Color ink)
    {
        foreach (WinForms.ToolStripItem item in items)
        {
            item.ForeColor = ink;
            if (item is WinForms.ToolStripMenuItem { HasDropDownItems: true } parent)
            {
                if (parent.DropDown is WinForms.ToolStripDropDownMenu sub) sub.ShowImageMargin = false;
                Style(parent.DropDownItems, ink);
            }
        }
    }

    private void BuildMenu()
    {
        var settings = AppSettings.Shared;
        var items = _menu.Items;
        items.Clear();
        var dark = Theme.IsDark;
        _menu.Renderer = new WinForms.ToolStripProfessionalRenderer(new MenuColors(dark)) { RoundedEdges = false };

        WinForms.ToolStripMenuItem Item(string title, Action action, string? shortcut = null)
        {
            var item = new WinForms.ToolStripMenuItem(title) { ShortcutKeyDisplayString = shortcut };
            item.Click += (_, _) => action();
            return item;
        }

        items.Add(Item("Zwischenablage", _app.ToggleClipboardPanel, settings.ClipboardHotkey.Display));
        items.Add(Item(DictationEngine.Shared.IsListening ? "Diktat beenden" : "Diktat starten",
            DictationEngine.Shared.Toggle, settings.DictationHotkey.Display));
        items.Add(Item(MeetingRecorder.Shared.IsRunning ? "Meeting-Transkription beenden" : "Meeting transkribieren", () =>
        {
            MeetingRecorder.Shared.Toggle();
            _app.ShowMainWindow(Section.Meetings);
        }, settings.MeetingHotkey.Display));
        items.Add(Item(ScreenRecorder.Shared.IsRecording ? "Aufnahme beenden" : "Bildschirm aufnehmen",
            ScreenRecorder.Shared.Toggle, settings.RecordingHotkey.Display));
        items.Add(new WinForms.ToolStripSeparator());

        var awake = AwakeManager.Shared;
        var awakeItem = new WinForms.ToolStripMenuItem(awake.MenuTitle) { ShortcutKeyDisplayString = settings.AwakeHotkey.Display };
        if (awake.IsActive)
        {
            awakeItem.DropDownItems.Add(Item("Beenden", awake.Stop));
            awakeItem.DropDownItems.Add(new WinForms.ToolStripSeparator());
        }
        awakeItem.DropDownItems.Add(Item("Unbegrenzt", () => awake.Start(null)));
        foreach (var (label, seconds) in AwakeManager.Durations)
        {
            var s = seconds;
            awakeItem.DropDownItems.Add(Item(label, () => awake.Start(s)));
        }
        items.Add(awakeItem);
        items.Add(new WinForms.ToolStripSeparator());
        items.Add(Item("Klar öffnen", () => _app.ShowMainWindow()));
        items.Add(Item("Einstellungen", () => _app.ShowMainWindow(Section.Settings)));
        items.Add(new WinForms.ToolStripSeparator());
        items.Add(Item("Beenden", _app.Quit));
        Style(items, dark ? Color.White : Color.Black);
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
        _menu.Dispose();
        if (_current != null)
        {
            Native.DestroyIcon(_current.Handle);
            _current.Dispose();
        }
    }
}
