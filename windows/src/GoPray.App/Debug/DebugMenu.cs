// DebugMenu.cs — DEBUG builds only (whole file). Port of Debug/DebugMenu.swift.
// "Trigger Athan now (20 s lock)" per mode for the open/next prayer (needs setup done), "Wipe state (idle only)",
// and `--debug-seed toronto` (does Setup's Finish through the same store.Mutate). It can start a block, never
// end one: the shield's "I prayed" goes through RequestConfirm like always. None of this exists in Release
// (guard rule 10 + the -Release binary scan).

#if DEBUG
using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using GoPray.App.UI;
using GoPray.Core;

namespace GoPray.App.Debug;

internal static class DebugMenu
{
    public static UIElement Build(AppHost env)
    {
        var p = new StackPanel { Margin = new Thickness(16, 10, 16, 10) };
        p.Children.Add(Theme.Text("Debug", 11, Theme.Secondary));
        p.Children.Add(Theme.Link("Trigger Athan now (20 s lock) · Whole screen", () => Trigger(env, BlockMode.WholeScreen)));
        p.Children.Add(Theme.Link("Trigger Athan now (20 s lock) · Coding apps", () => Trigger(env, BlockMode.CodingApps)));
        p.Children.Add(Theme.Link("Wipe state (idle only)", () => env.Gate.DebugWipeState()));
        // "Emergency exits (debug)": set this year's used count, idle only.
        var used = new StackPanel { Orientation = Orientation.Horizontal };
        used.Children.Add(Theme.Text("Emergency exits (debug) used: ", 11, Theme.Secondary, wrap: false));
        for (int n = 0; n <= EmergencyExitPolicy.Total; n++)
        {
            int k = n;
            var l = Theme.Link(k.ToString(System.Globalization.CultureInfo.InvariantCulture), () => env.Gate.DebugSetEmergencyExitsUsed(k));
            l.Margin = new Thickness(0, 0, 8, 0);
            used.Children.Add(l);
        }
        p.Children.Add(used);
        return p;
    }

    /// <summary>The prayer whose window is open now, else the next one.</summary>
    static Prayer CurrentPrayer(AppHost env)
    {
        var now = env.Clock.Now;
        if (env.Schedule.Window(now) is { } w && now < w.End) return w.Prayer;
        return env.Schedule.NextAthan(now)?.Prayer ?? Prayer.Dhuhr;
    }

    static void Trigger(AppHost env, BlockMode mode)
    {
        if (env.Gate.IsBlocked || !env.SettingsStore.Settings.SetupComplete) return;
        try { env.SettingsStore.Mutate(s => s with { Mode = mode }); } catch (Exception) { return; }
        env.Popover?.Hide();
        env.Gate.DebugTriggerAthan(CurrentPrayer(env), 20);
    }

    /// <summary>`GoPray.exe --debug-seed toronto`: Setup's Finish for Toronto, ISNA, Standard, whole screen, volume 0.15,
    /// launch at login OFF (a Debug build is framework-dependent, so a logon task would not start it). Setup not done only.</summary>
    public static void SeedIfAsked(AppHost env, string[] args)
    {
        int i = Array.IndexOf(args, "--debug-seed");
        if (i < 0 || i + 1 >= args.Length || args[i + 1] != "toronto" || env.SettingsStore.Settings.SetupComplete) return;
        try
        {
            env.SettingsStore.Mutate(s => s with
            {
                City = "Toronto, Ontario", Latitude = 43.6532, Longitude = -79.3832, Method = "northAmerica", Madhab = 1,
                Mode = BlockMode.WholeScreen, AthanVolume = 0.15f, LaunchAtLogin = false, SetupComplete = true,
            });
            CoreLog.Notice("DEBUG seed: toronto");
        }
        catch (Exception e) { CoreLog.Error("DEBUG seed failed: " + e.Message); }
    }
}
#endif
