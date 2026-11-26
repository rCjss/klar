namespace Klar.Core;

public sealed class ClipboardStore
{
    private static ClipboardStore? _shared;
    public static ClipboardStore Shared => _shared ??= new ClipboardStore(() => AppSettings.Shared.HistoryLimit);

    private const string FileName = "clipboard.json";
    private readonly Debouncer _debouncer = new();
    private readonly Func<int> _historyLimit;
    private List<ClipItem> _items;

    public event Action? Changed;

    public ClipboardStore(Func<int> historyLimit)
    {
        _historyLimit = historyLimit;
        _items = Storage.Load<List<ClipItem>>(FileName) ?? [];
    }

    public IReadOnlyList<ClipItem> Items => _items;

    /// <summary>Angepinnte zuerst, dann nach Reihenfolge (zuletzt kopiert oben).</summary>
    public List<ClipItem> Ordered
    {
        get
        {
            // Stabile Sortierung: Die Listenreihenfolge ist bereits „zuletzt benutzt zuerst“.
            var pinned = _items.Where(i => i.Pinned);
            var rest = _items.Where(i => !i.Pinned);
            return [.. pinned, .. rest];
        }
    }

    /// <summary>Rückt einen vorhandenen Eintrag wie frisch kopiert an den Anfang.</summary>
    public void Touch(Guid id)
    {
        var idx = _items.FindIndex(i => i.Id == id);
        if (idx <= 0) return;
        var item = _items[idx];
        _items.RemoveAt(idx);
        _items.Insert(0, item);
        Persist();
    }

    public void Add(ClipItem item)
    {
        if (item.Kind == ClipKind.Text && item.Text is { } text)
        {
            var existing = _items.FirstOrDefault(i => i.Kind == ClipKind.Text && i.Text == text);
            if (existing != null)
            {
                item.Id = existing.Id;
                item.Pinned = existing.Pinned;
                _items.Remove(existing);
            }
        }
        else if (item.Kind == ClipKind.Files && item.Files is { } files
                 && _items.FirstOrDefault() is { Kind: ClipKind.Files, Files: { } latest } top && latest.SequenceEqual(files))
        {
            // Dieselben Dateien direkt noch einmal kopiert: kein zweiter Eintrag.
            item.Id = top.Id;
            item.Pinned = top.Pinned;
            _items.Remove(top);
        }
        _items.Insert(0, item);
        Trim();
        Persist();
    }

    public void TogglePin(Guid id)
    {
        var item = _items.FirstOrDefault(i => i.Id == id);
        if (item == null) return;
        item.Pinned = !item.Pinned;
        Persist();
    }

    public void Remove(Guid id)
    {
        var item = _items.FirstOrDefault(i => i.Id == id);
        if (item == null) return;
        DeleteImage(item);
        _items.Remove(item);
        Persist();
    }

    public void ClearUnpinned()
    {
        foreach (var item in _items.Where(i => !i.Pinned)) DeleteImage(item);
        _items.RemoveAll(i => !i.Pinned);
        Persist();
    }

    private void Trim()
    {
        var limit = Math.Max(20, _historyLimit());
        var count = 0;
        var keep = new List<ClipItem>(_items.Count);
        foreach (var item in _items)
        {
            if (item.Pinned) { keep.Add(item); continue; }
            if (count < limit) { keep.Add(item); count++; }
            else DeleteImage(item);
        }
        _items = keep;
    }

    private static void DeleteImage(ClipItem item)
    {
        if (item.ImageFile is not { Length: > 0 } file) return;
        try { File.Delete(Path.Combine(Storage.Images, Path.GetFileName(file))); } catch { }
    }

    private void Persist()
    {
        Changed?.Invoke();
        _debouncer.Call(() => Storage.Save(_items, FileName));
    }
}

public sealed class DictationStore
{
    private static DictationStore? _shared;
    public static DictationStore Shared => _shared ??= new DictationStore();

    private const string FileName = "dictations.json";
    private readonly Debouncer _debouncer = new();
    private List<Dictation> _items;

    public event Action? Changed;

    public DictationStore() => _items = Storage.Load<List<Dictation>>(FileName) ?? [];

    public IReadOnlyList<Dictation> Items => _items;

    public void Add(Dictation d)
    {
        _items.Insert(0, d);
        if (_items.Count > 1000) _items.RemoveRange(1000, _items.Count - 1000);
        Persist();
    }

    public void Remove(Guid id)
    {
        _items.RemoveAll(i => i.Id == id);
        Persist();
    }

    private void Persist()
    {
        Changed?.Invoke();
        _debouncer.Call(() => Storage.Save(_items, FileName));
    }
}

public sealed class MeetingStore
{
    private static MeetingStore? _shared;
    public static MeetingStore Shared => _shared ??= new MeetingStore();

    private const string FileName = "meetings.json";
    private readonly Debouncer _debouncer = new(1.0);
    private readonly List<MeetingTranscript> _items;

    public event Action? Changed;

    public MeetingStore() => _items = Storage.Load<List<MeetingTranscript>>(FileName) ?? [];

    public IReadOnlyList<MeetingTranscript> Items => _items;

    public MeetingTranscript? Find(Guid id) => _items.FirstOrDefault(i => i.Id == id);

    public void Upsert(MeetingTranscript m)
    {
        var i = _items.FindIndex(x => x.Id == m.Id);
        if (i >= 0) _items[i] = m; else _items.Insert(0, m);
        Persist();
    }

    public void Remove(Guid id)
    {
        _items.RemoveAll(i => i.Id == id);
        Persist();
    }

    public void SetSummary(Guid id, string summary)
    {
        if (Find(id) is not { } m) return;
        m.Summary = summary;
        Persist();
    }

    public void Rename(Guid id, string title)
    {
        if (Find(id) is not { } m) return;
        m.Title = title;
        Persist();
    }

    private void Persist()
    {
        Changed?.Invoke();
        _debouncer.Call(() => Storage.Save(_items, FileName));
    }
}
