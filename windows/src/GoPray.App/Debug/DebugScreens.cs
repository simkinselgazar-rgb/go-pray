// DebugScreens.cs — DEBUG builds only (whole file). `GoPray.exe --debug-screens <dir>` walks the real Setup
// (typing a city, which runs one real geocoder search), the popover, Settings and Credits, and saves each
// window's own visual as a PNG. Every window is placed off-screen and never activated: no desktop content can
// be in an image, and nothing shows on the person's screen. Needs GOPRAY_DEBUG_STATE_DIR (a scratch folder).
// Launch at login is switched off before Finish, so the run creates no scheduled task.

#if DEBUG
using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using GoPray.App.UI;
using GoPray.Core;

namespace GoPray.App.Debug;

internal static class DebugScreens
{
    public static bool Wants(string[] a) => Array.IndexOf(a, "--debug-screens") >= 0;

    public static async void Run(AppHost env, string[] args, Action done)
    {
        int i = Array.IndexOf(args, "--debug-screens");
        var dir = i + 1 < args.Length ? args[i + 1] : Path.Combine(Path.GetTempPath(), "gopray-screens");
        Directory.CreateDirectory(dir);
        try
        {
            if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("GOPRAY_DEBUG_STATE_DIR"))) throw new InvalidOperationException("set GOPRAY_DEBUG_STATE_DIR");
            env.OffScreen = true;

            // Setup, step 1: a real search for "Toronto" (the only network call: Open-Meteo, like a person typing).
            env.ShowSetupForDebug();
            var setup = env.Setup!;
            var m = setup.Model;
            await Task.Delay(2500);                                    // the header still
            if (FindBox(setup) is { } box) box.Text = "Toronto"; else m.Search.QueryChanged("Toronto");   // typed, as a person would
            await m.Search.Settle();
            await Task.Delay(300);
            Save(setup, dir, "setup-1-city");
            m.PickedCity = m.Search.Results.FirstOrDefault() ?? new CityMatch("Toronto", "Ontario", "Canada", "CA", 43.6532, -79.3832);
            m.Next(); setup.Refresh(); await Task.Delay(400);
            Save(setup, dir, "setup-2-method");
            m.Next(); setup.Refresh(); await Task.Delay(400);
            Save(setup, dir, "setup-3-mode");
            m.LaunchAtLogin = false;                                   // no scheduled task from a screenshot run
            m.Next(); setup.Refresh(); await Task.Delay(2500);         // Finish; the header follows the next prayer
            Save(setup, dir, "setup-4-done");
            setup.Close();

            // Popover
            var pop = env.Popover!;
            pop.Left = -20000; pop.Top = -20000; pop.ShowActivated = false;   // not -32000: Win32's "minimised" spot
            pop.Show();
            pop.Render();
            await Task.Delay(3000);
            pop.Render();
            await Task.Delay(300);
            CoreLog.Notice($"DEBUG popover visible={pop.IsVisible} size={pop.ActualWidth}x{pop.ActualHeight} Width={pop.Width} stc={pop.SizeToContent} min={pop.MinWidth} content={((FrameworkElement)pop.Content).ActualWidth}");
            Save(pop, dir, "popover");
            pop.Hide();

            // Settings (the whole scrolling form) and Credits
            env.ShowSettingsForDebug();
            await Task.Delay(500);
            SaveScrolled(env.SettingsView!, dir, "settings");
            env.ShowCreditsForDebug();
            await Task.Delay(400);
            SaveScrolled(env.CreditsView!, dir, "credits");
            CoreLog.Notice("DEBUG screens saved to " + dir);
        }
        catch (Exception e) { CoreLog.Error("DEBUG screens failed: " + e); File.WriteAllText(Path.Combine(dir, "error.txt"), e.ToString()); }
        done();
    }

    static TextBox? FindBox(DependencyObject o)
    {
        if (o is TextBox t) return t;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(o); i++) if (FindBox(VisualTreeHelper.GetChild(o, i)) is { } f) return f;
        return null;
    }

    static double Scale(Visual v) => PresentationSource.FromVisual(v)?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;

    static void Save(Window w, string dir, string name)
    {
        w.UpdateLayout();
        double s = Scale(w);
        var rtb = new RenderTargetBitmap((int)Math.Ceiling(w.ActualWidth * s), (int)Math.Ceiling(w.ActualHeight * s), 96 * s, 96 * s, PixelFormats.Pbgra32);
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            dc.DrawRectangle(w.Background ?? Brushes.White, null, new Rect(0, 0, w.ActualWidth, w.ActualHeight));
            dc.DrawRectangle(new VisualBrush((Visual)w.Content) { Stretch = Stretch.None, AlignmentX = AlignmentX.Left, AlignmentY = AlignmentY.Top }, null,
                             new Rect(0, 0, ((FrameworkElement)w.Content).ActualWidth, ((FrameworkElement)w.Content).ActualHeight));
        }
        rtb.Render(dv);
        Write(rtb, dir, name);
    }

    /// <summary>A window whose content is a ScrollViewer: render the whole inner content, not just the visible part.</summary>
    static void SaveScrolled(Window w, string dir, string name)
    {
        w.UpdateLayout();
        var inner = (FrameworkElement)((ScrollViewer)w.Content).Content;
        inner.Measure(new Size(inner.ActualWidth, double.PositiveInfinity));
        double width = inner.ActualWidth, height = inner.DesiredSize.Height;
        double s = Scale(w);
        var rtb = new RenderTargetBitmap((int)Math.Ceiling(width * s), (int)Math.Ceiling(height * s), 96 * s, 96 * s, PixelFormats.Pbgra32);
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            dc.DrawRectangle(w.Background ?? Brushes.White, null, new Rect(0, 0, width, height));
            inner.Arrange(new Rect(0, 0, width, height));
            dc.DrawRectangle(new VisualBrush(inner) { Stretch = Stretch.None, AlignmentX = AlignmentX.Left, AlignmentY = AlignmentY.Top }, null, new Rect(0, 0, width, height));
        }
        rtb.Render(dv);
        Write(rtb, dir, name);
    }

    static void Write(BitmapSource b, string dir, string name)
    {
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(b));
        using var fs = File.Create(Path.Combine(dir, name + ".png"));
        enc.Save(fs);
    }
}
#endif
