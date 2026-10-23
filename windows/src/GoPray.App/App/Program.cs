// Program.cs — process entry. AppHost decides (single instance, `--tick`) and wires everything.

using System;
using GoPray.App.Shield;

namespace GoPray.App;

internal static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        // The hook dies with the process anyway; this makes the release explicit on a normal exit.
        AppDomain.CurrentDomain.ProcessExit += (_, _) => KeyboardGuard.Uninstall();
#if DEBUG
        if (Debug.DebugHarness.Wants(args)) return Debug.DebugHarness.Run(args);
#endif
        return AppHost.Run(args);
    }
}
