using Klar.Core;
using Xunit;

[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace Klar.Core.Tests;

/// <summary>Kein Test darf in den echten Datenordner der App schreiben – auch nicht über das Protokoll.
/// Deshalb zeigt die Ablage schon vor dem ersten Test auf einen temporären Ordner.</summary>
internal static class TestModule
{
    [System.Runtime.CompilerServices.ModuleInitializer]
    internal static void Init()
    {
        var dir = Path.Combine(Path.GetTempPath(), "klar-tests-default-" + Guid.NewGuid().ToString("N"));
        Storage.Configure(dir, Path.Combine(dir, "Videos"), Path.Combine(dir, "Models"));
    }
}

/// <summary>Jede Testklasse bekommt einen frischen, leeren Datenordner.</summary>
public abstract class StorageTest : IDisposable
{
    protected readonly string Dir = Path.Combine(Path.GetTempPath(), "klar-tests-" + Guid.NewGuid().ToString("N"));

    protected StorageTest()
    {
        Storage.Configure(Dir, Path.Combine(Dir, "Videos"), Path.Combine(Dir, "Models"));
        AppSettings.Secrets = new MemorySecretStore();
        AppSettings.ResetForTests();
    }

    public void Dispose()
    {
        Debouncer.FlushAll();
        try { Directory.Delete(Dir, recursive: true); } catch { }
    }
}
