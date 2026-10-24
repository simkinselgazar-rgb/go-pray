// PopoverWindow.cs — the tray popover, 320 wide (spec §7). Port of UI/MenuView.swift.
// Today's five times, the next prayer and a countdown, the mode, the paused state. Quiet on purpose:
// no ticks, no "prayed" marks, no history. During a block the header reads "6:12 left" and Quit is disabled
// (the gate refuses it too). Opens above the tray; closes when it loses focus.

using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using GoPray.App.Update;
using GoPray.Core;

namespace GoPray.App.UI;

internal sealed class PopoverWindow : Window
{
    readonly MenuModel _model;
    readonly Action _openSettings, _openSetup, _quit;
    readonly UpdateChecker? _updates;
    readonly SceneBand _band = new(320, 96);
    readonly StackPanel _root = new() { Width = 320 };
    readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromSeconds(1) };
    public UIElement? DebugPanel { get; set; }

    public PopoverWindow(MenuModel model, Action openSettings, Action openSetup, Action quit, UpdateChecker? updates = null)
    {
        _model = model; _openSettings = openSettings; _openSetup = openSetup; _quit = quit; _updates = updates;
        if (updates != null) updates.Changed += () => Dispatcher.BeginInvoke(() => { if (IsVisible) Render(); });
        Title = "Go Pray";
        SizeToContent = SizeToContent.WidthAndHeight;       // the 320-wide content sets the size (an explicit Width is DPI-scaled wrongly off-monitor)
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Background = new SolidColorBrush(Color.FromRgb(0xF9, 0xF9, 0xF9));
        BorderBrush = new SolidColorBrush(Color.FromArgb(0x33, 0, 0, 0));
        BorderThickness = new Thickness(1);
        FontFamily = Theme.Body;
        Content = _root;
        _tick.Tick += (_, _) => Render();
        Deactivated += (_, _) => Hide();
        IsVisibleChanged += (_, _) => { if (IsVisible) { Render(); _tick.Start(); } else _tick.Stop(); };
    }

    /// <summary>Show just above the taskbar's notification area.</summary>
    public void ShowNearTray()
    {
        Render();
        Show();
        UpdateLayout();
        var work = SystemParameters.WorkArea;
        Left = work.Right - ActualWidth - 12;
        Top = work.Bottom - ActualHeight - 12;
        Activate();
    }

    internal void Render()
    {
        var snap = _model.Snapshot(_model.Clock.Now);
        _root.Children.Clear();
        switch (snap.Status)
        {
            case MenuStatus.NeedsSetup:
                Empty("Add your city to see today's prayer times.", "Set up", _openSetup);
                break;
            case MenuStatus.NoSchedule:
                Empty("Go Pray can't work out times for this place. Check the city in Settings.", "Open Settings", _openSettings);
                break;
            default:
                Header(snap);
                Rows(snap);
                _root.Children.Add(Theme.Divider());
                ModeAndPlace(snap);
                if (snap.EmergencyLine is { } exits)
                {
                    var e = Theme.Text(exits, 11, Theme.Secondary);
                    e.Margin = new Thickness(Theme.S16, 0, Theme.S16, Theme.S12);
                    _root.Children.Add(e);
                }
                break;
        }
        UpdateRow(snap);
        _root.Children.Add(Theme.Divider());
        Actions(snap);
        var version = Theme.Text(AppVersion.Line, 10, Theme.Secondary, wrap: false);
        version.HorizontalAlignment = HorizontalAlignment.Center;
        version.Margin = new Thickness(0, 0, 0, Theme.S8);
        _root.Children.Add(version);
        if (DebugPanel != null)
        {
            _root.Children.Add(Theme.Divider());
            if (DebugPanel is FrameworkElement fe && fe.Parent is Panel old) old.Children.Remove(fe);
            _root.Children.Add(DebugPanel);
        }
    }

    void Header(MenuSnapshot snap)
    {
        var prayer = snap.HeaderPrayer;
        if (_band.Parent is Panel p) p.Children.Remove(_band);
        _root.Children.Add(_band);
        _band.Show(prayer);
        var g = new Grid { Margin = new Thickness(Theme.S16, Theme.S12, Theme.S16, Theme.S12) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel();
        left.Children.Add(Theme.DisplayCaps(Labels.PrayerName(prayer), 20, 0.1));
        left.Children.Add(Theme.Text(snap.Subtitle, 13, Theme.Secondary));
        g.Children.Add(left);
        if (snap.PausedLine != null && !snap.IsBlocked)
        {
            var resume = Theme.Link("Resume", () => { _model.Resume(); Render(); });
            resume.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(resume, 1);
            g.Children.Add(resume);
        }
        _root.Children.Add(g);
    }

    void Rows(MenuSnapshot snap)
    {
        var list = new StackPanel { Margin = new Thickness(0, 0, 0, Theme.S8) };
        foreach (var r in snap.Rows)
        {
            var g = new Grid { Height = 28, Margin = new Thickness(Theme.S16, 0, Theme.S16, 0) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var brush = r.IsPast ? Theme.Secondary : Theme.Primary;
            var dot = new System.Windows.Shapes.Ellipse { Width = 6, Height = 6, Fill = r.IsNext ? new SolidColorBrush(Theme.Accent(r.Prayer)) : Brushes.Transparent, VerticalAlignment = VerticalAlignment.Center };
            var name = Theme.Text(Labels.PrayerName(r.Prayer), 13, brush, r.IsNext ? FontWeights.SemiBold : FontWeights.Normal);
            name.VerticalAlignment = VerticalAlignment.Center;
            var time = Theme.Text(TimeText.Clock(r.Time), 13, brush);
            time.VerticalAlignment = VerticalAlignment.Center;
            time.SetValue(System.Windows.Documents.Typography.NumeralAlignmentProperty, FontNumeralAlignment.Tabular);
            Grid.SetColumn(name, 1); Grid.SetColumn(time, 2);
            g.Children.Add(dot); g.Children.Add(name); g.Children.Add(time);
            System.Windows.Automation.AutomationProperties.SetName(g, $"{Labels.PrayerName(r.Prayer)}, {TimeText.Clock(r.Time)}{(r.IsNext ? ", next" : "")}");
            list.Children.Add(g);
        }
        _root.Children.Add(list);
    }

    void ModeAndPlace(MenuSnapshot snap)
    {
        var g = new Grid { Margin = new Thickness(Theme.S16, Theme.S12, Theme.S16, Theme.S12) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        var chip = new Border { CornerRadius = new CornerRadius(6), Background = Theme.Quaternary, Padding = new Thickness(8, 3, 8, 3), Child = Theme.Text(Labels.ModeChip(snap.Mode), 11, Theme.Primary, wrap: false) };
        System.Windows.Automation.AutomationProperties.SetName(chip, "Mode: " + Labels.ModeName(snap.Mode));
        var footer = Theme.Text(snap.Footer, 11, Theme.Secondary, wrap: false);
        footer.HorizontalAlignment = HorizontalAlignment.Right;
        footer.VerticalAlignment = VerticalAlignment.Center;
        footer.Margin = new Thickness(Theme.S8, 0, 0, 0);
        Grid.SetColumn(footer, 1);
        g.Children.Add(chip); g.Children.Add(footer);
        _root.Children.Add(g);
    }

    void Actions(MenuSnapshot snap)
    {
        var g = new Grid { Margin = new Thickness(Theme.S16, Theme.S12, Theme.S16, Theme.S12) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var settings = Theme.Button("Settings…", () => { Hide(); _openSettings(); });
        settings.HorizontalAlignment = HorizontalAlignment.Left;
        var quit = Theme.Button("Quit Go Pray", _quit);
        quit.IsEnabled = !snap.IsBlocked;                  // the gate refuses it too
        Grid.SetColumn(quit, 1);
        g.Children.Add(settings); g.Children.Add(quit);
        _root.Children.Add(g);
    }

    /// <summary>"Update available: 0.2.0 — Download", or the checker's last line ("You're up to date." …). Disabled
    /// during a block (the checker refuses then too).</summary>
    void UpdateRow(MenuSnapshot snap)
    {
        if (_updates is not { } u) return;
        UIElement? row = null;
        if (u.Status == UpdateStatus.Available && u.Latest is { } r)
        {
            var link = Theme.Link($"Update available: {r.Version.ToString(3)} — Download", () => { _ = u.DownloadAndOpen(); });
            link.IsEnabled = !snap.IsBlocked;
            row = link;
        }
        else if (u.Message is { } m)
        {
            var p = new StackPanel();
            p.Children.Add(Theme.Text(m, 11, Theme.Secondary));
            if (u.Status == UpdateStatus.Failed)
                p.Children.Add(Theme.Link("Open the releases page", UpdateChecker.OpenReleasesPage));
            row = p;
        }
        if (row == null) return;
        _root.Children.Add(Theme.Divider());
        if (row is FrameworkElement fe) fe.Margin = new Thickness(Theme.S16, Theme.S8, Theme.S16, Theme.S8);
        _root.Children.Add(row);
    }

    void Empty(string text, string button, Action action)
    {
        var p = new StackPanel { Margin = new Thickness(Theme.S16) };
        p.Children.Add(Theme.Text(text, 13));
        var b = Theme.Button(button, () => { Hide(); action(); }, primary: true);
        b.HorizontalAlignment = HorizontalAlignment.Left;
        b.Margin = new Thickness(0, Theme.S12, 0, 0);
        p.Children.Add(b);
        _root.Children.Add(p);
    }
}
