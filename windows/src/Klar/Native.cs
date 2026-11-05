using System.Runtime.InteropServices;
using System.Text;

namespace Klar;

/// <summary>Win32-Schnittstellen, die WPF nicht selbst anbietet.</summary>
internal static class Native
{
    // MARK: Fenster und Nachrichten

    public const int WM_HOTKEY = 0x0312, WM_CLIPBOARDUPDATE = 0x031D;
    public const int WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000;
    public const uint SWP_NOSIZE = 0x1, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10;
    public static readonly IntPtr HWND_MESSAGE = new(-3);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public const uint MOD_NOREPEAT = 0x4000;

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    public static bool IsKeyDown(uint vk) => (GetAsyncKeyState((int)vk) & 0x8000) != 0;

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

    public static string ClassName(IntPtr hWnd)
    {
        var sb = new StringBuilder(256);
        return GetClassName(hWnd, sb, sb.Capacity) > 0 ? sb.ToString() : "";
    }

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr value);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromPoint(POINT point, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO
    {
        public int Size;
        public RECT Monitor, Work;
        public uint Flags;
    }

    [DllImport("user32.dll")]
    public static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKeyW(uint code, uint mapType);

    // MARK: Zwischenablage

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool AddClipboardFormatListener(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool RemoveClipboardFormatListener(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();

    [DllImport("user32.dll")]
    public static extern IntPtr GetClipboardOwner();

    // MARK: Tastatur-Hook und Eingabe

    public const int WH_KEYBOARD_LL = 13;
    public const uint LLKHF_INJECTED = 0x10;

    public delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT
    {
        public uint VkCode, ScanCode, Flags, Time;
        public IntPtr ExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc proc, IntPtr module, uint threadId);

    [DllImport("user32.dll")]
    public static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetModuleHandle(string? moduleName);

    public const uint WM_QUIT = 0x0012;

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG
    {
        public IntPtr Hwnd;
        public uint Message;
        public IntPtr WParam, LParam;
        public uint Time;
        public POINT Point;
        public uint Private;
    }

    [DllImport("user32.dll")]
    public static extern int GetMessage(out MSG msg, IntPtr hWnd, uint filterMin, uint filterMax);

    [DllImport("user32.dll")]
    public static extern bool PostThreadMessage(uint threadId, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint attach, uint attachTo, bool on);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    /// <summary>Holt ein eigenes Fenster sicher in den Vordergrund. Windows erlaubt das nur dem Prozess,
    /// der gerade Eingaben erhält – über einen globalen Hotkey ist das gegeben, über den Tastatur-Hook,
    /// das Infobereich-Symbol oder einen zweiten Programmstart nicht. Dann hilft das kurze Koppeln
    /// an den Eingabe-Thread des aktiven Fensters.</summary>
    public static void ForceForeground(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || GetForegroundWindow() == hwnd) return;
        if (SetForegroundWindow(hwnd) && GetForegroundWindow() == hwnd) return;
        var foreground = GetForegroundWindow();
        var other = foreground == IntPtr.Zero ? 0 : GetWindowThreadProcessId(foreground, out _);
        var self = GetCurrentThreadId();
        if (other == 0 || other == self) return;
        AttachThreadInput(self, other, true);
        try
        {
            BringWindowToTop(hwnd);
            SetForegroundWindow(hwnd);
        }
        finally { AttachThreadInput(self, other, false); }
    }

    public const uint INPUT_KEYBOARD = 1, KEYEVENTF_KEYUP = 0x2;
    public const ushort VK_CONTROL = 0x11, VK_SHIFT = 0x10, VK_MENU = 0x12, VK_LWIN = 0x5B, VK_RWIN = 0x5C, VK_V = 0x56;

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int Dx, Dy;
        public uint MouseData, Flags, Time;
        public IntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort Vk, Scan;
        public uint Flags, Time;
        public IntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT Mouse;
        [FieldOffset(0)] public KEYBDINPUT Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint Type;
        public InputUnion U;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint count, INPUT[] inputs, int size);

    public static INPUT Key(ushort vk, bool up) => new()
    {
        Type = INPUT_KEYBOARD,
        U = new InputUnion { Keyboard = new KEYBDINPUT { Vk = vk, Flags = up ? KEYEVENTF_KEYUP : 0 } },
    };

    // MARK: Energie

    public const uint ES_CONTINUOUS = 0x80000000, ES_SYSTEM_REQUIRED = 0x1, ES_DISPLAY_REQUIRED = 0x2;

    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint flags);

    public static Guid SubGroupButtons = new("4f971e89-eebd-4455-a8de-9e59040e7347");
    public static Guid LidAction = new("5ca83367-6e45-459f-a27b-476b1d01c936");

    [DllImport("powrprof.dll")]
    public static extern uint PowerGetActiveScheme(IntPtr userRootPowerKey, out IntPtr activePolicyGuid);

    [DllImport("powrprof.dll")]
    public static extern uint PowerReadACValueIndex(IntPtr rootPowerKey, ref Guid scheme, ref Guid subGroup, ref Guid setting, out uint value);

    [DllImport("powrprof.dll")]
    public static extern uint PowerReadDCValueIndex(IntPtr rootPowerKey, ref Guid scheme, ref Guid subGroup, ref Guid setting, out uint value);

    [DllImport("powrprof.dll")]
    public static extern uint PowerWriteACValueIndex(IntPtr rootPowerKey, ref Guid scheme, ref Guid subGroup, ref Guid setting, uint value);

    [DllImport("powrprof.dll")]
    public static extern uint PowerWriteDCValueIndex(IntPtr rootPowerKey, ref Guid scheme, ref Guid subGroup, ref Guid setting, uint value);

    [DllImport("powrprof.dll")]
    public static extern uint PowerSetActiveScheme(IntPtr userRootPowerKey, ref Guid scheme);

    [DllImport("kernel32.dll")]
    public static extern IntPtr LocalFree(IntPtr mem);

    // MARK: Darstellung

    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20, DWMWA_CAPTION_COLOR = 35, DWMWA_TEXT_COLOR = 36;

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr icon);

    // MARK: Anmeldeinformationen

    public const uint CRED_TYPE_GENERIC = 1, CRED_PERSIST_LOCAL_MACHINE = 2;

    [StructLayout(LayoutKind.Sequential)]
    public struct CREDENTIAL
    {
        public uint Flags, Type;
        public IntPtr TargetName, Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes, TargetAlias, UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    public static extern void CredFree(IntPtr buffer);

    [DllImport("secur32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.U1)]
    private static extern bool GetUserNameExW(int nameFormat, StringBuilder name, ref uint size);

    /// <summary>Anzeigename des angemeldeten Benutzers („Vorname Nachname“), sonst der Anmeldename.</summary>
    public static string FullUserName()
    {
        try
        {
            uint size = 256;
            var sb = new StringBuilder((int)size);
            if (GetUserNameExW(3 /* NameDisplay */, sb, ref size) && sb.Length > 0) return sb.ToString();
        }
        catch { }
        return Environment.UserName;
    }
}
