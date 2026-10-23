// Displays.cs — the monitors, in device pixels (the app is PerMonitorV2-aware), primary first.

using System.Collections.Generic;
using System.Linq;
using WinForms = System.Windows.Forms;

namespace GoPray.App.Shield;

internal readonly record struct Display(string Id, int X, int Y, int Width, int Height);

internal static class Displays
{
    public static IReadOnlyList<Display> Live() =>
        WinForms.Screen.AllScreens.OrderByDescending(s => s.Primary)
            .Select(s => new Display(s.DeviceName, s.Bounds.X, s.Bounds.Y, s.Bounds.Width, s.Bounds.Height)).ToList();

    /// <summary>Coding-apps notice: 420 x 520 (device-independent) centred on the primary display.</summary>
    public const double NoticeWidth = 420, NoticeHeight = 520;

    public static Display NoticeFrame(Display primary, double scale)
    {
        int w = (int)System.Math.Round(NoticeWidth * scale), h = (int)System.Math.Round(NoticeHeight * scale);
        return new Display(primary.Id, primary.X + (primary.Width - w) / 2, primary.Y + (primary.Height - h) / 2, w, h);
    }
}
