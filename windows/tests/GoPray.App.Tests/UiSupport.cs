// UiSupport.cs — one long-lived STA thread with a WPF dispatcher for every UI test (WebView2 objects belong
// to the thread that made them). Nothing here puts a window on screen: controllers run with OnScreen = false
// (windows far off-screen, never topmost, never activated, no keyboard hook, no re-assert).

using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using GoPray.App.Shield;
using GoPray.Core;

namespace GoPray.App.Tests;

internal static class Ui
{
    static readonly Dispatcher D;

    static Ui()
    {
        Dispatcher? d = null;
        var ready = new ManualResetEventSlim();
        var t = new Thread(() =>
        {
            d = Dispatcher.CurrentDispatcher;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(d));
            ready.Set();
            Dispatcher.Run();
        }) { IsBackground = true, Name = "ui-tests" };
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        ready.Wait();
        D = d!;
    }

    /// <summary>A CI runner (GitHub Actions: a cold, loaded VM). There, and only there, wall-clock UPPER bounds
    /// and waits are doubled. Lower bounds ("never before ~3.9 s") and the product's own timers never change.</summary>
    public static readonly bool CI = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CI")) || !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("GITHUB_ACTIONS"));
    public static double Slack => CI ? 2.0 : 1.0;
    /// <summary>An upper bound in ms: as written locally, doubled on CI.</summary>
    public static long Upper(long ms) => (long)(ms * Slack);

    public static void Run(Func<Task> body, int timeoutSeconds = 60)
    {
        var task = D.InvokeAsync(body).Task.Unwrap();
        if (!task.Wait(TimeSpan.FromSeconds(timeoutSeconds * Slack))) throw new TimeoutException("UI test timed out");
        task.GetAwaiter().GetResult();
    }

    /// <summary>Waits up to `seconds` (times Slack on CI) for the condition.</summary>
    public static async Task<bool> Until(double seconds, Func<bool> cond)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds * Slack);
        while (DateTime.UtcNow < end) { if (cond()) return true; await Task.Delay(25); }
        return cond();
    }

    public static async Task<bool> UntilAsync(double seconds, Func<Task<bool>> cond)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds * Slack);
        while (DateTime.UtcNow < end) { if (await cond()) return true; await Task.Delay(50); }
        return await cond();
    }
}

internal sealed class SpyDelegate : IShieldDelegate
{
    public int Confirms, Silences, Emergencies;
    public Action? OnConfirm;
    public void ShieldDidRequestConfirm() { Confirms++; OnConfirm?.Invoke(); }
    public void ShieldDidRequestSilence() => Silences++;
    public void ShieldDidRequestEmergencyExit() => Emergencies++;
}

internal static class Fixture
{
    public static readonly string UserData = Path.Combine(Path.GetTempPath(), "gopray-app-tests-webview2");
    /// <summary>Keep off-screen views rendering like visible ones (no occlusion or background throttling).</summary>
    public const string BrowserArgs = "--disable-features=CalculateNativeWinOcclusion --disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows";

    /// <summary>The virtual-host mapping is shared by every view of one WebView2 profile, so a view over a different
    /// scenes folder must not share the profile of the bundled-scenes views (found: a scratch-folder test made the next
    /// test's pages resolve to the empty folder). The app maps exactly one folder, so it has one profile.</summary>
    public static SceneWebView.Options Web(bool block = true, string? scenesRoot = null) => new()
    {
        UserDataFolder = scenesRoot == null || scenesRoot == SceneWebView.BundledScenesRoot ? UserData : UserData + "-" + Path.GetFileName(scenesRoot),
        BrowserArguments = BrowserArgs,
        BlockForeignRequests = block,
    };

    public static ShieldContext Ctx(Prayer prayer = Prayer.Dhuhr, BlockMode mode = BlockMode.WholeScreen, int remainingMs = 600_000,
                                    int athanMs = 0, bool reduce = false, string? app = null, int lockSeconds = 0) =>
        new() { Prayer = prayer, Mode = mode, RemainingMs = remainingMs, AthanRemainingMs = athanMs, ReduceMotion = reduce, HiddenAppName = app, LockSeconds = lockSeconds };

    public static Display D(string id, int x = 0, int w = 1440, int h = 900) => new(id, x, 0, w, h);

    public static ShieldController Controller(IReadOnlyList<Display>? displays = null, string? scenesRoot = null, bool block = true)
    {
        var list = displays ?? [D("1")];
        return new ShieldController(new ShieldOptions
        {
            OnScreen = false,
            InstallKeyboardGuard = false,
            Displays = () => list,
            ScenesRoot = scenesRoot ?? SceneWebView.BundledScenesRoot,
            Web = Web(block, scenesRoot),
        });
    }

    /// <summary>A scratch scenes folder with the given files.</summary>
    public static string Scratch(Dictionary<string, string> files)
    {
        var dir = Path.Combine(Path.GetTempPath(), "gopray-scenes-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        foreach (var (name, text) in files) File.WriteAllText(Path.Combine(dir, name), text);
        return dir;
    }

    public static async Task<bool> BlockBuilt(SceneWebView web) =>
        await web.Js("String(!!document.querySelector('.block .ring-time'))") == "\"true\"";

    /// <summary>ExecuteScriptAsync returns JSON; unwrap a JSON string to its text.</summary>
    public static async Task<string> Text(SceneWebView web, string js)
    {
        var r = await web.Js(js);
        return r.StartsWith('"') ? System.Text.Json.JsonSerializer.Deserialize<string>(r) ?? "" : r;
    }
}
