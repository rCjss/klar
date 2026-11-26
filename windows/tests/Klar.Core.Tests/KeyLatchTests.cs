using Klar.Core;
using Xunit;
using static Klar.Core.KeyLatchLogic;

namespace Klar.Core.Tests;

public class KeyLatchTests
{
    private const uint W = 0x57, A = 0x41;

    [Fact]
    public void WithoutCapsLock_EverythingPasses()
    {
        var l = new KeyLatchLogic();
        Assert.Equal(Verdict.Pass, l.KeyDown(W, capsLock: false, otherModifiers: false).Verdict);
        Assert.Equal(Verdict.Pass, l.KeyUp(W));
        Assert.Empty(l.Latched);
    }

    [Fact]
    public void CapsLockAndW_HoldsW_UntilPressedAgain()
    {
        var l = new KeyLatchLogic();
        Assert.Equal(Verdict.PassAndLatch, l.KeyDown(W, true, false).Verdict);
        Assert.Equal(Verdict.Pass, l.KeyDown(W, true, false).Verdict);  // Wiederholung
        Assert.Equal(Verdict.Swallow, l.KeyUp(W));                       // bleibt für Programme gedrückt
        Assert.Equal([W], l.Latched);

        var (verdict, release) = l.KeyDown(W, true, false);
        Assert.Equal(Verdict.Swallow, verdict);
        Assert.Equal([W], release);
        Assert.Equal(Verdict.Swallow, l.KeyUp(W));
        Assert.Empty(l.Latched);
    }

    [Fact]
    public void CapsLockOff_ReleasesAll()
    {
        var l = new KeyLatchLogic();
        l.KeyDown(W, true, false); l.KeyUp(W);
        l.KeyDown(A, true, false); l.KeyUp(A);
        Assert.Equal(new[] { A, W }, l.CapsLockOff().Order());
        Assert.Empty(l.Latched);
    }

    [Fact]
    public void NormalTap_ReleasesLatchedKey()
    {
        var l = new KeyLatchLogic();
        l.KeyDown(W, true, false); l.KeyUp(W);
        Assert.Equal(Verdict.Pass, l.KeyDown(W, false, false).Verdict);
        Assert.Equal(Verdict.Pass, l.KeyUp(W));
        Assert.Empty(l.Latched);
    }

    [Fact]
    public void Shortcuts_ModifiersAndEscape_AreNotLatched()
    {
        var l = new KeyLatchLogic();
        Assert.Equal(Verdict.Pass, l.KeyDown(W, true, otherModifiers: true).Verdict);
        l.KeyUp(W);
        Assert.Equal(Verdict.Pass, l.KeyDown(0x1B, true, false).Verdict);
        Assert.Equal(Verdict.Pass, l.KeyDown(0xA0, true, false).Verdict);
        Assert.Empty(l.Latched);
    }
}
