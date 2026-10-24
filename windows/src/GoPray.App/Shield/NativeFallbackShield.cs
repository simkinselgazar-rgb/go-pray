// NativeFallbackShield.cs — the shield when the web page is blank, hung or crashed, or WebView2 is missing
// (§E.6, §G). Same gate, same button, same remaining time, no web. Port of Shield/NativeFallbackShield.swift.
// Plain on purpose: ground colour, name (EN + AR), one line, countdown, "I prayed", Silence.
// v2 (PLAN-v2 §2.2, §2.5, §9.3): a quiet footer "Emergency exit · 3 of 5 left this year" (absent at 0 or when the
// block's switch is off). Press and HOLD it 3 s (a thin bar fills; releasing early cancels; no keyboard path), then a
// confirm card ("Not now" is the default). "Use it" only ASKS: the gate decides and records the use.

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
    public int EmergencyExitsLeft { get; private set; }
    public bool Accepting { get => _accepting; set { _accepting = value; Changed?.Invoke(); } }
    /// <summary>An emergency exit is leaving: a plain fade, no "May Allah accept it."</summary>
    public bool Leaving { get => _leaving; set { _leaving = value; Changed?.Invoke(); } }
    public Action OnPrayed { get; set; } = () => { };
    public Action OnSilence { get; set; } = () => { };
    public Action OnEmergency { get; set; } = () => { };
    public event Action? Changed;
    bool _accepting, _leaving;

    public FallbackModel(ShieldContext ctx, DateTime? now = null) => Apply(ctx, now);

    public void Apply(ShieldContext ctx, DateTime? now = null)
    {
        var t = now ?? DateTime.UtcNow;
        Prayer = ctx.Prayer;
        CanConfirmAt = t.AddMilliseconds(ctx.RemainingMs);
        AthanEndsAt = ctx.AthanRemainingMs > 0 ? t.AddMilliseconds(ctx.AthanRemainingMs) : null;
        HiddenAppName = ctx.HiddenAppName;
        EmergencyExitsLeft = Math.Clamp(ctx.EmergencyExitsLeft, 0, EmergencyExitPolicy.Total);
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

    // Emergency exit: a Border, not a Button, so no key (Space/Enter) can press it.
    readonly TextBlock _exitLabel = new() { FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center };
    readonly Border _exitBar = new() { Height = 2, HorizontalAlignment = HorizontalAlignment.Left, Width = 0, Margin = new Thickness(0, 3, 0, 0) };
    readonly Border _exit = new() { Background = Brushes.Transparent, Padding = new Thickness(10, 6, 10, 6), Margin = new Thickness(0, 28, 0, 0), HorizontalAlignment = HorizontalAlignment.Center, Cursor = System.Windows.Input.Cursors.Hand };
    readonly DispatcherTimer _hold = new() { Interval = TimeSpan.FromMilliseconds(30) };
    DateTime? _holdStart;
    readonly StackPanel _card = new() { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 440, Visibility = Visibility.Collapsed };
    readonly TextBlock _cardTitle = new() { Text = Copy.EmergencyCardTitle, FontFamily = new FontFamily("Georgia"), FontSize = 26, HorizontalAlignment = HorizontalAlignment.Center };
    readonly TextBlock _cardBody = new() { FontSize = 15, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 12, 0, 20) };
    readonly Button _notNow = new() { Content = Copy.EmergencyNotNow, Width = 140, Height = 36, FontSize = 14, IsDefault = true, IsCancel = true };
    readonly Button _useIt = new() { Content = Copy.EmergencyUseIt, Width = 140, Height = 36, FontSize = 14, Margin = new Thickness(12, 0, 0, 0), Background = Brushes.Transparent };
    /// <summary>Tests: the hold length (the policy's 3 s by default).</summary>
    internal TimeSpan HoldFor { get; set; } = TimeSpan.FromSeconds(EmergencyExitPolicy.HoldSeconds);

    public NativeFallbackShield(FallbackModel model)
    {
        _m = model;
        _prayed.Click += (_, _) => _m.OnPrayed();
        _silence.Click += (_, _) => _m.OnSilence();
        var exitInner = new StackPanel();
        exitInner.Children.Add(_exitLabel);
        exitInner.Children.Add(_exitBar);
        _exit.Child = exitInner;
        _exit.MouseLeftButtonDown += (_, e) => { BeginHold(); _exit.CaptureMouse(); e.Handled = true; };
        _exit.MouseLeftButtonUp += (_, _) => { _exit.ReleaseMouseCapture(); CancelHold(); };
        _exit.LostMouseCapture += (_, _) => CancelHold();
        _hold.Tick += (_, _) => HoldTick();
        _notNow.Click += (_, _) => CloseCard();
        _useIt.Click += (_, _) => { CloseCard(); _m.OnEmergency(); };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        buttons.Children.Add(_notNow);
        buttons.Children.Add(_useIt);
        foreach (var e in new UIElement[] { _cardTitle, _cardBody, buttons }) _card.Children.Add(e);
        foreach (var e in new UIElement[] { _latin, _arabic, _line, _time, _prayed, _silence, _exit }) _stack.Children.Add(e);
        Children.Add(_stack);
        Children.Add(_card);
        Children.Add(_accept);
        _m.Changed += Render;
        _tick.Tick += (_, _) => Render();
        Loaded += (_, _) => { _tick.Start(); Render(); };
        Unloaded += (_, _) => { _tick.Stop(); _hold.Stop(); };
        Render();
    }

    public string TimeText => _time.Text;
    public bool PrayedEnabled => _prayed.IsEnabled;
    internal bool ExitVisible => _exit.Visibility == Visibility.Visible;
    internal string ExitText => _exitLabel.Text;
    internal bool CardOpen => _card.Visibility == Visibility.Visible;
    internal string CardBody => _cardBody.Text;

    // Also the test seams for the hold (the real path is the mouse handlers above).
    internal void BeginHold()
    {
        if (!ExitVisible || CardOpen) return;
        _holdStart = DateTime.UtcNow;
        _exitLabel.Text = Copy.EmergencyHolding;
        _hold.Start();
    }

    internal void CancelHold()
    {
        if (_holdStart == null) return;
        _holdStart = null;
        _hold.Stop();
        _exitBar.Width = 0;
        Render();
    }

    internal void PressNotNow() => _notNow.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
    internal void PressUseIt() => _useIt.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));

    void HoldTick()
    {
        if (_holdStart is not { } t0) return;
        double f = Math.Min(1, (DateTime.UtcNow - t0).TotalMilliseconds / HoldFor.TotalMilliseconds);
        _exitBar.Width = Math.Max(0, _exit.ActualWidth - _exit.Padding.Left - _exit.Padding.Right) * f;
        if (f < 1) return;
        _holdStart = null;
        _hold.Stop();
        _exit.ReleaseMouseCapture();
        _exitBar.Width = 0;
        _cardBody.Text = Copy.EmergencyCardBody(_m.Prayer, _m.EmergencyExitsLeft);
        _card.Visibility = Visibility.Visible;
        _stack.Visibility = Visibility.Collapsed;
        _notNow.Focus();
        Render();
    }

    void CloseCard()
    {
        _card.Visibility = Visibility.Collapsed;
        _stack.Visibility = Visibility.Visible;
        Render();
    }

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
        bool showExit = _m.EmergencyExitsLeft > 0 && !_m.Accepting && !_m.Leaving;
        _exit.Visibility = showExit ? Visibility.Visible : Visibility.Collapsed;
        if (!showExit && CardOpen) { _card.Visibility = Visibility.Collapsed; _stack.Visibility = Visibility.Visible; }
        if (_holdStart == null) _exitLabel.Text = Copy.EmergencyButton(_m.EmergencyExitsLeft);
        var quiet = new SolidColorBrush(Color.FromArgb(153, pal.Text.R, pal.Text.G, pal.Text.B));   // 60 % ink
        _exitLabel.Foreground = quiet;
        _exitBar.Background = quiet;
        _cardTitle.Foreground = ink; _cardBody.Foreground = ink; _useIt.Foreground = ink;
        _stack.Opacity = _m.Accepting || _m.Leaving ? 0 : 1;
        _card.Opacity = _m.Leaving ? 0 : 1;
        _accept.Opacity = _m.Accepting ? 1 : 0;
    }
}
