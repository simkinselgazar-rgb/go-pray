// Program.cs — process entry. Phase 2: the shield exists; the tray, Setup, Settings, launch decision and
// autostart are wired in Phase 3/4. Until then a Release build does nothing on its own.

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
        return 0;
    }
}
