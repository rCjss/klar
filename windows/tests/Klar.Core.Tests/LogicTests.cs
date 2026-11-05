using System.Text.Json;
using Klar.Core;
using Xunit;

namespace Klar.Core.Tests;

public class VoiceCommandTests
{
    private static readonly Snippet[] Snippets =
    [
        new() { Trigger = "Signatur", Text = "Viele Grüße\nFelix" },
        new() { Trigger = "Meine Adresse", Text = "Musterweg 1, 12345 Berlin" },
    ];

    [Theory]
    [InlineData("Signatur")]
    [InlineData("signatur.")]
    [InlineData("  Signatur!  ")]
    public void NameAlone_InsertsSnippet(string spoken)
    {
        var r = VoiceCommands.Apply(spoken, Snippets, "einfügen");
        Assert.Equal("Viele Grüße\nFelix", r.Text);
        Assert.Equal("Signatur", r.UsedSnippet);
    }

    [Fact]
    public void PrefixInSentence_ReplacesInline()
    {
        var r = VoiceCommands.Apply("Bis morgen, einfügen Signatur.", Snippets, "einfügen");
        Assert.Equal("Bis morgen, Viele Grüße\nFelix", r.Text);
        Assert.Equal("Signatur", r.UsedSnippet);
    }

    [Fact]
    public void MultiWordTrigger_AllowsCommaBetweenWords()
    {
        var r = VoiceCommands.Apply("Schick es an Einfügen: meine, Adresse", Snippets, "einfügen");
        Assert.Equal("Schick es an Musterweg 1, 12345 Berlin", r.Text);
    }

    [Theory]
    [InlineData("Bis Freitag. Ein Fügen-Signatur.")]
    [InlineData("Bis Freitag. einfügen, Signa-tur")]
    public void SplitOrHyphenatedCommand_IsStillRecognised(string spoken)
    {
        var r = VoiceCommands.Apply(spoken, Snippets, "einfügen");
        Assert.Equal("Bis Freitag. Viele Grüße\nFelix", r.Text);
    }

    [Fact]
    public void WordWithoutPrefix_StaysUntouched()
    {
        var r = VoiceCommands.Apply("Die Signatur fehlt noch.", Snippets, "einfügen");
        Assert.Equal("Die Signatur fehlt noch.", r.Text);
        Assert.Null(r.UsedSnippet);
    }

    [Fact]
    public void SnippetTextWithDollarSign_IsInsertedLiterally()
    {
        var r = VoiceCommands.Apply("einfügen Preis", [new Snippet { Trigger = "Preis", Text = "$1 kostet $0" }], "einfügen");
        Assert.Equal("$1 kostet $0", r.Text);
    }

    [Fact]
    public void Builtins_NewLineAndParagraph()
    {
        var r = VoiceCommands.Apply("Hallo Anna, neue Zeile wie geht es dir. Neuer Absatz. Bis bald", [], "einfügen");
        Assert.Equal("Hallo Anna\nwie geht es dir.\n\nBis bald", r.Text);
    }

    [Fact]
    public void RecognitionHint_ListsCommandsAsSpoken()
        => Assert.Equal("Einfügen Signatur. Einfügen Meine Adresse. Neue Zeile. Neuer Absatz.", VoiceCommands.RecognitionHint(Snippets, "einfügen"));

    [Fact]
    public void Normalize_StripsPunctuationAndCase()
        => Assert.Equal("größe 42 ok", VoiceCommands.Normalize("  Größe:  42 – OK!"));
}

public class HotkeyTests
{
    [Fact]
    public void Display_ListsModifiersInFixedOrder()
    {
        Assert.Equal("Strg+Alt+V", Hotkey.ClipboardDefault.Display);
        Assert.Equal("Strg+Alt+Umschalt+M", Hotkey.MeetingDefault.Display);
        Assert.Equal("Umschalt+Win+Leertaste", new Hotkey(Hotkey.VkSpace, HotkeyModifiers.Win | HotkeyModifiers.Shift).Display);
        Assert.Equal("F9", new Hotkey(0x78, HotkeyModifiers.None).Display);
    }

    [Fact]
    public void ModifierOnly_IsRecognised()
    {
        var hk = new Hotkey(Hotkey.VkRControl, HotkeyModifiers.None);
        Assert.True(hk.IsModifierOnly);
        Assert.Equal("rechte Strg", hk.Display);
        Assert.False(Hotkey.ClipboardDefault.IsModifierOnly);
    }

    [Fact]
    public void Acceptable_NeedsModifierExceptFunctionKeys()
    {
        Assert.False(Hotkey.IsAcceptable('A', HotkeyModifiers.None));
        Assert.True(Hotkey.IsAcceptable('A', HotkeyModifiers.Control));
        Assert.True(Hotkey.IsAcceptable(0x70, HotkeyModifiers.None));
    }

    [Fact]
    public void Json_RoundTrips()
    {
        var json = JsonSerializer.Serialize(Hotkey.MeetingDefault, Storage.Json);
        Assert.Equal(Hotkey.MeetingDefault, JsonSerializer.Deserialize<Hotkey>(json, Storage.Json));
        Assert.DoesNotContain("display", json);
    }
}

public class FormatTests
{
    [Fact]
    public void Clock() => Assert.Equal("01:02:03", Format.Clock(3723.9));

    [Fact]
    public void Relative()
    {
        var now = new DateTime(2026, 11, 5, 12, 0, 0, DateTimeKind.Local).ToUniversalTime();
        Assert.Equal("gerade eben", Format.Relative(now.AddSeconds(-30), now));
        Assert.Equal("vor 5 Min.", Format.Relative(now.AddMinutes(-5), now));
        Assert.Equal("09:00", Format.Relative(now.AddHours(-3), now));
        Assert.Equal("gestern", Format.Relative(now.AddHours(-20), now));
        Assert.Equal("1. Nov. 2026, 12:00", Format.Relative(now.AddDays(-4), now));
    }

    [Fact]
    public void ClipPreview()
    {
        Assert.Equal("a ⏎ b", new ClipItem { Kind = ClipKind.Text, Text = " a\r\nb \n" }.Preview);
        Assert.Equal("x.txt, Ordner", new ClipItem { Kind = ClipKind.Files, Files = [@"C:\tmp\x.txt", "/tmp/Ordner"] }.Preview);
        Assert.True(new ClipItem { Kind = ClipKind.Text, Text = "Hallo Welt", SourceApp = "Notepad" }.Matches("note"));
        Assert.False(new ClipItem { Kind = ClipKind.Text, Text = "Hallo Welt" }.Matches("xyz"));
    }
}

public class ClipboardStoreTests : StorageTest
{
    private static ClipItem Text(string t) => new() { Kind = ClipKind.Text, Text = t };

    [Fact]
    public void SameText_MovesToTop_AndKeepsPinAndId()
    {
        var store = new ClipboardStore(() => 500);
        store.Add(Text("a"));
        store.Add(Text("b"));
        var a = store.Items.First(i => i.Text == "a");
        store.TogglePin(a.Id);
        store.Add(Text("a"));
        Assert.Equal(2, store.Items.Count);
        Assert.Equal("a", store.Items[0].Text);
        Assert.True(store.Items[0].Pinned);
        Assert.Equal(a.Id, store.Items[0].Id);
    }

    [Fact]
    public void SameFilesTwiceInARow_AreNotDuplicated()
    {
        var store = new ClipboardStore(() => 500);
        store.Add(new ClipItem { Kind = ClipKind.Files, Files = [@"C:\a.gif"] });
        store.Add(new ClipItem { Kind = ClipKind.Files, Files = [@"C:\a.gif"] });
        Assert.Single(store.Items);
        store.Add(Text("dazwischen"));
        store.Add(new ClipItem { Kind = ClipKind.Files, Files = [@"C:\a.gif"] });
        Assert.Equal(3, store.Items.Count);
    }

    [Fact]
    public void Ordered_PinnedFirst_ThenMostRecent()
    {
        var store = new ClipboardStore(() => 500);
        foreach (var t in new[] { "a", "b", "c" }) store.Add(Text(t));
        store.TogglePin(store.Items.First(i => i.Text == "a").Id);
        Assert.Equal(["a", "c", "b"], store.Ordered.Select(i => i.Text));
        store.Touch(store.Items.First(i => i.Text == "b").Id);
        Assert.Equal(["a", "b", "c"], store.Ordered.Select(i => i.Text));
    }

    [Fact]
    public void Trim_KeepsPinned_AndDeletesImagesOfDroppedItems()
    {
        var store = new ClipboardStore(() => 20);
        var image = Path.Combine(Storage.Images, "alt.png");
        File.WriteAllBytes(image, [1, 2, 3]);
        store.Add(new ClipItem { Kind = ClipKind.Image, ImageFile = "alt.png" });
        store.Add(Text("pin"));
        store.TogglePin(store.Items[0].Id);
        for (var i = 0; i < 25; i++) store.Add(Text("t" + i));
        Assert.Equal(21, store.Items.Count);
        Assert.Contains(store.Items, i => i.Text == "pin");
        Assert.DoesNotContain(store.Items, i => i.Kind == ClipKind.Image);
        Assert.False(File.Exists(image));
    }

    [Fact]
    public void ClearUnpinned_AndPersistence()
    {
        var store = new ClipboardStore(() => 500);
        store.Add(Text("bleibt"));
        store.TogglePin(store.Items[0].Id);
        store.Add(Text("weg"));
        store.ClearUnpinned();
        Debouncer.FlushAll();
        var reloaded = new ClipboardStore(() => 500);
        Assert.Single(reloaded.Items);
        Assert.Equal("bleibt", reloaded.Items[0].Text);
        Assert.True(reloaded.Items[0].Pinned);
        Assert.Contains("\"kind\": \"text\"", File.ReadAllText(Path.Combine(Dir, "clipboard.json")));
    }
}

public class SettingsTests : StorageTest
{
    [Fact]
    public void Defaults_AndRoundTrip()
    {
        AppSettings.FullUserName = () => "Erika Muster";
        var s = AppSettings.Shared;
        Assert.Equal(Hotkey.ClipboardDefault, s.ClipboardHotkey);
        Assert.Equal("Viele Grüße\nErika Muster", s.Snippets.Single().Text);
        Assert.Equal("de", s.LanguageCode);

        s.DictationHotkey = new Hotkey(Hotkey.VkRControl, HotkeyModifiers.None);
        s.HistoryLimit = 2000;
        s.ClaudeApiKey = "  sk-test  ";
        s.Snippets.Add(new Snippet { Trigger = "Adresse", Text = "Weg 1" });
        s.SnippetsEdited();

        AppSettings.ResetForTests();
        var again = AppSettings.Shared;
        Assert.NotSame(s, again);
        Assert.True(again.DictationHotkey.IsModifierOnly);
        Assert.Equal(2000, again.HistoryLimit);
        Assert.Equal(2, again.Snippets.Count);
        Assert.Equal("sk-test", again.ClaudeApiKey);
        Assert.DoesNotContain("sk-test", File.ReadAllText(Path.Combine(Dir, "settings.json")));
    }

    [Fact]
    public void CorruptFile_FallsBackToDefaults_AndKeepsACopy()
    {
        File.WriteAllText(Path.Combine(Dir, "settings.json"), "{ kaputt");
        Assert.Equal(500, AppSettings.Shared.HistoryLimit);
        Assert.True(File.Exists(Path.Combine(Dir, "settings.json.defekt")));
    }
}

public class MeetingTests : StorageTest
{
    [Fact]
    public void PlainText_AndStore()
    {
        var m = new MeetingTranscript { Title = "Test" };
        m.Lines.Add(new TranscriptLine { Time = 5, Speaker = "Ich", Text = "Hallo" });
        m.Lines.Add(new TranscriptLine { Time = 65, Speaker = "Andere", Text = "Tag" });
        Assert.Equal("[00:00:05] Ich: Hallo\n[00:01:05] Andere: Tag", m.PlainText);

        var store = new MeetingStore();
        store.Upsert(m);
        store.SetSummary(m.Id, "## Kurzfassung");
        store.Rename(m.Id, "Neu");
        Debouncer.FlushAll();
        var again = new MeetingStore().Find(m.Id)!;
        Assert.Equal("Neu", again.Title);
        Assert.Equal("## Kurzfassung", again.Summary);
        Assert.Equal(2, again.Lines.Count);
    }
}

public class GiphyTests
{
    [Fact]
    public void FileName_IsSafeForWindows()
    {
        var gif = new GiphyGif { Id = "abc123XYZ", Title = "Happy: Cat/Dog? GIF by Someone" };
        Assert.Equal("Happy  Cat Dog abc123.gif", GiphyClient.FileName(gif));
        Assert.Equal("GIF 12.gif", GiphyClient.FileName(new GiphyGif { Id = "12", Title = " GIF" }));
    }

    [Fact]
    public void Json_MapsSnakeCase()
    {
        const string json = """{"id":"1","title":"t","images":{"fixed_width":{"url":"https://a/p.gif","width":"200","height":"113"},"original":{"url":"https://a/o.gif","width":"480","height":"270"}}}""";
        var gif = JsonSerializer.Deserialize<GiphyGif>(json)!;
        Assert.Equal("https://a/p.gif", gif.PreviewUrl);
        Assert.Equal("https://a/o.gif", gif.OriginalUrl);
    }

    [Fact]
    public async Task MissingKey_Throws()
        => Assert.Equal("Kein Giphy-API-Schlüssel hinterlegt.", (await Assert.ThrowsAsync<GiphyException>(() => GiphyClient.FetchAsync("cat", " "))).Message);
}

public class SummarizerTests
{
    [Fact]
    public void ApiBody_MatchesMacVersion()
    {
        using var doc = JsonDocument.Parse(ClaudeApiBackend.BuildBody("[00:00:01] Ich: Hallo"));
        var root = doc.RootElement;
        Assert.Equal("claude-opus-5-5", root.GetProperty("model").GetString());
        Assert.Equal(8000, root.GetProperty("max_tokens").GetInt32());
        Assert.Equal("default", root.GetProperty("fallbacks").GetString());
        Assert.StartsWith("Du fasst Meeting-Transkripte", root.GetProperty("system").GetString());
        var msg = root.GetProperty("messages")[0];
        Assert.Equal("user", msg.GetProperty("role").GetString());
        Assert.Equal("Transkript:\n\n[00:00:01] Ich: Hallo", msg.GetProperty("content").GetString());
    }

    [Fact]
    public void ApiResponse_JoinsTextBlocks()
        => Assert.Equal("A\nB", ClaudeApiBackend.ParseResponse("""{"stop_reason":"end_turn","content":[{"type":"text","text":" A"},{"type":"thinking","thinking":"x"},{"type":"text","text":"B "}]}"""));

    [Fact]
    public void ApiResponse_RefusalAndEmpty()
    {
        Assert.Equal("Die Anfrage wurde vom Modell abgelehnt.", Assert.Throws<SummaryException>(() => ClaudeApiBackend.ParseResponse("""{"stop_reason":"refusal","content":[]}""")).Message);
        Assert.Equal("Leere Antwort erhalten.", Assert.Throws<SummaryException>(() => ClaudeApiBackend.ParseResponse("""{"content":[]}""")).Message);
    }

    [Fact]
    public void ClaudeCodeArguments_DisableToolsAndSessions()
    {
        var args = ClaudeCodeBackend.Arguments(new ClaudeCodeBackend.Command("node.exe", ["cli.js"]));
        Assert.Equal("cli.js", args[0]);
        Assert.Equal("-p", args[1]);
        Assert.Contains("--no-session-persistence", args);
        var tools = args.ToList().IndexOf("--tools");
        Assert.Equal("", args[tools + 1]);
        Assert.Equal(Summarizer.Instructions, args[^1]);
    }

    [Fact]
    public void ProviderKeys_MatchMacVersion()
    {
        Assert.Equal(SummaryProvider.ClaudeApi, SummaryProviders.Parse("claudeAPI"));
        Assert.Equal(SummaryProvider.Auto, SummaryProviders.Parse("apple"));
        Assert.Equal("claudeCode", SummaryProvider.ClaudeCode.Key());
    }
}
