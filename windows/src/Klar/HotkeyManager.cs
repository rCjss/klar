using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Threading;
using Klar.Core;

namespace Klar;

/// <summary>Unsichtbares Fenster, das Systemnachrichten empfängt (Tastenkürzel, Zwischenablage).</summary>
internal static class MessageWindow
{
    private static HwndSource? _source;

    public static IntPtr Handle => Source.Handle;

    public static HwndSource Source
    {
        get
        {
            if (_source != null) return _source;
            _source = new HwndSource(new HwndSourceParameters("Klar.Messages")
            {
                ParentWindow = Native.HWND_MESSAGE,
                WindowStyle = 0,
                Width = 0,
                Height = 0,
            });
            return _source;
        }
    }
}

/// <summary>Globale Tastenkürzel. Kombinationen laufen über RegisterHotKey; das Loslassen (für
/// Push-to-Talk) wird über den Tastenzustand erkannt. Einzelne Modifier-Tasten laufen über einen
/// Tastatur-Hook, der nur existiert, solange ein solches Kürzel eingestellt ist.</summary>
internal sealed class HotkeyManager
{
    public static HotkeyManager Shared { get; } = new();

    private sealed class Binding
    {
        public required Hotkey Hotkey;
        public required Action OnPress;
        public Action? OnRelease, OnCancel;
        public bool Registered;
        public string? Error;
    }

    private readonly Dictionary<int, Binding> _bindings = [];
    private readonly DispatcherTimer _releaseTimer;
    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;
    private bool _installed;
    private volatile bool _paused;
    private int? _heldId;
    private IntPtr _hook;
    private Native.LowLevelKeyboardProc? _hookProc;
    private Thread? _hookThread;
    private uint _hookThreadId;
    private uint? _heldModifier;
    private bool _heldCancelled;

    /// <summary>Registrierungsstatus hat sich geändert (für die Anzeige in den Einstellungen).</summary>
    public event Action? Changed;

    private HotkeyManager()
    {
        _releaseTimer = new DispatcherTimer(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(15) };
        _releaseTimer.Tick += (_, _) => PollRelease();
    }

    private void InstallIfNeeded()
    {
        if (_installed) return;
        _installed = true;
        MessageWindow.Source.AddHook(WndProc);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != Native.WM_HOTKEY) return IntPtr.Zero;
        handled = true;
        var id = wParam.ToInt32();
        if (_paused || !_bindings.TryGetValue(id, out var b)) return IntPtr.Zero;
        Log.Write($"Hotkey {b.Hotkey.Display} gedrückt");
        b.OnPress();
        if (b.OnRelease != null)
        {
            _heldId = id;
            _releaseTimer.Start();
        }
        return IntPtr.Zero;
    }

    private void PollRelease()
    {
        if (_heldId is not { } id || !_bindings.TryGetValue(id, out var b))
        {
            _releaseTimer.Stop();
            _heldId = null;
            return;
        }
        if (Native.IsKeyDown(b.Hotkey.Key)) return;
        _releaseTimer.Stop();
        _heldId = null;
        b.OnRelease?.Invoke();
    }

    public void Set(int id, Hotkey hotkey, Action onPress, Action? onRelease = null, Action? onCancel = null)
    {
        InstallIfNeeded();
        Unregister(id);
        _bindings[id] = new Binding { Hotkey = hotkey, OnPress = onPress, OnRelease = onRelease, OnCancel = onCancel };
        if (!_paused) Register(id);
        UpdateHook();
    }

    /// <summary>Nach dem Setzen aller Kürzel aufrufen, damit Anzeigen den neuen Stand übernehmen.</summary>
    public void NotifyChanged() => Changed?.Invoke();

    /// <summary>Fehlertext, falls das Kürzel nicht registriert werden konnte.</summary>
    public string? Error(int id) => _bindings.TryGetValue(id, out var b) ? b.Error : null;

    private void Register(int id)
    {
        if (!_bindings.TryGetValue(id, out var b) || b.Hotkey.IsModifierOnly) return;
        b.Registered = Native.RegisterHotKey(MessageWindow.Handle, id, (uint)b.Hotkey.Modifiers | Native.MOD_NOREPEAT, b.Hotkey.Key);
        b.Error = b.Registered ? null : "bereits von Windows oder einer anderen App belegt";
        if (!b.Registered) Log.Write($"Hotkey {b.Hotkey.Display} konnte nicht registriert werden ({Marshal.GetLastWin32Error()})");
    }

    private void Unregister(int id)
    {
        if (_bindings.TryGetValue(id, out var b) && b.Registered)
        {
            Native.UnregisterHotKey(MessageWindow.Handle, id);
            b.Registered = false;
        }
        if (_heldId == id) { _heldId = null; _releaseTimer.Stop(); }
    }

    /// <summary>Während ein neues Kürzel aufgenommen wird, sollen die alten nicht feuern.</summary>
    public void Pause()
    {
        _paused = true;
        foreach (var id in _bindings.Keys.ToList()) Unregister(id);
        _heldModifier = null;
    }

    public void Resume()
    {
        if (!_paused) return;
        _paused = false;
        foreach (var id in _bindings.Keys.ToList()) Register(id);
    }

    public void Shutdown()
    {
        foreach (var id in _bindings.Keys.ToList()) Unregister(id);
        if (_hookThread != null) StopHook();
    }

    // MARK: Einzelne Modifier-Tasten

    public bool HookInstalled => _hook != IntPtr.Zero;

    private void UpdateHook()
    {
        var needed = _bindings.Values.Any(b => b.Hotkey.IsModifierOnly);
        if (needed && _hookThread == null) StartHook();
        else if (!needed && _hookThread != null) StopHook();
    }

    /// <summary>Der Hook läuft auf einem eigenen Thread mit eigener Nachrichtenschleife. Windows entfernt
    /// einen Tastatur-Hook stillschweigend, wenn sein Thread zu lange nicht antwortet – auf dem UI-Thread
    /// könnte das schon ein langsamer Zugriff auf die Zwischenablage auslösen. Zudem würde dort jede
    /// Verzögerung das Tippen im ganzen System bremsen.</summary>
    private void StartHook()
    {
        var ready = new ManualResetEventSlim(false);
        var thread = new Thread(() =>
        {
            _hookThreadId = Native.GetCurrentThreadId();
            _hookProc = HookProc; // Referenz halten, sonst räumt die Laufzeit den Rückruf weg
            _hook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _hookProc, Native.GetModuleHandle(null), 0);
            var error = Marshal.GetLastWin32Error();
            ready.Set();
            if (_hook == IntPtr.Zero)
            {
                Log.Write("Tastatur-Hook konnte nicht installiert werden (" + error + ")");
                return;
            }
            while (Native.GetMessage(out _, IntPtr.Zero, 0, 0) > 0) { }
            Native.UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        })
        { IsBackground = true, Name = "Klar.KeyboardHook" };
        _hookThread = thread;
        thread.Start();
        ready.Wait(3000);
    }

    private void StopHook()
    {
        if (_hookThreadId != 0) Native.PostThreadMessage(_hookThreadId, Native.WM_QUIT, IntPtr.Zero, IntPtr.Zero);
        _hookThread = null;
        _hookThreadId = 0;
        _heldModifier = null;
    }

    /// <summary>Läuft auf dem Hook-Thread und kehrt sofort zurück; die eigentliche Arbeit macht der UI-Thread.</summary>
    private IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && !_paused)
        {
            var data = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
            // Eigene, simulierte Eingaben (Strg+V) ignorieren; ebenso das künstliche linke Strg von AltGr.
            if ((data.Flags & Native.LLKHF_INJECTED) == 0 && data.ScanCode != 0x21D)
            {
                var message = wParam.ToInt32();
                var down = message is Native.WM_KEYDOWN or Native.WM_SYSKEYDOWN;
                var vk = data.VkCode;
                _dispatcher.BeginInvoke(() => HandleModifierEvent(vk, down), DispatcherPriority.Input);
            }
        }
        return Native.CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    private Binding? ModifierBinding(uint vk) => _bindings.Values.FirstOrDefault(b => b.Hotkey.IsModifierOnly && b.Hotkey.Key == vk);

    private void HandleModifierEvent(uint vk, bool down)
    {
        if (_paused) return;
        if (down)
        {
            if (_heldModifier is { } held)
            {
                if (held == vk) return; // Tastenwiederholung
                // Eine andere Taste während des Haltens: das war ein Shortcut, kein Auslöser.
                // Das Loslassen wird trotzdem noch gemeldet, damit ein laufendes Push-to-Talk endet.
                if (!_heldCancelled)
                {
                    _heldCancelled = true;
                    ModifierBinding(held)?.OnCancel?.Invoke();
                }
                return;
            }
            if (ModifierBinding(vk) is { } b)
            {
                _heldModifier = vk;
                _heldCancelled = false;
                b.OnPress();
            }
        }
        else if (_heldModifier == vk)
        {
            _heldModifier = null;
            ModifierBinding(vk)?.OnRelease?.Invoke();
        }
    }
}

internal static class HotkeyId
{
    public const int Clipboard = 1, Dictation = 2, Meeting = 3, Recording = 4, Awake = 5;
}
