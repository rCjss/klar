using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;

namespace Klar.Core;

/// <summary>Ablage für Geheimnisse (API-Schlüssel). Unter Windows die Anmeldeinformationsverwaltung.</summary>
public interface ISecretStore
{
    string Read(string account);
    void Write(string account, string value);
}

public sealed class MemorySecretStore : ISecretStore
{
    private readonly Dictionary<string, string> _values = [];
    public string Read(string account) => _values.GetValueOrDefault(account, "");
    public void Write(string account, string value)
    {
        if (value.Length == 0) _values.Remove(account); else _values[account] = value;
    }
}

public sealed class AppSettings : INotifyPropertyChanged
{
    private const string FileName = "settings.json";
    private static AppSettings? _shared;

    /// <summary>Muss vor dem ersten Zugriff auf <see cref="Shared"/> gesetzt werden.</summary>
    public static ISecretStore Secrets { get; set; } = new MemorySecretStore();

    /// <summary>Anzeigename des Benutzers für den Standard-Textbaustein.</summary>
    public static Func<string> FullUserName { get; set; } = () => Environment.UserName;

    public static AppSettings Shared => _shared ??= Load();

    internal static void ResetForTests() => _shared = null;

    private static AppSettings Load()
    {
        var s = Storage.Load<AppSettings>(FileName) ?? new AppSettings();
        s._snippets ??= [new Snippet { Trigger = "Signatur", Text = "Viele Grüße\n" + FullUserName() }];
        s._claudeApiKey = Secrets.Read("claude-api-key");
        s._giphyApiKey = Secrets.Read("giphy-api-key");
        s._loaded = true;
        return s;
    }

    private bool _loaded;
    public event PropertyChangedEventHandler? PropertyChanged;

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        Changed(name);
    }

    private void Changed(string? name)
    {
        if (!_loaded) return;
        Save();
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public void Save() => Storage.Save(this, FileName);

    private Hotkey _clipboardHotkey = Hotkey.ClipboardDefault;
    private Hotkey _dictationHotkey = Hotkey.DictationDefault;
    private Hotkey _meetingHotkey = Hotkey.MeetingDefault;
    private Hotkey _recordingHotkey = Hotkey.RecordingDefault;
    private Hotkey _awakeHotkey = Hotkey.AwakeDefault;
    private bool _awakeKeepsDisplay = true;
    private bool _awakeDuringCapture = true;
    private List<Snippet>? _snippets;
    private string _localeIdentifier = "de-DE";
    private string _commandPrefix = "einfügen";
    private int _historyLimit = 500;
    private bool _pasteAfterDictation = true;
    private bool _recordMicInScreenRecording;
    private bool _showInTaskbar = true;
    private bool _autoSummarize = true;
    private string _summaryProvider = "auto";
    private string _whisperModel = SpeechModels.Default.Id;
    private bool _didShowWindowOnce;
    private bool _lidModeArmed;
    private uint _lidSavedAc = 1, _lidSavedDc = 1;
    private string _claudeApiKey = "";
    private string _giphyApiKey = "";

    public Hotkey ClipboardHotkey { get => _clipboardHotkey; set => Set(ref _clipboardHotkey, value); }
    public Hotkey DictationHotkey { get => _dictationHotkey; set => Set(ref _dictationHotkey, value); }
    public Hotkey MeetingHotkey { get => _meetingHotkey; set => Set(ref _meetingHotkey, value); }
    public Hotkey RecordingHotkey { get => _recordingHotkey; set => Set(ref _recordingHotkey, value); }
    public Hotkey AwakeHotkey { get => _awakeHotkey; set => Set(ref _awakeHotkey, value); }
    public bool AwakeKeepsDisplay { get => _awakeKeepsDisplay; set => Set(ref _awakeKeepsDisplay, value); }
    public bool AwakeDuringCapture { get => _awakeDuringCapture; set => Set(ref _awakeDuringCapture, value); }

    public List<Snippet> Snippets
    {
        get => _snippets ??= [];
        set { _snippets = value; Changed(nameof(Snippets)); }
    }

    /// <summary>Nach dem Bearbeiten eines Bausteins aufrufen – die Liste selbst ändert sich dabei nicht.</summary>
    public void SnippetsEdited() => Changed(nameof(Snippets));

    public string LocaleIdentifier { get => _localeIdentifier; set => Set(ref _localeIdentifier, value); }
    public string CommandPrefix { get => _commandPrefix; set => Set(ref _commandPrefix, value); }
    public int HistoryLimit { get => _historyLimit; set => Set(ref _historyLimit, value); }
    public bool PasteAfterDictation { get => _pasteAfterDictation; set => Set(ref _pasteAfterDictation, value); }
    public bool RecordMicInScreenRecording { get => _recordMicInScreenRecording; set => Set(ref _recordMicInScreenRecording, value); }
    public bool ShowInTaskbar { get => _showInTaskbar; set => Set(ref _showInTaskbar, value); }
    public bool AutoSummarize { get => _autoSummarize; set => Set(ref _autoSummarize, value); }
    public string SummaryProvider { get => _summaryProvider; set => Set(ref _summaryProvider, value); }
    public string WhisperModel { get => _whisperModel; set => Set(ref _whisperModel, value); }
    public bool DidShowWindowOnce { get => _didShowWindowOnce; set => Set(ref _didShowWindowOnce, value); }
    public bool LidModeArmed { get => _lidModeArmed; set => Set(ref _lidModeArmed, value); }
    public uint LidSavedAc { get => _lidSavedAc; set => Set(ref _lidSavedAc, value); }
    public uint LidSavedDc { get => _lidSavedDc; set => Set(ref _lidSavedDc, value); }

    [JsonIgnore]
    public string ClaudeApiKey
    {
        get => _claudeApiKey;
        set
        {
            var v = value.Trim();
            if (v == _claudeApiKey) return;
            _claudeApiKey = v;
            Secrets.Write("claude-api-key", v);
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ClaudeApiKey)));
        }
    }

    [JsonIgnore]
    public string GiphyApiKey
    {
        get => _giphyApiKey;
        set
        {
            var v = value.Trim();
            if (v == _giphyApiKey) return;
            _giphyApiKey = v;
            Secrets.Write("giphy-api-key", v);
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(GiphyApiKey)));
        }
    }

    /// <summary>Sprachcode für die Erkennung, z. B. „de“ aus „de-DE“.</summary>
    [JsonIgnore]
    public string LanguageCode => LocaleIdentifier.Split('-')[0].ToLowerInvariant();
}
