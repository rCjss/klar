using System.ComponentModel;
using System.Windows;
using System.Windows.Threading;
using Klar.Core;

namespace Klar;

public partial class App : Application
{
    private const string InstanceName = @"Local\de.felixsiebrasse.klar";

    private Mutex? _mutex;
    private EventWaitHandle? _showSignal;
    private TrayIcon? _tray;
    private ClipboardPanel? _panel;
    private MainWindow? _window;
    private bool _quitting;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // „Klar.exe --selftest [Berichtsdatei]“ prüft alle Fenster und Systemfunktionen und beendet sich.
        var selfTest = Array.IndexOf(e.Args, "--selftest");
        if (selfTest >= 0)
        {
            var report = selfTest + 1 < e.Args.Length ? e.Args[selfTest + 1] : Path.Combine(Path.GetTempPath(), "klar-selftest.txt");
            _ = RunSelfTestAsync(report);
            return;
        }

        // Nur eine Instanz: Ein zweiter Start holt das Fenster der laufenden nach vorn.
        _mutex = new Mutex(true, InstanceName + ".mutex", out var first);
        _showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, InstanceName + ".show");
        if (!first)
        {
            _showSignal.Set();
            Shutdown();
            return;
        }

        DispatcherUnhandledException += (_, args) =>
        {
            Log.Write("Unbehandelter Fehler: " + args.Exception);
            args.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, args) => Log.Write("Schwerer Fehler: " + args.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Log.Write("Unbeobachteter Fehler: " + args.Exception);
            args.SetObserved();
        };

        UiThread.Post = action => Dispatcher.BeginInvoke(action);
        AppSettings.Secrets = new CredentialStore();
        AppSettings.FullUserName = Native.FullUserName;
        KeyNames.LayoutResolver = vk =>
        {
            var c = Native.MapVirtualKeyW(vk, 2 /* MAPVK_VK_TO_CHAR */) & 0x7FFF;
            return c > 32 ? ((char)c).ToString() : null;
        };

        var settings = AppSettings.Shared;
        Theme.Start();
        _panel = new ClipboardPanel();
        ClipboardMonitor.Shared.Start();
        _tray = new TrayIcon(this);
        RegisterHotkeys();
        settings.PropertyChanged += OnSettingChanged;

        DictationEngine.Shared.Changed += RefreshStatus;
        MeetingRecorder.Shared.Changed += RefreshStatus;
        ScreenRecorder.Shared.Changed += RefreshStatus;
        AwakeManager.Shared.Changed += RefreshStatus;
        RefreshStatus();

        var signal = _showSignal;
        var listener = new Thread(() =>
        {
            try
            {
                while (signal.WaitOne())
                    Dispatcher.BeginInvoke(() => { if (!_quitting) ShowMainWindow(); });
            }
            catch (ObjectDisposedException) { }
        })
        { IsBackground = true, Name = "Klar.Show" };
        listener.Start();

        var hidden = e.Args.Contains("--hidden");
        if (!settings.DidShowWindowOnce)
        {
            settings.DidShowWindowOnce = true;
            ShowMainWindow(Section.Settings);
        }
        else if (!hidden) ShowMainWindow();
    }

    private async Task RunSelfTestAsync(string report)
    {
        var code = 1;
        try { code = await new SelfTest(this).RunAsync(report); }
        catch (Exception ex)
        {
            try { File.AppendAllText(report, "ABBRUCH: " + ex + Environment.NewLine); } catch { }
        }
        Shutdown(code);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_tray != null)
        {
            ScreenRecorder.Shared.StopOnQuit();
            MeetingRecorder.Shared.FinishOnQuit();
            AwakeManager.Shared.ReleaseOnQuit();
            ClipboardMonitor.Shared.Stop();
            HotkeyManager.Shared.Shutdown();
            Debouncer.FlushAll();
            _tray.Dispose();
        }
        _showSignal?.Dispose();
        try { _mutex?.ReleaseMutex(); } catch { }
        _mutex?.Dispose();
        base.OnExit(e);
    }

    internal void Quit()
    {
        _quitting = true;
        Shutdown();
    }

    // MARK: Status

    private void RefreshStatus()
    {
        // Meeting und Aufnahme halten den PC automatisch wach.
        AwakeManager.Shared.SetAutoHold(MeetingRecorder.Shared.IsRunning || ScreenRecorder.Shared.IsRecording);
        _tray?.Refresh();
    }

    // MARK: Hotkeys

    private void RegisterHotkeys()
    {
        var settings = AppSettings.Shared;
        var hk = HotkeyManager.Shared;
        hk.Set(HotkeyId.Clipboard, settings.ClipboardHotkey, ToggleClipboardPanel);
        hk.Set(HotkeyId.Dictation, settings.DictationHotkey,
            DictationEngine.Shared.HotkeyPressed,
            DictationEngine.Shared.HotkeyReleased,
            DictationEngine.Shared.HotkeyCancelled);
        hk.Set(HotkeyId.Meeting, settings.MeetingHotkey, MeetingRecorder.Shared.Toggle);
        hk.Set(HotkeyId.Recording, settings.RecordingHotkey, ScreenRecorder.Shared.Toggle);
        hk.Set(HotkeyId.Awake, settings.AwakeHotkey, AwakeManager.Shared.Toggle);
        hk.NotifyChanged();
    }

    private void OnSettingChanged(object? sender, PropertyChangedEventArgs e)
    {
        var settings = AppSettings.Shared;
        switch (e.PropertyName)
        {
            case nameof(AppSettings.ClipboardHotkey):
            case nameof(AppSettings.DictationHotkey):
            case nameof(AppSettings.MeetingHotkey):
            case nameof(AppSettings.RecordingHotkey):
            case nameof(AppSettings.AwakeHotkey):
                RegisterHotkeys();
                break;
            case nameof(AppSettings.AwakeKeepsDisplay):
                AwakeManager.Shared.Refresh();
                break;
            case nameof(AppSettings.AwakeDuringCapture):
                RefreshStatus();
                break;
            case nameof(AppSettings.ShowInTaskbar):
                if (_window != null) _window.ShowInTaskbar = settings.ShowInTaskbar;
                break;
        }
    }

    // MARK: Fenster

    internal void ToggleClipboardPanel() => _panel?.Toggle();

    internal void ShowMainWindow(Section? section = null)
    {
        _window ??= new MainWindow();
        _window.Present(section);
    }
}
