using Klar.Core;
using Xunit;
using Xunit.Abstractions;

namespace Klar.Core.Tests;

/// <summary>Echter Durchlauf mit Whisper: WAV → 16 kHz → Abschnitte → Text → Sprachbefehle.
/// Läuft nur, wenn KLAR_WHISPER_MODEL (Modelldatei) und KLAR_TEST_WAV (16-Bit-PCM-WAV) gesetzt sind.</summary>
public class WhisperEndToEndTests(ITestOutputHelper output)
{
    private static (float[] Interleaved, int Rate, int Channels) ReadWav(string path)
    {
        var b = File.ReadAllBytes(path);
        int rate = 0, channels = 0, bits = 0;
        var pos = 12;
        while (pos + 8 <= b.Length)
        {
            var id = System.Text.Encoding.ASCII.GetString(b, pos, 4);
            var size = BitConverter.ToInt32(b, pos + 4);
            if (id == "fmt ")
            {
                channels = BitConverter.ToInt16(b, pos + 10);
                rate = BitConverter.ToInt32(b, pos + 12);
                bits = BitConverter.ToInt16(b, pos + 22);
            }
            else if (id == "data")
            {
                Assert.Equal(16, bits);
                size = Math.Min(size, b.Length - pos - 8);
                var samples = new float[size / 2];
                for (var i = 0; i < samples.Length; i++) samples[i] = BitConverter.ToInt16(b, pos + 8 + i * 2) / 32768f;
                return (samples, rate, channels);
            }
            pos += 8 + size + (size & 1);
        }
        throw new InvalidDataException("Kein data-Abschnitt.");
    }

    [Fact]
    public async Task Dictation_FromWavToPastedText()
    {
        var model = Environment.GetEnvironmentVariable("KLAR_WHISPER_MODEL");
        var wav = Environment.GetEnvironmentVariable("KLAR_TEST_WAV");
        if (string.IsNullOrEmpty(model) || string.IsNullOrEmpty(wav)) return;

        var (audio, rate, channels) = ReadWav(wav);
        using var whisper = new WhisperTranscriber(model);
        var clock = TimeSpan.Zero;
        Snippet[] snippets = [new Snippet { Trigger = "Signatur", Text = "Viele Grüße\nFelix" }];
        var session = new TranscriptionSession(whisper, "de", () => clock, hint: VoiceCommands.RecognitionHint(snippets, "einfügen"));
        var committed = new List<(string Text, TimeSpan Start)>();
        session.Committed += (t, s) => { lock (committed) committed.Add((t, s)); };

        var resampler = new Resampler(rate, channels);
        var block = rate / 100 * channels; // 10 ms, wie WASAPI
        var started = DateTime.UtcNow;
        for (var o = 0; o < audio.Length; o += block)
        {
            var n = Math.Min(block, audio.Length - o);
            clock += TimeSpan.FromSeconds(n / (double)channels / rate);
            session.Append(resampler.Process(audio.AsSpan(o, n)));
        }
        await session.StopAsync();
        output.WriteLine($"Dauer Audio: {clock.TotalSeconds:0.0} s, Erkennung: {(DateTime.UtcNow - started).TotalSeconds:0.0} s");
        foreach (var c in committed) output.WriteLine($"[{c.Start.TotalSeconds:0.0}] {c.Text}");

        Assert.True(committed.Count >= 2, "Sprechpausen sollten mehrere Abschnitte ergeben.");
        var raw = string.Join(" ", committed.Select(c => c.Text));
        var result = VoiceCommands.Apply(raw, snippets, "einfügen");
        output.WriteLine("---\n" + result.Text);
        Assert.Contains("Unterlagen", result.Text);
        Assert.Contains("Freitag", result.Text);
        Assert.Contains("Hallo Anna\n", result.Text);
        Assert.EndsWith("Viele Grüße\nFelix", result.Text);
        Assert.Equal("Signatur", result.UsedSnippet);
    }
}
