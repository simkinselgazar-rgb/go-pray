// ShieldWindow.cs — one borderless window per monitor (or the coding notice). Port of Shield/ShieldPanel.swift.
// - Exact device-pixel bounds via SetWindowPos after the HWND exists (re-applied on a DPI change).
// - Topmost, no taskbar button, not in Alt+Tab (WS_EX_TOOLWINDOW). The notice and the art windows never
//   take focus (WS_EX_NOACTIVATE); only the main whole-screen window is activated.
// - Closing (Alt+F4, WM_CLOSE from anyone) is cancelled until the controller itself closes it.
// - The ground colour is the window background: it is up before the page is (the skeleton).
// - OnScreen = false (tests): placed far off-screen, never topmost, never activated.

using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using GoPray.App.Native;

namespace GoPray.App.Shield;

internal sealed class ShieldWindow : Window
{
    public Display Frame { get; private set; }
    public bool Activates { get; }
    public bool OnScreen { get; }
    public bool Notice { get; }
    public IntPtr Handle { get; private set; }
    bool _allowClose;

    public ShieldWindow(Display frame, Color ground, bool activates, bool onScreen, bool notice)
    {
        Frame = frame;
        Activates = activates && onScreen;
        OnScreen = onScreen;
        Notice = notice;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = Activates;
        Topmost = onScreen;
        Background = new SolidColorBrush(ground);
        Title = "Go Pray";
        WindowStartupLocation = WindowStartupLocation.Manual;
        // Rough placement in DIPs; SourceInitialized sets the exact device-pixel rectangle.
        Left = onScreen ? frame.X : -32000;
        Top = onScreen ? frame.Y : -32000;
        Width = Math.Max(1, frame.Width);
        Height = Math.Max(1, frame.Height);
        SourceInitialized += (_, _) =>
        {
            Handle = new WindowInteropHelper(this).Handle;
            HwndSource.FromHwnd(Handle)?.AddHook(WndProc);
            Win32.AddExStyle(Handle, Win32.WS_EX_TOOLWINDOW | (Activates ? 0 : Win32.WS_EX_NOACTIVATE));
            Win32.RemoveExStyle(Handle, Win32.WS_EX_APPWINDOW);
            if (notice)
            {
                int round = Win32.DWMWCP_ROUND;
                Win32.DwmSetWindowAttribute(Handle, Win32.DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));
            }
            Place();
        };
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(Place);
        Closing += OnClosing;
    }

    /// <summary>Exact bounds in device pixels (spike: SetWindowPos gave exactly the monitor's rectangle).</summary>
    public void Place()
    {
        if (Handle == IntPtr.Zero) return;
        var f = Frame;
        int x = OnScreen ? f.X : -32000 - f.Width, y = OnScreen ? f.Y : -32000 - f.Height;
        Win32.SetWindowPos(Handle, OnScreen ? Win32.HWND_TOPMOST : IntPtr.Zero, x, y, f.Width, f.Height,
                           Win32.SWP_SHOWWINDOW | (Activates ? 0 : Win32.SWP_NOACTIVATE));
    }

    /// <summary>Bring back to the top of the topmost band (no size or move).</summary>
    public void RaiseToTop()
    {
        if (Handle == IntPtr.Zero || !OnScreen) return;
        Win32.SetWindowPos(Handle, Win32.HWND_TOPMOST, 0, 0, 0, 0, Win32.SWP_NOMOVE | Win32.SWP_NOSIZE | Win32.SWP_SHOWWINDOW | Win32.SWP_NOACTIVATE);
    }

    /// <summary>WM_GETMINMAXINFO: allow exactly the monitor's size (Windows otherwise caps a window at the
    /// virtual screen plus borders, which a test display larger than the desktop hits).</summary>
    IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        const int WM_GETMINMAXINFO = 0x24;
        if (msg == WM_GETMINMAXINFO)
        {
            // MINMAXINFO: ptReserved(8) ptMaxSize(8) ptMaxPosition(8) ptMinTrackSize(8) ptMaxTrackSize(8)
            System.Runtime.InteropServices.Marshal.WriteInt32(lParam, 8, Math.Max(Frame.Width, System.Runtime.InteropServices.Marshal.ReadInt32(lParam, 8)));
            System.Runtime.InteropServices.Marshal.WriteInt32(lParam, 12, Math.Max(Frame.Height, System.Runtime.InteropServices.Marshal.ReadInt32(lParam, 12)));
            System.Runtime.InteropServices.Marshal.WriteInt32(lParam, 32, Math.Max(Frame.Width, System.Runtime.InteropServices.Marshal.ReadInt32(lParam, 32)));
            System.Runtime.InteropServices.Marshal.WriteInt32(lParam, 36, Math.Max(Frame.Height, System.Runtime.InteropServices.Marshal.ReadInt32(lParam, 36)));
            handled = true;
        }
        return IntPtr.Zero;
    }

    void OnClosing(object? sender, CancelEventArgs e)
    {
        if (!_allowClose) e.Cancel = true;     // Alt+F4 and WM_CLOSE during a block: refused
    }

    /// <summary>The controller's close. The only way this window goes away.</summary>
    public void CloseForReal()
    {
        _allowClose = true;
        Close();
    }
}
