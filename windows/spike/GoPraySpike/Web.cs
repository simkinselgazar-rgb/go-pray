using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace GoPraySpike;

// Q4: shield.html via a virtual host (Deny), webkit -> chrome.webview shim injected before page scripts,
// prayed message round trip, GoPrayBridge.show via ExecuteScriptAsync, CSP violations count.
// A normal (not topmost) 1000x650 window; closes itself after 20 s.
static class WebMode
{
    const string Host = "gopray.invalid";
    const string Shim = "window.webkit = { messageHandlers: { gopray: { postMessage: function (m) { window.chrome.webview.postMessage(m); } } } };";

    public static void Run(string[] a)
    {
        Log.Open("q4-webview");
        var scenes = Program.StrArg(a, "--scenes", "");
        var outDir = Environment.GetEnvironmentVariable("GOPRAY_SPIKE_EVIDENCE") ?? AppContext.BaseDirectory;
        Log.W($"scenes={scenes} exists={File.Exists(Path.Combine(scenes, "shield.html"))}");
        new Thread(() => { Thread.Sleep(24000); Log.W("WATCHDOG exit"); Environment.Exit(0); }) { IsBackground = true }.Start();
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var wv = new WebView2();
        var w = new Window { Title = "GOPRAY-SPIKE-WEBVIEW", Width = 1000, Height = 650, Left = 60, Top = 40, Content = wv };
        string pageUrl = $"https://{Host}/shield.html";
        var msgs = new System.Collections.Generic.List<string>();
        var ready = new TaskCompletionSource();

        async Task Go()
        {
            try { Log.W($"runtime={CoreWebView2Environment.GetAvailableBrowserVersionString()}"); }
            catch (Exception e) { Log.W("runtime MISSING " + e.Message); }
            var env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(Path.GetTempPath(), "GoPraySpike-WV2"));
            await wv.EnsureCoreWebView2Async(env);
            var core = wv.CoreWebView2;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.SetVirtualHostNameToFolderMapping(Host, scenes, CoreWebView2HostResourceAccessKind.Deny);
            var sid = await core.AddScriptToExecuteOnDocumentCreatedAsync(Shim);
            Log.W($"shim injected id={sid}");
            core.NavigationStarting += (_, e) =>
            {
                bool okUrl = e.Uri.StartsWith($"https://{Host}/");
                Log.W($"NavigationStarting {e.Uri} allowed={okUrl}");
                if (!okUrl) e.Cancel = true;
            };
            core.NewWindowRequested += (_, e) => { e.Handled = true; Log.W("NewWindowRequested blocked " + e.Uri); };
            core.WebMessageReceived += (_, e) =>
            {
                string body = e.WebMessageAsJson;
                bool srcOk = e.Source == pageUrl || e.Source.StartsWith(pageUrl + "?");
                Log.W($"WebMessageReceived source={e.Source} sourceOk={srcOk} json={body}");
                try
                {
                    using var d = JsonDocument.Parse(body);
                    var t = d.RootElement.GetProperty("type").GetString();
                    msgs.Add(t!);
                    if (t == "ready") ready.TrySetResult();
                }
                catch (Exception ex) { Log.W("bad message " + ex.Message); }
            };
            core.ProcessFailed += (_, e) => Log.W("ProcessFailed " + e.ProcessFailedKind);
            core.NavigationCompleted += (_, e) => Log.W($"NavigationCompleted ok={e.IsSuccess} status={e.WebErrorStatus}");
            core.Navigate(pageUrl);
            var r = await Task.WhenAny(ready.Task, Task.Delay(4000));
            Log.W($"ready within 4 s = {ready.Task.IsCompleted}");
            async Task<string> Js(string s) { var v = await core.ExecuteScriptAsync(s); Log.W($"js `{s}` => {v}"); return v; }
            await Js("typeof window.webkit.messageHandlers.gopray.postMessage");
            await Js("typeof window.GoPrayBridge");
            await Js("GoPrayBridge.violations()");
            var ctx = JsonSerializer.Serialize(new { prayer = "dhuhr", layout = "full", reduceMotion = false, remainingMs = 8000, lockMs = 8000, athanRemainingMs = 0, hiddenAppName = "" });
            await Js($"GoPrayBridge.show({ctx})");
            await Task.Delay(3000);
            await Js("(function(){var b=document.querySelector('.prayed');return b?('disabled='+b.disabled):'no button'})()");
            await TrustedClick(core, Js);   // before unlock: the page must not post 'prayed'
            await Task.Delay(800);
            Log.W($"messages so far: {string.Join(",", msgs)}");
            await Task.Delay(6000);
            await Js("(function(){var b=document.querySelector('.prayed');return b?('disabled='+b.disabled):'no button'})()");
            using (var fs = File.Create(Path.Combine(outDir, "q4-webview-unlocked.png")))
                await core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, fs);
            await TrustedClick(core, Js);   // after unlock: expect 'prayed'
            await Task.Delay(1000);
            Log.W($"messages after click: {string.Join(",", msgs)}  prayedCount={msgs.Count(m => m == "prayed")}");
            await Js("GoPrayBridge.violations()");
            // negative control: an inline <script> added by the page must be blocked by the CSP
            await Js("(function(){var s=document.createElement('script');s.textContent='window.__inline=1';document.body.appendChild(s);return 'added'})()");
            await Task.Delay(300);
            await Js("String(window.__inline)");
            await Js("GoPrayBridge.violations()");
            // a page-script navigation to the network must be cancelled
            await Js("location.href='https://example.com/'; 'nav'");
            await Task.Delay(800);
            await Js("location.href");
        }

        async Task TrustedClick(CoreWebView2 core, Func<string, Task<string>> js)
        {
            var rect = await js("(function(){var r=document.querySelector('.prayed').getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()");
            using var d = JsonDocument.Parse(JsonDocument.Parse(rect).RootElement.GetString()!);
            double x = d.RootElement.GetProperty("x").GetDouble(), y = d.RootElement.GetProperty("y").GetDouble();
            foreach (var type in new[] { "mousePressed", "mouseReleased" })
                await core.CallDevToolsProtocolMethodAsync("Input.dispatchMouseEvent",
                    JsonSerializer.Serialize(new { type, x, y, button = "left", clickCount = 1 }));
            Log.W($"trusted (CDP) click at {x:0},{y:0}");
        }

        w.Loaded += async (_, _) =>
        {
            try { await Go(); } catch (Exception e) { Log.W("ERROR " + e); }
            Log.W("web done");
            app.Shutdown();
        };
        w.Show();
        app.Run();
    }
}

