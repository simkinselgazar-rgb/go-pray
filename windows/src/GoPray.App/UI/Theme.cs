// Theme.cs — the few tokens the app chrome uses (spec §4–6) and small builders shared by the popover,
// Setup, Settings and Credits. Port of PrayerTokens / GPFont / Spacing / GPNotice in
// UI/SetupViewComponents.swift. Windows: Segoe UI where the Mac uses SF Pro; Cormorant Garamond for
// display text, Amiri for Arabic (both OFL, bundled from GoPray/Resources/fonts).

using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using GoPray.App.Shield;
using GoPray.Core;

namespace GoPray.App.UI;

internal static class Theme
{
    public const double S4 = 4, S8 = 8, S12 = 12, S16 = 16, S24 = 24, S32 = 32;

    static readonly Uri FontsDir = new(Path.Combine(AppContext.BaseDirectory, "Resources", "fonts") + Path.DirectorySeparatorChar);
    public static readonly FontFamily Display = new(FontsDir, "./#Cormorant Garamond, Georgia");
    public static readonly FontFamily Arabic = new(FontsDir, "./#Amiri, Segoe UI");
    public static readonly FontFamily Body = new("Segoe UI Variable Text, Segoe UI");
    public static readonly FontFamily Mono = new("Cascadia Mono, Consolas");

    public static readonly Brush Secondary = new SolidColorBrush(Color.FromRgb(0x5F, 0x5F, 0x5F));
    public static readonly Brush Quaternary = new SolidColorBrush(Color.FromArgb(0x1F, 0, 0, 0));
    public static readonly Brush Primary = new SolidColorBrush(Color.FromRgb(0x1B, 0x1B, 0x1B));

    /// <summary>The 6 pt "next prayer" dot colour (the prayer's ring token).</summary>
    public static Color Accent(Prayer p) => p switch
    {
        Prayer.Fajr => ShieldPalette.Hex(0xF5D4A0),
        Prayer.Dhuhr => ShieldPalette.Hex(0x2E4D60),
        Prayer.Asr => ShieldPalette.Hex(0x7A5C22),
        Prayer.Maghrib => ShieldPalette.Hex(0x5C3A12),
        _ => ShieldPalette.Hex(0x62A38E),
    };

    public static TextBlock Text(string s, double size = 13, Brush? color = null, FontWeight? weight = null, bool wrap = true) => new()
    {
        Text = s, FontSize = size, FontFamily = Body, Foreground = color ?? Primary,
        FontWeight = weight ?? FontWeights.Normal, TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
    };

    /// <summary>Display caps (Latin only: never letter-space Arabic). Tracking in em.</summary>
    public static FrameworkElement DisplayCaps(string s, double size, double trackingEm = 0.25)
    {
        // WPF text has no tracking, so each letter is its own glyph run with the em gap after it.
        var p = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var ch in s.ToUpperInvariant())
            p.Children.Add(new TextBlock { Text = ch.ToString(), FontFamily = Display, FontSize = size, Foreground = Primary, Margin = new Thickness(0, 0, size * trackingEm, 0) });
        System.Windows.Automation.AutomationProperties.SetName(p, s);
        return p;
    }

    public static TextBlock Heading(string s, double size = 26) => new()
    {
        Text = s, FontFamily = Display, FontSize = size, Foreground = Primary, TextWrapping = TextWrapping.Wrap,
    };

    public static TextBlock Help(string s) => Text(s, 12, Secondary);

    /// <summary>One line of "why", never red (GPNotice).</summary>
    public static UIElement Notice(string text, bool locked = true)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, S8) };
        p.Children.Add(new TextBlock { Text = locked ? "" : "", FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 13, Foreground = Secondary, Margin = new Thickness(0, 2, 6, 0) });
        p.Children.Add(Text(text, 12, Secondary));
        return p;
    }

    public static Button Button(string label, Action onClick, bool primary = false, double minWidth = 76)
    {
        var b = new Button
        {
            Content = label, MinWidth = minWidth, Height = 30, Padding = new Thickness(12, 2, 12, 2), FontFamily = Body, FontSize = 13,
            Background = primary ? new SolidColorBrush(ShieldPalette.Nabawi) : new SolidColorBrush(Color.FromRgb(0xF3, 0xF3, 0xF3)),
            Foreground = primary ? new SolidColorBrush(ShieldPalette.OnNabawi) : Primary,
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0, 0, 0)), BorderThickness = new Thickness(1),
        };
        b.Click += (_, _) => onClick();
        return b;
    }

    public static Button Link(string label, Action onClick)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = label, TextDecorations = TextDecorations.Underline, Foreground = new SolidColorBrush(ShieldPalette.Hex(0x2E4D60)), FontSize = 12, FontFamily = Body },
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), Cursor = System.Windows.Input.Cursors.Hand, Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        b.Click += (_, _) => onClick();
        return b;
    }

    /// <summary>Segmented control: one toggle per option, exactly one checked.</summary>
    public static StackPanel Segmented<T>(T[] options, Func<T, string> label, T selected, Action<T> pick)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var o in options)
        {
            var chosen = Equals(o, selected);
            var b = new Button
            {
                Content = label(o), MinWidth = 120, Height = 30, FontFamily = Body, FontSize = 13, Padding = new Thickness(12, 2, 12, 2),
                Background = chosen ? new SolidColorBrush(Color.FromRgb(0xFF, 0xFF, 0xFF)) : new SolidColorBrush(Color.FromRgb(0xEC, 0xEC, 0xEC)),
                FontWeight = chosen ? FontWeights.SemiBold : FontWeights.Normal,
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0, 0, 0)), BorderThickness = new Thickness(1),
            };
            System.Windows.Automation.AutomationProperties.SetName(b, label(o) + (chosen ? ", selected" : ""));
            b.Click += (_, _) => pick(o);
            p.Children.Add(b);
        }
        return p;
    }

    public static Border Divider() => new() { Height = 1, Background = Quaternary, Margin = new Thickness(0) };
}
