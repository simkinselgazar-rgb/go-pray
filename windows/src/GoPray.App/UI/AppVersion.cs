// AppVersion.cs — "Go Pray 0.2.0" for the tray popup, Settings and Credits. Read from the assembly's informational
// version (set by <Version> in GoPray.App.csproj or `-p:Version=` in build-installer.ps1), never typed by hand.
// The SDK may append "+<commit>" (source link); only the part before "+" is shown.

using System.Reflection;

namespace GoPray.App.UI;

internal static class AppVersion
{
    public static string Number { get; } = Clean(typeof(AppVersion).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion);

    public static string Line => "Go Pray " + Number;

    internal static string Clean(string? informational)
    {
        var v = (informational ?? "").Split('+')[0].Trim();
        return v.Length == 0 ? "0.0.0" : v;
    }
}
