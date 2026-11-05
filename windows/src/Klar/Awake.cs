using System.Runtime.InteropServices;
using System.Windows.Threading;
using Klar.Core;

namespace Klar;

/// <summary>Hält PC und Bildschirm wach – für eine gewählte Dauer oder unbegrenzt.
/// Technisch über SetThreadExecutionState, so wie Videoplayer und Präsentationsprogramme.</summary>
internal sealed class AwakeManager
{
    public static AwakeManager Shared { get; } = new();

    public static readonly (string Label, double Seconds)[] Durations =
    [
        ("15 Min", 15 * 60), ("30 Min", 30 * 60), ("1 Std", 3600),
        ("2 Std", 2 * 3600), ("4 Std", 4 * 3600), ("8 Std", 8 * 3600),
    ];

    /// <summary>Manuell aktiv (per Menü, Hotkey oder Fenster).</summary>
    public bool IsActive { get; private set; }
    /// <summary>Endzeitpunkt (UTC); null = unbegrenzt.</summary>
    public DateTime? Until { get; private set; }
    /// <summary>Automatisch aktiv, weil ein Meeting transkribiert oder der Bildschirm aufgenommen wird.</summary>
    public bool AutoHold { get; private set; }
    /// <summary>Deckel-Modus: Der PC läuft auch zugeklappt weiter.</summary>
    public bool LidMode { get; private set; }
    public string? LidError { get; private set; }
    public bool IsHolding => IsActive || AutoHold;

    /// <summary>Zustand oder Restzeit hat sich geändert (tickt jede Sekunde, solange eine Dauer läuft).</summary>
    public event Action? Changed;

    private readonly DispatcherTimer _ticker;

    private AwakeManager()
    {
        _ticker = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _ticker.Tick += (_, _) =>
        {
            if (IsActive && Until is { } end && DateTime.UtcNow >= end) Stop();
            else Changed?.Invoke();
        };
        // Wurde Klar mit aktivem Deckel-Modus abgewürgt, steht die Energieoption noch auf „Nichts unternehmen“.
        // Beim nächsten Start den gemerkten Wert wieder einsetzen – sonst liefe ein zugeklapptes Notebook
        // unbemerkt weiter, obwohl Klar „Der PC darf schlafen“ anzeigt.
        var settings = AppSettings.Shared;
        if (settings.LidModeArmed)
        {
            if (ReadLidAction() is not { Ac: 0, Dc: 0 } || WriteLidAction(settings.LidSavedAc, settings.LidSavedDc))
                settings.LidModeArmed = false;
            else
                LidError = "Der Deckel-Modus ließ sich nach dem letzten Beenden nicht zurücksetzen. Bitte in den Windows-Energieoptionen „Beim Zuklappen“ prüfen.";
        }
    }

    /// <summary>Startet oder verlängert. <paramref name="seconds"/> null = unbegrenzt.</summary>
    public void Start(double? seconds)
    {
        IsActive = true;
        Until = seconds is { } s ? DateTime.UtcNow.AddSeconds(s) : null;
        Apply();
    }

    public void Stop()
    {
        IsActive = false;
        Until = null;
        Apply();
        if (LidMode) SetLidMode(false);
    }

    public void Toggle()
    {
        if (IsActive) Stop(); else Start(null);
    }

    /// <summary>Von Meeting-Transkription und Bildschirmaufnahme aufgerufen.</summary>
    public void SetAutoHold(bool on)
    {
        var wanted = on && AppSettings.Shared.AwakeDuringCapture;
        if (wanted == AutoHold) return;
        AutoHold = wanted;
        Apply();
    }

    /// <summary>Einstellung „Bildschirm ebenfalls wach halten“ wurde geändert.</summary>
    public void Refresh() => Apply();

    public string StatusText
    {
        get
        {
            if (IsActive)
            {
                if (Until is { } end) return $"Wach bis {Format.TimeText(end)} · noch {RemainingText(end)}";
                return LidMode ? "Wach, unbegrenzt – auch zugeklappt" : "Wach, unbegrenzt";
            }
            return AutoHold ? "Wach, solange Meeting oder Aufnahme läuft" : "Der PC darf schlafen.";
        }
    }

    public string MenuTitle => IsActive
        ? Until is { } end ? $"Cocaine bis {Format.TimeText(end)}" : "Cocaine (unbegrenzt)"
        : "Cocaine";

    private static string RemainingText(DateTime end)
    {
        var s = Math.Max(0, (int)(end - DateTime.UtcNow).TotalSeconds);
        if (s >= 3600) return $"{s / 3600} Std {s % 3600 / 60} Min";
        if (s >= 60) return $"{s / 60} Min";
        return $"{s} Sek";
    }

    private void Apply()
    {
        var hold = IsHolding;
        var display = hold && AppSettings.Shared.AwakeKeepsDisplay;
        var flags = Native.ES_CONTINUOUS;
        if (hold) flags |= Native.ES_SYSTEM_REQUIRED;
        if (display) flags |= Native.ES_DISPLAY_REQUIRED;
        // Gilt für den aufrufenden Thread – deshalb immer vom UI-Thread aus.
        if (Native.SetThreadExecutionState(flags) == 0) Log.Write("SetThreadExecutionState fehlgeschlagen");
        if (IsActive && Until != null) _ticker.Start(); else _ticker.Stop();
        Changed?.Invoke();
    }

    // MARK: Deckel-Modus

    /// <summary>Aktion beim Zuklappen im aktiven Energieplan: 0 = nichts, 1 = Energie sparen, 2 = Ruhezustand, 3 = Herunterfahren.</summary>
    private static (uint Ac, uint Dc)? ReadLidAction()
    {
        try
        {
            if (Native.PowerGetActiveScheme(IntPtr.Zero, out var ptr) != 0) return null;
            try
            {
                var scheme = Marshal.PtrToStructure<Guid>(ptr);
                if (Native.PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref Native.SubGroupButtons, ref Native.LidAction, out var ac) != 0) return null;
                if (Native.PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref Native.SubGroupButtons, ref Native.LidAction, out var dc) != 0) return null;
                return (ac, dc);
            }
            finally { Native.LocalFree(ptr); }
        }
        catch (Exception e)
        {
            Log.Write("Energieeinstellung nicht lesbar: " + e.Message);
            return null;
        }
    }

    private static bool WriteLidAction(uint ac, uint dc)
    {
        try
        {
            if (Native.PowerGetActiveScheme(IntPtr.Zero, out var ptr) != 0) return false;
            try
            {
                var scheme = Marshal.PtrToStructure<Guid>(ptr);
                if (Native.PowerWriteACValueIndex(IntPtr.Zero, ref scheme, ref Native.SubGroupButtons, ref Native.LidAction, ac) != 0) return false;
                if (Native.PowerWriteDCValueIndex(IntPtr.Zero, ref scheme, ref Native.SubGroupButtons, ref Native.LidAction, dc) != 0) return false;
                return Native.PowerSetActiveScheme(IntPtr.Zero, ref scheme) == 0;
            }
            finally { Native.LocalFree(ptr); }
        }
        catch (Exception e)
        {
            Log.Write("Energieeinstellung nicht schreibbar: " + e.Message);
            return false;
        }
    }

    /// <summary>Schaltet den Deckel-Modus um. Ändert die Windows-Einstellung „Beim Zuklappen“ im aktiven
    /// Energieplan und merkt sich den vorherigen Wert.</summary>
    public void SetLidMode(bool on)
    {
        if (on == LidMode) return;
        LidError = null;
        var settings = AppSettings.Shared;
        if (on)
        {
            var current = ReadLidAction();
            if (current == null)
            {
                LidError = "Die Energieeinstellung „Beim Zuklappen“ lässt sich auf diesem Gerät nicht lesen.";
                Changed?.Invoke();
                return;
            }
            if (!settings.LidModeArmed)
            {
                settings.LidSavedAc = current.Value.Ac;
                settings.LidSavedDc = current.Value.Dc;
            }
            if (!WriteLidAction(0, 0))
            {
                LidError = "Deckel-Modus konnte nicht eingeschaltet werden (Energieeinstellung ist gesperrt).";
                Changed?.Invoke();
                return;
            }
            settings.LidModeArmed = true;
            LidMode = true;
            if (!IsActive) Start(null); else Changed?.Invoke();
        }
        else
        {
            if (!WriteLidAction(settings.LidSavedAc, settings.LidSavedDc))
            {
                LidError = "Deckel-Modus konnte nicht zurückgesetzt werden. Bitte in den Windows-Energieoptionen „Beim Zuklappen“ prüfen.";
                Changed?.Invoke();
                return;
            }
            settings.LidModeArmed = false;
            LidMode = false;
            Changed?.Invoke();
        }
    }

    /// <summary>Beim Beenden der App: Deckel-Modus nie aktiv zurücklassen.</summary>
    public void ReleaseOnQuit()
    {
        if (LidMode) SetLidMode(false);
        Native.SetThreadExecutionState(Native.ES_CONTINUOUS);
    }
}
