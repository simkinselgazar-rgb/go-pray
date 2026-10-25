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
        // TV discovery from the real exe (what Windows Firewall really does to it): prints what Find TVs would see.
        if (Array.IndexOf(args, "--debug-find-tvs") >= 0)
        {
            GoPray.Core.CoreLog.Sink = Console.WriteLine;
            var d = new Tv.TvController().Discover(new System.Threading.CancellationTokenSource(10_000).Token).GetAwaiter().GetResult();
            Console.WriteLine($"found {d.Found.Count}, firewallBlocks={d.FirewallBlocks}, firewallCheck={Tv.TvController.FirewallDropsReplies()}");
            foreach (var f in d.Found) Console.WriteLine($"  {f.Host}  {f.Name}");
            return 0;
        }
#endif
        return AppHost.Run(args);
    }
}
