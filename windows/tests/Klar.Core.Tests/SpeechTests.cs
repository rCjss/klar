using Klar.Core;
using Xunit;

namespace Klar.Core.Tests;

public class ResamplerTests
{
    private static float[] Sine(double hz, int rate, double seconds, int channels = 1)
    {
        var n = (int)(rate * seconds);
        var data = new float[n * channels];
        for (var i = 0; i < n; i++)
            for (var c = 0; c < channels; c++)
                data[i * channels + c] = (float)(0.5 * Math.Sin(2 * Math.PI * hz * i / rate));
        return data;
    }

    private static double Rms(IReadOnlyList<float> x, int skip = 400)
        => Math.Sqrt(x.Skip(skip).Select(v => (double)v * v).Average());

    /// <summary>Speist in ungleich großen Blöcken ein – so wie die Soundkarte liefert.</summary>
    private static List<float> Run(Resampler r, float[] input, int channels)
    {
        var output = new List<float>();
        int[] sizes = [441, 480, 1024, 7, 960];
        var offset = 0;
        for (var k = 0; offset < input.Length; k++)
        {
            var n = Math.Min(sizes[k % sizes.Length] * channels, input.Length - offset);
            output.AddRange(r.Process(input.AsSpan(offset, n)));
            offset += n;
        }
        return output;
    }

    [Theory]
    [InlineData(48000, 2)]
    [InlineData(44100, 2)]
    [InlineData(44100, 1)]
    [InlineData(16000, 1)]
    [InlineData(8000, 1)]
    public void KeepsSpeechBand_AndLength(int rate, int channels)
    {
        var output = Run(new Resampler(rate, channels), Sine(1000, rate, 2, channels), channels);
        Assert.InRange(output.Count, 32000 - 4, 32000 + 4);
        Assert.InRange(Rms(output), 0.33, 0.37); // 0,5 / √2 ≈ 0,354
    }

    [Fact]
    public void ToneFrequency_IsPreserved()
    {
        var output = Run(new Resampler(48000, 1), Sine(1000, 48000, 1), 1);
        var crossings = 0;
        for (var i = 401; i < output.Count; i++)
            if (output[i - 1] < 0 && output[i] >= 0) crossings++;
        var seconds = (output.Count - 401) / 16000.0;
        Assert.InRange(crossings / seconds, 990, 1010);
    }

    [Fact]
    public void RemovesContentAboveTargetNyquist()
    {
        var output = Run(new Resampler(48000, 1), Sine(12000, 48000, 1), 1);
        Assert.True(Rms(output) < 0.01, $"Aliasing zu stark: {Rms(output)}");
    }
}

public class PcmDecoderTests
{
    [Fact]
    public void DecodesCommonFormats()
    {
        Assert.Equal([0.5f, -1f], PcmDecoder.ToFloat([0x00, 0x40, 0x00, 0x80], 16, false));
        Assert.Equal([0.5f, -1f], PcmDecoder.ToFloat([0x00, 0x00, 0x40, 0x00, 0x00, 0x80], 24, false));
        Assert.Equal([0.5f, -1f], PcmDecoder.ToFloat([0, 0, 0, 0x40, 0, 0, 0, 0x80], 32, false));
        var floats = new byte[8];
        BitConverter.GetBytes(0.25f).CopyTo(floats, 0);
        BitConverter.GetBytes(-0.75f).CopyTo(floats, 4);
        Assert.Equal([0.25f, -0.75f], PcmDecoder.ToFloat(floats, 32, true));
        Assert.Single(PcmDecoder.ToFloat([1, 2, 3], 16, false)); // unvollständiges letztes Sample entfällt
        Assert.Throws<NotSupportedException>(() => PcmDecoder.ToFloat(new byte[8], 64, true));
    }
}

public class SegmenterTests
{
    private const int Rate = 16000;
    private static readonly Random Rng = new(7);

    private static float[] Noise(double seconds, float amplitude)
    {
        var data = new float[(int)(seconds * Rate)];
        for (var i = 0; i < data.Length; i++) data[i] = (float)(Rng.NextDouble() * 2 - 1) * amplitude;
        return data;
    }

    private static List<SpeechSegment> Feed(SpeechSegmenter seg, params float[][] parts)
    {
        var done = new List<SpeechSegment>();
        var t = 0.0;
        foreach (var part in parts)
        {
            for (var o = 0; o < part.Length; o += 480)
            {
                var n = Math.Min(480, part.Length - o);
                t += n / (double)Rate;
                done.AddRange(seg.Append(part.AsSpan(o, n), TimeSpan.FromSeconds(t)));
            }
        }
        return done;
    }

    [Fact]
    public void SplitsAtPauses_WithPreRollAndStartTime()
    {
        var seg = new SpeechSegmenter();
        var done = Feed(seg, Noise(1.0, 0.001f), Noise(1.5, 0.2f), Noise(1.0, 0.001f), Noise(0.8, 0.2f), Noise(1.0, 0.001f));
        Assert.Equal(2, done.Count);
        // 1,5 s Sprache + Vorlauf (≤ 0,3 s) + Nachlauf (0,2 s)
        Assert.InRange(done[0].Samples.Length / (double)Rate, 1.6, 2.1);
        Assert.InRange(done[0].Start.TotalSeconds, 0.65, 1.0);
        Assert.InRange(done[1].Start.TotalSeconds, 3.15, 3.5);
        Assert.False(seg.InSegment);
    }

    [Fact]
    public void IgnoresSilenceAndShortClicks()
    {
        var seg = new SpeechSegmenter();
        var done = Feed(seg, Noise(2, 0.001f), Noise(0.06, 0.5f), Noise(2, 0.001f));
        Assert.Empty(done);
        Assert.Null(seg.Flush());
    }

    [Fact]
    public void LongSpeech_IsCutAtHardLimit()
    {
        var seg = new SpeechSegmenter();
        // Durchgehende Rede: laute Silben mit kurzen Atempausen, die keinen Abschnitt beenden.
        var parts = new List<float[]> { Noise(0.5, 0.001f) };
        for (var i = 0; i < 172; i++) { parts.Add(Noise(0.25, 0.2f)); parts.Add(Noise(0.1, 0.001f)); }
        var done = Feed(seg, [.. parts]);
        Assert.Equal(2, done.Count);
        Assert.All(done, s => Assert.InRange(s.Samples.Length / (double)Rate, 27.5, 28.1));
        Assert.NotNull(seg.Flush());
    }

    [Fact]
    public void Flush_ReturnsOpenSegment_AndIdleClosesIt()
    {
        var seg = new SpeechSegmenter();
        Assert.Empty(Feed(seg, Noise(0.5, 0.001f), Noise(1.0, 0.2f)));
        Assert.True(seg.InSegment);
        Assert.Null(seg.CloseIfIdle(TimeSpan.FromSeconds(0.2)));
        Assert.NotNull(seg.CloseIfIdle(TimeSpan.FromSeconds(1)));
        Assert.False(seg.InSegment);

        Assert.Empty(Feed(seg, Noise(1.0, 0.2f)));
        var last = seg.Flush();
        Assert.NotNull(last);
        Assert.InRange(last!.Value.Samples.Length / (double)Rate, 0.9, 1.4);
    }

    [Fact]
    public void AdaptsToConstantBackgroundNoise()
    {
        var seg = new SpeechSegmenter();
        // Lüfterrauschen knapp über der festen Schwelle darf nicht als Dauersprache zählen.
        var done = Feed(seg, Noise(6, 0.02f), Noise(1.2, 0.4f), Noise(2, 0.02f));
        Assert.Contains(done, s => s.Start.TotalSeconds > 5);
        Assert.False(seg.InSegment);
    }
}

public class TranscriptionSessionTests
{
    private sealed class FakeTranscriber(Func<float[], string> reply) : ITranscriber
    {
        public List<int> Lengths { get; } = [];
        public async Task<string> TranscribeAsync(float[] samples, string language, string? hint, CancellationToken ct)
        {
            await Task.Delay(20, ct);
            lock (Lengths) Lengths.Add(samples.Length);
            return reply(samples);
        }
    }

    private static float[] Tone(double seconds, float amp)
    {
        var rng = new Random(3);
        var d = new float[(int)(seconds * 16000)];
        for (var i = 0; i < d.Length; i++) d[i] = (float)(rng.NextDouble() * 2 - 1) * amp;
        return d;
    }

    [Fact]
    public async Task CommitsSegmentsInOrder_AndFlushesOnStop()
    {
        var clock = TimeSpan.Zero;
        var n = 0;
        var fake = new FakeTranscriber(_ => "Satz " + ++n);
        var session = new TranscriptionSession(fake, "de", () => clock);
        var committed = new List<(string Text, TimeSpan Start)>();
        var pendingSeen = 0;
        session.Committed += (t, s) => { lock (committed) committed.Add((t, s)); };
        session.PendingChanged += p => pendingSeen = Math.Max(pendingSeen, p);

        void Push(float[] data)
        {
            for (var o = 0; o < data.Length; o += 1600)
            {
                var len = Math.Min(1600, data.Length - o);
                clock += TimeSpan.FromSeconds(len / 16000.0);
                session.Append(data.AsSpan(o, len));
            }
        }

        Push(Tone(0.5, 0.001f));
        Push(Tone(1.0, 0.2f));
        Push(Tone(1.0, 0.001f));
        Push(Tone(1.0, 0.2f)); // bleibt offen bis Stop
        await session.StopAsync();

        Assert.Equal(["Satz 1", "Satz 2"], committed.Select(c => c.Text));
        Assert.InRange(committed[0].Start.TotalSeconds, 0.15, 0.55);
        Assert.InRange(committed[1].Start.TotalSeconds, 2.1, 2.6);
        Assert.True(pendingSeen >= 1);
        Assert.Equal(0, session.Pending);
        session.Append(Tone(1, 0.2f)); // nach Stop wirkungslos
        Assert.Equal(2, fake.Lengths.Count);
    }

    [Fact]
    public async Task DropsHallucinations_AndSurvivesErrors()
    {
        var clock = TimeSpan.Zero;
        var replies = new Queue<string>(["Untertitel der Amara.org-Community", "[Musik]", "BOOM", "Echter Text."]);
        var fake = new FakeTranscriber(_ =>
        {
            var r = replies.Dequeue();
            return r == "BOOM" ? throw new InvalidOperationException("kaputt") : r;
        });
        var session = new TranscriptionSession(fake, "de", () => clock);
        var committed = new List<string>();
        var failures = 0;
        session.Committed += (t, _) => committed.Add(t);
        session.Failed += _ => failures++;
        for (var i = 0; i < 4; i++)
        {
            foreach (var part in new[] { Tone(1.0, 0.2f), Tone(1.0, 0.001f) })
                for (var o = 0; o < part.Length; o += 1600)
                {
                    clock += TimeSpan.FromSeconds(0.1);
                    session.Append(part.AsSpan(o, 1600));
                }
        }
        await session.StopAsync();
        Assert.Equal(["Echter Text."], committed);
        Assert.Equal(1, failures);
    }

    [Fact]
    public async Task Cancel_DiscardsPendingWork()
    {
        var fake = new FakeTranscriber(_ => "x");
        var clock = TimeSpan.Zero;
        var session = new TranscriptionSession(fake, "de", () => clock);
        var committed = 0;
        session.Committed += (_, _) => committed++;
        var speech = Tone(1.0, 0.2f);
        for (var o = 0; o < speech.Length; o += 1600) { clock += TimeSpan.FromSeconds(0.1); session.Append(speech.AsSpan(o, 1600)); }
        session.Cancel();
        await session.StopAsync();
        Assert.Equal(0, committed);
    }
}

public class HallucinationFilterTests
{
    [Theory]
    [InlineData("Untertitel der Amara.org-Community", "")]
    [InlineData("Untertitelung des ZDF, 2020", "")]
    [InlineData("Vielen Dank fürs Zuschauen!", "")]
    [InlineData("[BLANK_AUDIO]", "")]
    [InlineData("(Musik) Hallo zusammen. *lacht*", "Hallo zusammen.")]
    [InlineData("Vielen Dank.", "Vielen Dank.")]
    [InlineData("Die Untertitel im Film waren gut.", "Die Untertitel im Film waren gut.")]
    public void Clean(string input, string expected) => Assert.Equal(expected, HallucinationFilter.Clean(input));
}

public class SpeechModelTests : StorageTest
{
    [Fact]
    public void Catalog()
    {
        Assert.Equal("small", SpeechModels.Default.Id);
        Assert.Same(SpeechModels.Default, SpeechModels.Find("gibt-es-nicht"));
        Assert.Same(SpeechModels.Accurate, SpeechModels.Find("large-v3-turbo"));
        Assert.EndsWith("/ggml-small-q5_1.bin", SpeechModels.Default.Url);
        Assert.False(SpeechModels.Default.IsDownloaded);
        Assert.StartsWith(Path.Combine(Dir, "Models"), SpeechModels.Default.FilePath);
    }
}
