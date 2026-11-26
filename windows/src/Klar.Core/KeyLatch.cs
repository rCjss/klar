namespace Klar.Core;

/// <summary>Feststelltaste als „Taste festhalten“: Ist die Feststelltaste an und wird eine Taste gedrückt (z. B. W),
/// bleibt sie für alle Programme gedrückt, auch nach dem Loslassen – etwa zum Dauerlaufen in Spielen. Losgelassen
/// wird sie, wenn man sie bei eingeschalteter Feststelltaste erneut drückt, sie bei ausgeschalteter Feststelltaste
/// normal antippt oder die Feststelltaste ausschaltet. Nur die Entscheidungen, ohne Systemaufrufe – dieselbe Logik
/// hat die Mac-Fassung in Sources/Klar/KeyLatch.swift. Nicht threadsicher.</summary>
public sealed class KeyLatchLogic
{
    public enum Verdict { Pass, PassAndLatch, Swallow }

    private readonly HashSet<uint> _latched = [];
    /// <summary>Physisches Loslassen, das verschluckt wird, weil Programme die Taste weiter gedrückt sehen sollen.</summary>
    private readonly HashSet<uint> _swallowUp = [];
    /// <summary>Gerade physisch gedrückt – Windows meldet Tastenwiederholung als erneutes Drücken.</summary>
    private readonly HashSet<uint> _down = [];

    public IReadOnlyCollection<uint> Latched => _latched;

    /// <summary>Virtuelle Tastencodes, die sich nicht festhalten lassen: Umschalt, Strg, Alt, Windows, Feststelltaste, Esc.</summary>
    public static bool IsLatchable(uint vk) => vk is not (0x10 or 0x11 or 0x12 or 0x14 or 0x1B or 0x5B or 0x5C
        or 0xA0 or 0xA1 or 0xA2 or 0xA3 or 0xA4 or 0xA5);

    /// <returns>Urteil und Tasten, für die jetzt ein künstliches Loslassen zu senden ist.</returns>
    public (Verdict Verdict, uint[] Release) KeyDown(uint key, bool capsLock, bool otherModifiers)
    {
        if (!_down.Add(key)) return (Verdict.Pass, []); // Tastenwiederholung
        if (_latched.Contains(key))
        {
            if (!capsLock) return (Verdict.Pass, []); // normales Antippen: das Loslassen beendet es
            _latched.Remove(key);
            _swallowUp.Add(key);
            return (Verdict.Swallow, [key]);
        }
        if (!capsLock || otherModifiers || !IsLatchable(key)) return (Verdict.Pass, []);
        _latched.Add(key);
        _swallowUp.Add(key);
        return (Verdict.PassAndLatch, []);
    }

    public Verdict KeyUp(uint key)
    {
        _down.Remove(key);
        if (_swallowUp.Remove(key)) return Verdict.Swallow;
        _latched.Remove(key);
        return Verdict.Pass;
    }

    /// <summary>Feststelltaste aus (oder Funktion abgeschaltet): alle festgehaltenen Tasten loslassen.</summary>
    public uint[] CapsLockOff()
    {
        var all = _latched.ToArray();
        _latched.Clear();
        return all;
    }
}
