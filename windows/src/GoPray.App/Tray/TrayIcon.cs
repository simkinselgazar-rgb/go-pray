// TrayIcon.cs — the notification-area icon (the Mac's menu bar icon). Left click opens the popover; right
// click a short menu (Open Go Pray, Settings…, Credits, Quit). The mihrab glyph switches with the taskbar
// theme (SystemUsesLightTheme: black glyph on a light taskbar, white on a dark one).

using System;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using Microsoft.Win32;

namespace GoPray.App.Tray;

internal sealed class TrayIcon : IDisposable
{
    readonly NotifyIcon _icon;
    readonly ToolStripMenuItem _quit;
    public ContextMenuStrip Menu { get; }

    public TrayIcon(Action openPopover, Action openSettings, Action openCredits, Action quit, Func<bool> isBlocked)
    {
        Menu = new ContextMenuStrip();
        Menu.Items.Add("Open Go Pray", null, (_, _) => openPopover());
        Menu.Items.Add("Settings…", null, (_, _) => openSettings());
        Menu.Items.Add("Credits", null, (_, _) => openCredits());
        Menu.Items.Add(new ToolStripSeparator());
        _quit = new ToolStripMenuItem("Quit Go Pray", null, (_, _) => quit());
        Menu.Items.Add(_quit);
        Menu.Opening += (_, _) => _quit.Enabled = !isBlocked();      // the gate refuses it too
        _icon = new NotifyIcon { Text = "Go Pray", ContextMenuStrip = Menu, Visible = true, Icon = ThemeIcon() };
        _icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) openPopover(); };
        SystemEvents.UserPreferenceChanged += OnPreference;
    }

    void OnPreference(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.VisualStyle) _icon.Icon = ThemeIcon();
    }

    public void SetTooltip(string text) => _icon.Text = text.Length > 63 ? text[..63] : text;

    /// <summary>true when the taskbar is light (Windows "SystemUsesLightTheme" = 1).</summary>
    public static bool LightTaskbar()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return k?.GetValue("SystemUsesLightTheme") is int v && v == 1;
        }
        catch (Exception) { return false; }
    }

    static Icon ThemeIcon()
    {
        var name = LightTaskbar() ? "tray-black-for-light-taskbar.ico" : "tray-white-for-dark-taskbar.ico";
        var path = Path.Combine(AppContext.BaseDirectory, "Resources", "icons", name);
        return File.Exists(path) ? new Icon(path, SystemInformation.SmallIconSize) : SystemIcons.Application;
    }

    public void Dispose()
    {
        SystemEvents.UserPreferenceChanged -= OnPreference;
        _icon.Visible = false;
        _icon.Dispose();
        Menu.Dispose();
    }
}
