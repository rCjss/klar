using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace Klar;

/// <summary>Schwarz auf Weiß im hellen Modus, Weiß auf Schwarz im dunklen. Keine weiteren Farben.</summary>
internal static class Theme
{
    public static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI");

    public static bool IsDark { get; private set; }
    public static Color Paper => IsDark ? Colors.Black : Colors.White;
    public static Color Ink => IsDark ? Colors.White : Colors.Black;
    public static event Action? Changed;

    private const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    private static bool ReadLight(string name)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
            return key?.GetValue(name) is not int v || v != 0;
        }
        catch { return true; }
    }

    /// <summary>Die Taskleiste kann dunkel sein, während Apps hell sind.</summary>
    public static bool TaskbarIsDark => !ReadLight("SystemUsesLightTheme");

    public static void Start()
    {
        Apply();
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color or UserPreferenceCategory.VisualStyle)
                Application.Current?.Dispatcher.BeginInvoke(Apply);
        };
    }

    public static void Apply()
    {
        IsDark = !ReadLight("AppsUseLightTheme");
        var r = Application.Current.Resources;
        r["Paper"] = Solid(Paper, 1);
        r["Ink"] = Solid(Ink, 1);
        r["Muted"] = Solid(Ink, 0.42);
        r["Faint"] = Solid(Ink, 0.18);
        r["Line"] = Solid(Ink, 0.08);
        r["Hover"] = Solid(Ink, 0.04);
        Changed?.Invoke();
    }

    public static SolidColorBrush Solid(Color color, double opacity)
    {
        var b = new SolidColorBrush(Color.FromArgb((byte)Math.Round(opacity * 255), color.R, color.G, color.B));
        b.Freeze();
        return b;
    }

    /// <summary>Für Flächen in Tintenfarbe (ausgewählte Zeile, Diktat-Kapsel): Schrift in Papierfarbe.</summary>
    public static SolidColorBrush OnInk(double opacity = 1) => Solid(Paper, opacity);
    public static SolidColorBrush InkBrush(double opacity = 1) => Solid(Ink, opacity);

    /// <summary>Färbt die Titelleiste passend ein (Windows 11; unter Windows 10 nur Hell/Dunkel).</summary>
    public static void StyleTitleBar(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;
        var dark = IsDark ? 1 : 0;
        Native.DwmSetWindowAttribute(hwnd, Native.DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));
        var caption = IsDark ? 0x00000000 : 0x00FFFFFF; // COLORREF 0x00BBGGRR
        Native.DwmSetWindowAttribute(hwnd, Native.DWMWA_CAPTION_COLOR, ref caption, sizeof(int));
        var text = IsDark ? 0x00FFFFFF : 0x00000000;
        Native.DwmSetWindowAttribute(hwnd, Native.DWMWA_TEXT_COLOR, ref text, sizeof(int));
    }
}
