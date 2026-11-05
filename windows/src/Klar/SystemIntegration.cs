using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Klar.Core;
using Microsoft.Win32;

namespace Klar;

/// <summary>API-Schlüssel in der Windows-Anmeldeinformationsverwaltung (Eintrag „Klar/…“).</summary>
internal sealed class CredentialStore : ISecretStore
{
    private static string Target(string account) => "Klar/" + account;

    public string Read(string account)
    {
        try
        {
            if (!Native.CredRead(Target(account), Native.CRED_TYPE_GENERIC, 0, out var ptr)) return "";
            try
            {
                var cred = Marshal.PtrToStructure<Native.CREDENTIAL>(ptr);
                if (cred.CredentialBlob == IntPtr.Zero || cred.CredentialBlobSize == 0) return "";
                var bytes = new byte[cred.CredentialBlobSize];
                Marshal.Copy(cred.CredentialBlob, bytes, 0, bytes.Length);
                return Encoding.Unicode.GetString(bytes);
            }
            finally { Native.CredFree(ptr); }
        }
        catch (Exception e)
        {
            Log.Write("Anmeldeinformation nicht lesbar: " + e.Message);
            return "";
        }
    }

    public void Write(string account, string value)
    {
        try
        {
            if (value.Length == 0)
            {
                Native.CredDelete(Target(account), Native.CRED_TYPE_GENERIC, 0);
                return;
            }
            var blob = Encoding.Unicode.GetBytes(value);
            var target = Marshal.StringToCoTaskMemUni(Target(account));
            var user = Marshal.StringToCoTaskMemUni("Klar");
            var data = Marshal.AllocCoTaskMem(blob.Length);
            try
            {
                Marshal.Copy(blob, 0, data, blob.Length);
                var cred = new Native.CREDENTIAL
                {
                    Type = Native.CRED_TYPE_GENERIC,
                    TargetName = target,
                    UserName = user,
                    CredentialBlob = data,
                    CredentialBlobSize = (uint)blob.Length,
                    Persist = Native.CRED_PERSIST_LOCAL_MACHINE,
                };
                if (!Native.CredWrite(ref cred, 0))
                    Log.Write("Anmeldeinformation nicht schreibbar (" + Marshal.GetLastWin32Error() + ")");
            }
            finally
            {
                Marshal.FreeCoTaskMem(target);
                Marshal.FreeCoTaskMem(user);
                Marshal.FreeCoTaskMem(data);
            }
        }
        catch (Exception e) { Log.Write("Anmeldeinformation nicht schreibbar: " + e.Message); }
    }
}

/// <summary>„Beim Anmelden starten“ über den Run-Schlüssel des Benutzers.</summary>
internal static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Klar";

    public static bool IsEnabled
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                return key?.GetValue(ValueName) is string s && s.Length > 0;
            }
            catch { return false; }
        }
    }

    /// <summary>Gibt eine Fehlermeldung zurück, falls Windows die Änderung ablehnt.</summary>
    public static string? Set(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on)
            {
                var exe = Environment.ProcessPath ?? throw new InvalidOperationException("Programmpfad unbekannt");
                key.SetValue(ValueName, "\"" + exe + "\" --hidden");
            }
            else key.DeleteValue(ValueName, throwOnMissingValue: false);
            return null;
        }
        catch (Exception e)
        {
            Log.Write("Autostart: " + e.Message);
            return e.Message;
        }
    }
}

internal static class Shell
{
    public static void Open(string pathOrUrl)
    {
        try { Process.Start(new ProcessStartInfo(pathOrUrl) { UseShellExecute = true }); }
        catch (Exception e) { Log.Write("Öffnen fehlgeschlagen: " + e.Message); }
    }

    /// <summary>Zeigt die Datei markiert im Explorer.</summary>
    public static void Reveal(string path)
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + path + "\"") { UseShellExecute = false }); }
        catch (Exception e) { Log.Write("Explorer fehlgeschlagen: " + e.Message); }
    }

    /// <summary>Verschiebt die Datei in den Papierkorb.</summary>
    public static void Recycle(string path)
    {
        try
        {
            Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(path,
                Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs,
                Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
        }
        catch (Exception e) { Log.Write("Löschen fehlgeschlagen: " + e.Message); }
    }

    /// <summary>Whisper und die Bildschirmaufnahme brauchen die Microsoft-Visual-C++-Laufzeit.</summary>
    public static bool VcRuntimeInstalled
    {
        get
        {
            string[] needed = ["vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll", "vcomp140.dll"];
            string[] dirs = [Environment.SystemDirectory, AppContext.BaseDirectory, Path.Combine(AppContext.BaseDirectory, "runtimes", "win-x64")];
            return needed.All(f => dirs.Any(d => File.Exists(Path.Combine(d, f))));
        }
    }

    public const string VcRuntimeUrl = "https://aka.ms/vs/17/release/vc_redist.x64.exe";
}
