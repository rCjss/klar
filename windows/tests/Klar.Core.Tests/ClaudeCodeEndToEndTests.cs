using Klar.Core;
using Xunit;
using Xunit.Abstractions;

namespace Klar.Core.Tests;

/// <summary>Echter Aufruf der installierten Claude-Code-Kommandozeile (über das eigene Abo).
/// Läuft nur mit KLAR_TEST_CLAUDE_CODE=1.</summary>
public class ClaudeCodeEndToEndTests(ITestOutputHelper output)
{
    [Fact]
    public async Task Summarize_ViaInstalledCli()
    {
        if (Environment.GetEnvironmentVariable("KLAR_TEST_CLAUDE_CODE") != "1") return;
        var dir = Path.Combine(Path.GetTempPath(), "klar-tests-" + Guid.NewGuid().ToString("N"));
        Storage.Configure(dir);
        try
        {
            var command = ClaudeCodeBackend.Locate();
            Assert.NotNull(command);
            output.WriteLine("Programm: " + command!.FileName);
            const string transcript = """
                [00:00:02] Ich: Wir liefern das Angebot für den Sportboden bis Freitag.
                [00:00:09] Andere: Einverstanden. Anna prüft bis Mittwoch die Materialpreise.
                [00:00:15] Ich: Offen ist noch, ob der Kunde Linierung wünscht.
                """;
            var summary = await new ClaudeCodeBackend().SummarizeAsync(transcript);
            output.WriteLine(summary);
            Assert.Contains("## Kurzfassung", summary);
            Assert.Contains("## Aufgaben", summary);
            Assert.Contains("Anna", summary);
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { }
        }
    }
}
