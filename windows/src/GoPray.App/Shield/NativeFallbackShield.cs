// NativeFallbackShield.cs — the shield when the web page is blank, hung or crashed, or WebView2 is missing
// (§E.6, §G). Same gate, same button, same remaining time, no web. Port of Shield/NativeFallbackShield.swift.
// Plain on purpose: ground colour, name (EN + AR), one line, countdown, "I prayed", Silence.

using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using GoPray.Core;

namespace GoPray.App.Shield;

/// <summary>What the fallback shows. The controller keeps it in step with the gate's Update.</summary>
internal sealed class FallbackModel
{
    public Prayer Prayer { get; private set; }
    public DateTime CanConfirmAt { get; private set; }
    public DateTime? AthanEndsAt { get; private set; }
    public string? HiddenAppName { get; private set; }
    public bool Accepting { get => _accepting; set { _accepting = value; Changed?.Invoke(); } }
    public Action OnPrayed { get; set; } = () => { };
    public Action OnSilence { get; set; } = () => { };
    public event Action? Changed;
    bool _accepting;

    public FallbackModel(ShieldContext ctx, DateTime? now = null) => Apply(ctx, now);

    public void Apply(ShieldContext ctx, DateTime? now = null)
    {
        var t = now ?? DateTime.UtcNow;
        Prayer = ctx.Prayer;
        CanConfirmAt = t.AddMilliseconds(ctx.RemainingMs);
        AthanEndsAt = ctx.AthanRemainingMs > 0 ? t.AddMilliseconds(ctx.AthanRemainingMs) : null;
        HiddenAppName = ctx.HiddenAppName;
        Changed?.Invoke();
    }

    /// <summary>Whole seconds until "I prayed" opens (ceil), never negative.</summary>
    public int SecondsLeft(DateTime now) => Math.Max(0, (int)Math.Ceiling((CanConfirmAt - now).TotalSeconds));
}

internal sealed class NativeFallbackShield : Grid
{
    readonly FallbackModel _m;
    readonly TextBlock _latin = new() { FontFamily = new FontFamily("Georgia"), FontSize = 44, HorizontalAlignment = HorizontalAlignment.Center };
    readonly TextBlock _arabic = new() { FontFamily = new FontFamily("Amiri, Segoe UI"), FontSize = 34, HorizontalAlignment = HorizontalAlignment.Center, FlowDirection = FlowDirection.RightToLeft };
    readonly TextBlock _line = new() { FontSize = 15, Opacity = 0.8, Margin = new Thickness(0, 6, 0, 0), HorizontalAlignment = HorizontalAlignment.Center };
    readonly TextBlock _time = new() { FontFamily = new FontFamily("Georgia"), FontSize = 40, FontWeight = FontWeights.Light, Margin = new Thickness(0, 12, 0, 12), HorizontalAlignment = HorizontalAlignment.Center };
    readonly Button _prayed = new() { Content = "I prayed", Width = 200, Height = 40, FontSize = 16, BorderThickness = new Thickness(1) };
    readonly Button _silence = new() { Content = "Athan playing · Silence", FontSize = 13, Opacity = 0.7, Margin = new Thickness(0, 4, 0, 0), Background = Brushes.Transparent, BorderThickness = new Thickness(0) };
    readonly StackPanel _stack = new() { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
    readonly TextBlock _accept = new() { Text = "May Allah accept it.", FontFamily = new FontFamily("Georgia"), FontSize = 28, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Opacity = 0 };
    readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromMilliseconds(250) };

    public NativeFallbackShield(FallbackModel model)
    {
        _m = model;
        _prayed.Click += (_, _) => _m.OnPrayed();
        _silence.Click += (_, _) => _m.OnSilence();
        foreach (var e in new UIElement[] { _latin, _arabic, _line, _time, _prayed, _silence }) _stack.Children.Add(e);
        Children.Add(_stack);
        Children.Add(_accept);
        _m.Changed += Render;
        _tick.Tick += (_, _) => Render();
        Loaded += (_, _) => { _tick.Start(); Render(); };
        Unloaded += (_, _) => _tick.Stop();
        Render();
    }

    public string TimeText => _time.Text;
    public bool PrayedEnabled => _prayed.IsEnabled;

    void Render()
    {
        var pal = ShieldPalette.Of(_m.Prayer);
        var ink = new SolidColorBrush(pal.Text);
        Background = new SolidColorBrush(pal.Ground);
        var names = ShieldPalette.Names[_m.Prayer];
        _latin.Text = names.Latin;
        _arabic.Text = names.Arabic;
        _line.Text = _m.HiddenAppName is { } app
            ? (app.Length > 40 ? app[..40] : app) + " is resting until you pray."
            : "Time to pray. Your work will be right here.";
        int left = _m.SecondsLeft(DateTime.UtcNow);
        _time.Text = $"{left / 60}:{left % 60:00}";
        bool open = left == 0;
        _prayed.IsEnabled = open;
        _prayed.Background = open ? new SolidColorBrush(ShieldPalette.Nabawi) : new SolidColorBrush(Color.FromArgb(18, pal.Text.R, pal.Text.G, pal.Text.B));
        _prayed.Foreground = open ? new SolidColorBrush(ShieldPalette.OnNabawi) : new SolidColorBrush(Color.FromArgb(115, pal.Text.R, pal.Text.G, pal.Text.B));
        _prayed.BorderBrush = new SolidColorBrush(Color.FromArgb(open ? (byte)0 : (byte)56, pal.Text.R, pal.Text.G, pal.Text.B));
        _silence.Visibility = (_m.AthanEndsAt ?? DateTime.MinValue) > DateTime.UtcNow ? Visibility.Visible : Visibility.Collapsed;
        foreach (var t in new[] { _latin, _arabic, _line, _time, _accept }) t.Foreground = ink;
        _silence.Foreground = ink;
        _stack.Opacity = _m.Accepting ? 0 : 1;
        _accept.Opacity = _m.Accepting ? 1 : 0;
    }
}
