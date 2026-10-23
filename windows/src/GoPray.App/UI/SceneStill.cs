// SceneStill.cs — a painted still of a prayer's scene for the popover and Setup headers (spec: 320 x 96,
// one frame, no motion). Port of UI/SceneStill.swift: one snapshot of the real scene page (reduce-motion
// path, art layout, no UI), cropped around each scene's subject with the Mac's per-prayer frames, cached as
// a PNG in %LOCALAPPDATA%\GoPray\stills so it is painted once per app version. No image ships with the app.
// Loading follows the spec: the prayer's ground colour is the skeleton and the still fades in over it.

using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using GoPray.App.Shield;
using GoPray.Core;

namespace GoPray.App.UI;

internal sealed class SceneStillRenderer
{
    public static SceneStillRenderer Shared { get; } = new();

    public string CacheDirectory { get; }
    readonly Dictionary<string, Task<BitmapSource?>> _inFlight = [];
    readonly string _scenes;
    readonly SceneWebView.Options _web;

    public SceneStillRenderer(string? cacheDirectory = null, string? scenesRoot = null)
    {
        CacheDirectory = cacheDirectory ?? Path.Combine(StateStore.DefaultDirectory(), "stills");
        _scenes = scenesRoot ?? SceneWebView.BundledScenesRoot;
        // Its own profile: off-screen rendering needs Chromium's occlusion off, and one profile has one option set.
        _web = new SceneWebView.Options
        {
            UserDataFolder = Path.Combine(StateStore.DefaultDirectory(), "WebView2-stills"),
            BrowserArguments = "--disable-features=CalculateNativeWinOcclusion --disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows",
        };
    }

    static string Version => Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "0";

    public string CachePath(Prayer p, Size size, double scale) =>
        Path.Combine(CacheDirectory, $"{p.ToString().ToLowerInvariant()}-{(int)size.Width}x{(int)size.Height}@{scale:0.##}x-v{Version}.png");

    /// <summary>Where each scene's art sits in its 1600 x 1000 virtual space (SceneStill.swift `frames`).</summary>
    public static readonly IReadOnlyDictionary<Prayer, (double X, double Y, double Width)> Frames = new Dictionary<Prayer, (double, double, double)>
    {
        [Prayer.Fajr] = (1150, 400, 700),     // the window light
        [Prayer.Dhuhr] = (1180, 640, 680),    // dome + minaret
        [Prayer.Asr] = (862, 560, 640),       // dome through the arches + lanterns
        [Prayer.Maghrib] = (1250, 480, 900),  // dome + minaret + sun
        [Prayer.Isha] = (1080, 566, 700),     // Kaaba + mataf lights
    };

    /// <summary>The page size and the crop of it for a band, in page units (SceneStill.swift `crop`).</summary>
    public static (Size Page, Rect Crop) Crop(Prayer p, Size band)
    {
        var f = Frames.TryGetValue(p, out var v) ? v : (800, 500, 800);
        double cw = f.Width * (band.Width > 400 ? 1.35 : 1);
        double s = band.Width / cw;
        var page = new Size(1600 * s, 1000 * s);
        double ch = band.Height / s;
        double cx = Math.Min(Math.Max(f.X, cw / 2), 1600 - cw / 2);
        double cy = Math.Min(Math.Max(f.Y, ch / 2), 1000 - ch / 2);
        return (page, new Rect((cx - cw / 2) * s, (cy - ch / 2) * s, band.Width, band.Height));
    }

    /// <summary>The still, from the cache or painted now. Never throws; null = keep showing the ground colour.</summary>
    public Task<BitmapSource?> Image(Prayer p, Size size, double scale)
    {
        var path = CachePath(p, size, scale);
        if (File.Exists(path))
        {
            try { return Task.FromResult<BitmapSource?>(Load(path)); } catch (Exception) { /* repaint */ }
        }
        if (_inFlight.TryGetValue(path, out var t)) return t;
        t = PaintAndStore(p, size, scale, path);
        _inFlight[path] = t;
        return t;
    }

    static BitmapSource Load(string path)
    {
        var bi = new BitmapImage();
        bi.BeginInit();
        bi.CacheOption = BitmapCacheOption.OnLoad;
        bi.UriSource = new Uri(path);
        bi.EndInit();
        bi.Freeze();
        return bi;
    }

    async Task<BitmapSource?> PaintAndStore(Prayer p, Size size, double scale, string path)
    {
        try
        {
            var img = await Paint(p, size, scale);
            if (img != null)
            {
                Directory.CreateDirectory(CacheDirectory);
                var enc = new PngBitmapEncoder();
                enc.Frames.Add(BitmapFrame.Create(img));
                using var fs = File.Create(path);
                enc.Save(fs);
            }
            return img;
        }
        catch (Exception e) { CoreLog.Error("still not painted: " + e.Message); return null; }
        finally { _inFlight.Remove(path); }
    }

    async Task<BitmapSource?> Paint(Prayer p, Size size, double scale)
    {
        var (page, crop) = Crop(p, size);
        var web = new SceneWebView(_scenes, ShieldPalette.Of(p).Ground, _web);
        // Off-screen, never activated, never in the taskbar: it shows the person nothing.
        var win = new Window
        {
            Left = -32000, Top = -32000, Width = page.Width, Height = page.Height, WindowStyle = WindowStyle.None,
            ShowActivated = false, ShowInTaskbar = false, ResizeMode = ResizeMode.NoResize, Content = web.View,
        };
        win.Show();
        try
        {
            bool ready = false;
            web.OnMessage = m => { if (m == BridgeMessage.Ready) ready = true; };
            web.Load($"prayer={p.ToString().ToLowerInvariant()}&layout=art&reduce=1&ms=600000");
            if (!await Until(6, () => ready)) return null;
            const string painted = "(function(){ const s = document.getElementById('scene'); if (!s) return ''; return getComputedStyle(s).opacity === '1' ? (s.dataset.state || '') : ''; })()";
            bool done = false;
            for (int i = 0; i < 50 && !done; i++)
            {
                var r = await web.Js(painted);
                done = r is "\"lived\"" or "\"still\"";
                if (!done) await Task.Delay(100);
            }
            if (!done) return null;
            await Task.Delay(400);                       // the 200 ms crossfade of the still path
            using var ms = new MemoryStream();
            if (!await web.CapturePng(ms)) return null;
            ms.Position = 0;
            var full = BitmapFrame.Create(ms, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            double k = full.PixelWidth / page.Width;     // device pixels per page unit (the window's DPI)
            var rect = new Int32Rect((int)Math.Round(crop.X * k), (int)Math.Round(crop.Y * k),
                                     Math.Min(full.PixelWidth, (int)Math.Round(crop.Width * k)), Math.Min(full.PixelHeight, (int)Math.Round(crop.Height * k)));
            rect.X = Math.Clamp(rect.X, 0, full.PixelWidth - rect.Width);
            rect.Y = Math.Clamp(rect.Y, 0, full.PixelHeight - rect.Height);
            var cut = new CroppedBitmap(full, rect);
            var scaled = new TransformedBitmap(cut, new ScaleTransform(size.Width * scale / rect.Width, size.Height * scale / rect.Height));
            var frozen = new WriteableBitmap(scaled);
            frozen.Freeze();
            return frozen;
        }
        finally
        {
            web.ShutDown();
            win.Close();
        }
    }

    static async Task<bool> Until(double seconds, Func<bool> cond)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < end) { if (cond()) return true; await Task.Delay(25); }
        return cond();
    }
}

/// <summary>The prayer's ground colour in the exact frame the still fills (the skeleton), the still fades in over it.</summary>
internal sealed class SceneBand : Border
{
    readonly Image _image = new() { Stretch = Stretch.UniformToFill, Opacity = 0 };
    Prayer? _shown;

    public SceneBand(double width, double height)
    {
        Width = width;
        Height = height;
        ClipToBounds = true;
        Child = _image;
        Focusable = false;   // decorative: the header text says which prayer it is
    }

    public async void Show(Prayer p)
    {
        if (_shown == p) return;
        _shown = p;
        Background = new SolidColorBrush(ShieldPalette.Of(p).Ground);
        _image.Opacity = 0;
        _image.Source = null;
        double scale = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformToDevice.M11 ?? 1.25;
        var img = await SceneStillRenderer.Shared.Image(p, new Size(Width, Height), scale);
        if (img == null || _shown != p) return;
        _image.Source = img;
        _image.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(200)));
    }
}
