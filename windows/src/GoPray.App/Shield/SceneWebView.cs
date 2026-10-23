// SceneWebView.cs — the locked-down WebView2 that shows the approved scenes. Port of Shield/SceneWebView.swift.
// Architecture Plan §G "web view lockdown". This is the ONLY file that builds a WebView2, loads a page,
// runs script or receives page messages (guard rule 5).
//
// - shield.html is served from the scenes folder through ONE virtual host, https://gopray.invalid/,
//   access kind Deny (no file:// at all). The page's own CSP (script-src 'self', connect-src 'none', …) holds.
// - Defence in depth: every request that is not for the virtual host is answered 403 by the host
//   (WebResourceRequested), so even a page without the CSP reaches nothing.
// - One navigation is allowed: the one we start. Everything else is cancelled (links, forms, location=,
//   reload, iframes, popups). No dialogs, downloads, permissions, context menu, accelerator keys
//   (F5, Ctrl+R, Ctrl+P…), zoom, swipe, status bar, autofill, dropped files. InPrivate profile.
// - bridge.js and shield.html stay byte-identical: a host script injected before any page script defines
//   window.webkit.messageHandlers.gopray.postMessage → chrome.webview.postMessage (spike Q4: it runs
//   under the page CSP, which applies to page scripts only).
// - One message channel, four validated names, and only from our page's URL.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using GoPray.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace GoPray.App.Shield;

internal sealed class SceneWebView
{
    public const string Host = "gopray.invalid";
    public const string Origin = "https://" + Host + "/";
    const string Shim = "window.webkit = Object.freeze({ messageHandlers: Object.freeze({ gopray: Object.freeze({ postMessage: function (m) { window.chrome.webview.postMessage(m); } }) }) });";

    public sealed record Options
    {
        /// <summary>%LOCALAPPDATA%\GoPray\WebView2 in the app; a temp folder in tests.</summary>
        public string UserDataFolder { get; init; } = Path.Combine(StateStore.DefaultDirectory(), "WebView2");
        /// <summary>Answer 403 to anything not on the virtual host (on in the app; tests turn it off for a negative control).</summary>
        public bool BlockForeignRequests { get; init; } = true;
        /// <summary>Extra Chromium switches (tests: keep off-screen views rendering).</summary>
        public string? BrowserArguments { get; init; }
    }

    /// <summary>&lt;app&gt;\Resources\scenes, filled at build by sync-assets.ps1 and verified by check-manifest.ps1.</summary>
    public static string BundledScenesRoot => Path.Combine(AppContext.BaseDirectory, "Resources", "scenes");

    static readonly Dictionary<string, Task<CoreWebView2Environment>> Environments = [];

    public string ScenesRoot { get; }
    public FrameworkElement View => _view;
    public Action<BridgeMessage>? OnMessage { get; set; }
    public Action<string>? OnFailure { get; set; }
    public Action? OnNavigationFinished { get; set; }

    // What the lockdown refused, for tests and logs.
    public List<string> DroppedMessages { get; } = [];
    public List<string> BlockedNavigations { get; } = [];
    public List<string> BlockedRequests { get; } = [];
    public int BlockedPopups { get; private set; }

    readonly WebView2 _view;
    readonly Options _options;
    CoreWebView2? _core;
    string? _expectedNavigation;
    string? _pageUrl;
    ulong? _ourNavigationId;
    bool _shut;
    readonly Task _ready;

    public SceneWebView(string scenesRoot, Color underPage, Options? options = null)
    {
        ScenesRoot = Path.GetFullPath(scenesRoot);
        _options = options ?? new Options();
        _view = new WebView2
        {
            DefaultBackgroundColor = System.Drawing.Color.FromArgb(underPage.A, underPage.R, underPage.G, underPage.B),
            AllowExternalDrop = false,
            Focusable = false,
        };
        _ready = InitAsync();
    }

    async Task InitAsync()
    {
        try
        {
            CoreWebView2Environment.GetAvailableBrowserVersionString();   // throws when the runtime is missing
            var env = await EnvironmentFor(_options);
            var co = env.CreateCoreWebView2ControllerOptions();
            co.IsInPrivateModeEnabled = true;
            await _view.EnsureCoreWebView2Async(env, co);
            if (_shut) return;
            var core = _view.CoreWebView2;
            _core = core;
            var s = core.Settings;
            s.AreDefaultContextMenusEnabled = false;
            s.AreDefaultScriptDialogsEnabled = false;
            s.AreBrowserAcceleratorKeysEnabled = false;
            s.AreHostObjectsAllowed = false;
            s.IsBuiltInErrorPageEnabled = false;
            s.IsGeneralAutofillEnabled = false;
            s.IsPasswordAutosaveEnabled = false;
            s.IsPinchZoomEnabled = false;
            s.IsStatusBarEnabled = false;
            s.IsSwipeNavigationEnabled = false;
            s.IsZoomControlEnabled = false;
            s.IsWebMessageEnabled = true;
            s.AreDevToolsEnabled = false;
#if DEBUG
            s.AreDevToolsEnabled = true;
#endif
            core.SetVirtualHostNameToFolderMapping(Host, ScenesRoot, CoreWebView2HostResourceAccessKind.Deny);
            await core.AddScriptToExecuteOnDocumentCreatedAsync(Shim);
            core.NavigationStarting += OnNavigationStarting;
            core.FrameNavigationStarting += (_, e) => { e.Cancel = true; BlockedNavigations.Add("frame:" + e.Uri); };
            core.NewWindowRequested += (_, e) => { e.Handled = true; BlockedPopups++; };
            core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
            core.DownloadStarting += (_, e) => e.Cancel = true;
            core.ContextMenuRequested += (_, e) => e.Handled = true;
            core.ScriptDialogOpening += (_, _) => { };              // not accepted = dismissed
            core.ProcessFailed += (_, e) => Fail("processFailed:" + e.ProcessFailedKind);
            core.NavigationCompleted += OnNavigationCompleted;
            core.WebMessageReceived += OnWebMessage;
            if (_options.BlockForeignRequests)
            {
                core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
                core.WebResourceRequested += (_, e) =>
                {
                    var uri = e.Request.Uri;
                    if (uri.StartsWith(Origin, StringComparison.OrdinalIgnoreCase)) return;   // the virtual host serves it
                    BlockedRequests.Add(uri);
                    e.Response = env.CreateWebResourceResponse(null, 403, "Blocked", "");
                };
            }
            if (_pageUrl != null) core.Navigate(_pageUrl);
        }
        catch (Exception e)
        {
            Fail("init:" + e.GetType().Name);
        }
    }

    static Task<CoreWebView2Environment> EnvironmentFor(Options o)
    {
        var key = o.UserDataFolder + "|" + o.BrowserArguments;
        lock (Environments)
        {
            if (!Environments.TryGetValue(key, out var t))
            {
                var eo = new CoreWebView2EnvironmentOptions { AdditionalBrowserArguments = o.BrowserArguments ?? "" };
                t = CoreWebView2Environment.CreateAsync(null, o.UserDataFolder, eo);
                Environments[key] = t;
            }
            return t;
        }
    }

    // MARK: Loading

    /// <summary><paramref name="query"/> has no leading "?".</summary>
    public void Load(string query = "", string page = "shield.html")
    {
        _pageUrl = Origin + page + (query.Length > 0 ? "?" + query : "");
        _expectedNavigation = _pageUrl;
        _core?.Navigate(_pageUrl);
    }

    /// <summary>Stop everything and drop every callback. Safe to call twice.</summary>
    public void ShutDown()
    {
        if (_shut) return;
        _shut = true;
        OnMessage = null; OnFailure = null; OnNavigationFinished = null;
        try { _core?.Stop(); } catch (Exception) { /* already gone */ }
        try { _view.Dispose(); } catch (Exception) { /* already gone */ }
        _core = null;
    }

    // MARK: Host -> JS (the only script calls in the app)

    public void Show(BridgePayload payload) => Run(payload.ShowScript());
    public void AthanStopped() => Run("GoPrayBridge.athanStopped()");
    public void DismissPage() => Run("GoPrayBridge.dismiss()");

    async void Run(string script)
    {
        try
        {
            await _ready;
            if (_core == null || _shut) return;
            await _core.ExecuteScriptAsync(script);
        }
        catch (Exception e)
        {
            Fail("scriptFailed:" + e.GetType().Name);
        }
    }

    /// <summary>Runs JS and returns its JSON result ("ERR: …" if it throws). Tests and the debug harness.</summary>
    internal async Task<string> Js(string script)
    {
        try
        {
            await _ready;
            if (_core == null) return "ERR: no core";
            return await _core.ExecuteScriptAsync(script);
        }
        catch (Exception e) { return "ERR: " + e.Message; }
    }

    /// <summary>The ids of this environment's renderer processes (tests kill them to prove the fallback).</summary>
    internal async Task<int[]> RendererProcessIds()
    {
        await _ready;
        if (_core == null) return [];
        return _core.Environment.GetProcessInfos().Where(p => p.Kind == CoreWebView2ProcessKind.Renderer).Select(p => p.ProcessId).ToArray();
    }

#if DEBUG
    /// <summary>Debug harness only: crash this view's renderer (CDP Page.crash) to show the fallback live.</summary>
    internal async Task DebugCrashRenderer()
    {
        await _ready;
        if (_core != null) { try { await _core.CallDevToolsProtocolMethodAsync("Page.crash", "{}"); } catch (Exception) { /* it crashed */ } }
    }
#endif

    // MARK: Policy

    /// <summary>A URL on the virtual host, the only place the page may come from.</summary>
    public static bool IsOurs(string? url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var u) && u.Scheme == Uri.UriSchemeHttps
        && string.Equals(u.Host, Host, StringComparison.OrdinalIgnoreCase) && u.IsDefaultPort && !u.AbsolutePath.Contains("..");

    void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs e)
    {
        if (_expectedNavigation != null && e.Uri == _expectedNavigation && IsOurs(e.Uri))
        {
            _expectedNavigation = null;
            _ourNavigationId = e.NavigationId;
            return;
        }
        e.Cancel = true;
        BlockedNavigations.Add(e.Uri);
    }

    void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (e.NavigationId != _ourNavigationId) return;          // a navigation we cancelled
        if (e.IsSuccess) OnNavigationFinished?.Invoke();
        else Fail("navigationFailed:" + e.WebErrorStatus + ":" + e.HttpStatusCode);
    }

    void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (_pageUrl == null || !IsOurs(e.Source) || !(e.Source == _pageUrl || e.Source.Split('?')[0] == _pageUrl.Split('?')[0]))
        {
            DroppedMessages.Add("untrusted-source");
            return;
        }
        string json;
        try { json = e.WebMessageAsJson; } catch (Exception) { DroppedMessages.Add("unreadable"); return; }
        if (BridgeMessages.Parse(json) is not { } msg)
        {
            DroppedMessages.Add(json.Length > 80 ? json[..80] : json);
            return;
        }
        OnMessage?.Invoke(msg);
    }

    void Fail(string why)
    {
        if (_shut) return;
        OnFailure?.Invoke(why);
    }
}
