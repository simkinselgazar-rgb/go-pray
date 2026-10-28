// PopoverUpdateTests.cs — 0.3.6 (Ahmed, 2026-10-28): "Check for updates…" in the left-click popover, not only in the
// tray's right-click menu. Same UpdateChecker.CheckNow, the checker's states in place, disabled during a block.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using GoPray.App.Update;
using GoPray.App.UI;
using GoPray.Core;
using Xunit;

namespace GoPray.App.Tests;

public class PopoverUpdateTests : IDisposable
{
    readonly string _dir = Path.Combine(Path.GetTempPath(), "gopray-popover-" + Guid.NewGuid().ToString("N"));
    public void Dispose() { try { Directory.Delete(_dir, true); } catch { } }

    sealed class OfflineTransport : IUpdateTransport
    {
        public int Gets;
        public Task<string> GetText(Uri url, CancellationToken c) { Gets++; throw new HttpRequestException("offline"); }
        public Task Download(Uri url, string path, long max, CancellationToken c) => throw new HttpRequestException("offline");
    }

    static readonly DateTime asr = GoPray.Core.Tests.FakeSchedule.At(Prayer.Asr);

    sealed class Rig : IDisposable
    {
        public GoPray.Core.Tests.Harness H = null!;
        public UpdateChecker U = null!;
        public PopoverWindow W = null!;
        public void Dispose() { W.Close(); H.Dispose(); }
    }

    Rig Make(IUpdateTransport t, DateTime now)
    {
        var rig = new Rig { H = new GoPray.Core.Tests.Harness(now, SettingsRules.Defaults) };
        var h = rig.H;
        var store = new SettingsStore(Path.Combine(_dir, "settings"));
        store.Attach(h.Gate);
        store.Mutate(_ => GoPray.Core.Tests.TestSettings.Test());
        h.Settings = store.Settings;
        store.OnChange = s => h.Settings = s;
        rig.U = new UpdateChecker(new Version(0, 3, 6), _dir, () => h.Gate.IsBlocked, () => true, h.Clock, _ => { }, t, new FakeVerifier(true));
        rig.W = new PopoverWindow(new MenuModel(store, h.Gate, h.Schedule, h.Clock, () => TimeZoneInfo.Utc), () => { }, () => { }, () => { }, rig.U);
        rig.W.Render();
        return rig;
    }

    static IEnumerable<object> Tree(object o)
    {
        yield return o;
        if (o is DependencyObject d)
            foreach (var c in LogicalTreeHelper.GetChildren(d)) foreach (var x in Tree(c)) yield return x;
    }

    static List<string> Texts(Window w) => Tree(w).OfType<TextBlock>().Select(t => t.Text).ToList();

    static Button? CheckButton(Window w) =>
        Tree(w).OfType<Button>().FirstOrDefault(b => b.Content is TextBlock { Text: PopoverWindow.CheckForUpdatesLabel });

    static void Click(Button b) => b.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));

    [Fact]
    public void thePopoverHasCheckForUpdatesAndItCallsCheckNow() => Ui.Run(async () =>
    {
        var t = new FakeTransport { Releases = "[]" };
        using var r = Make(t, asr.AddHours(1));
        var b = CheckButton(r.W);
        Assert.NotNull(b);
        Assert.True(b!.IsEnabled);
        Assert.Equal("Check for updates…", PopoverWindow.CheckForUpdatesLabel);
        Click(b);
        Assert.True(await Ui.Until(4, () => r.U.Status == UpdateStatus.UpToDate));
        Assert.Single(t.Gets);                                                    // one manual check reached the network
        Assert.Equal(1, r.U.Requests);
        r.W.Render();
        Assert.Contains("You're up to date.", Texts(r.W));
        Assert.True(CheckButton(r.W)!.IsEnabled);                                 // and it can be asked again
    });

    [Fact]
    public void anUpdateShowsDownloadInPlace() => Ui.Run(async () =>
    {
        const string dl = "https://github.com/simkinselgazar-rgb/go-pray/releases/download/win-v0.4.0/";
        var t = new FakeTransport
        {
            Releases = $$"""
            [{ "tag_name": "win-v0.4.0", "draft": false, "prerelease": false,
               "assets": [ { "name": "GoPray-Setup-0.4.0.exe", "size": 65000000, "browser_download_url": "{{dl}}GoPray-Setup-0.4.0.exe" },
                           { "name": "GoPray-Setup-0.4.0.exe.sha256", "size": 90, "browser_download_url": "{{dl}}GoPray-Setup-0.4.0.exe.sha256" } ] }]
            """,
        };
        using var r = Make(t, asr.AddHours(1));
        Click(CheckButton(r.W)!);
        Assert.True(await Ui.Until(4, () => r.U.Status == UpdateStatus.Available));
        r.W.Render();
        Assert.Contains("Update available: 0.4.0 — Download", Texts(r.W));
        Assert.Null(CheckButton(r.W));                                             // the Download link takes its place
    });

    [Fact]
    public void anOfflineCheckSaysSoInPlace() => Ui.Run(async () =>
    {
        var t = new OfflineTransport();
        using var r = Make(t, asr.AddHours(1));
        Click(CheckButton(r.W)!);
        Assert.True(await Ui.Until(4, () => r.U.Status == UpdateStatus.Failed));
        r.W.Render();
        var texts = Texts(r.W);
        Assert.Contains("Couldn't reach GitHub. Try later.", texts);
        Assert.Contains("Open the releases page", texts);
        Assert.True(CheckButton(r.W)!.IsEnabled);
        Assert.Equal(1, t.Gets);
    });

    [Fact]
    public void checkForUpdatesIsDisabledDuringABlock() => Ui.Run(async () =>
    {
        var t = new FakeTransport { Releases = "[]" };
        using var r = Make(t, asr);
        r.H.Gate.AthanFired(Prayer.Asr, asr);
        Assert.True(r.H.Gate.IsBlocked);
        r.W.Render();
        var b = CheckButton(r.W);
        Assert.NotNull(b);
        Assert.False(b!.IsEnabled);
        await r.U.CheckNow();                                                     // the checker refuses too
        Assert.Empty(t.Gets);
        Assert.Equal(UpdateStatus.Idle, r.U.Status);
    });
}
