// CreditsWindow.cs — voices, sources and the takedown line. Port of UI/CreditsView.swift (text from Core Credits).
// Static text, no async loading, so no skeleton. The PrayTimes link opens in the person's browser only when
// they click it (a user action; the app itself makes no request).

using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using GoPray.Core;

namespace GoPray.App.UI;

internal sealed class CreditsWindow : Window
{
    public CreditsWindow()
    {
        Title = "Credits";
        Width = 440;
        Height = 520;
        ResizeMode = ResizeMode.CanMinimize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Brushes.White;
        FontFamily = Theme.Body;
        var p = new StackPanel();
        p.Children.Add(Theme.Text("Credits", 20, weight: FontWeights.SemiBold));
        Section(p, "Fajr", Theme.Text(Credits.FajrLine), Theme.Help(Credits.FajrNote));
        var link = new TextBlock();
        var h = new Hyperlink(new Run(Credits.PrayTimesName)) { NavigateUri = new System.Uri(Credits.PrayTimesUrl) };
        h.RequestNavigate += (_, e) => Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
        link.Inlines.Add(h);
        Section(p, "Other prayers", Theme.Text(Credits.PrayTimesLine), link);
        Section(p, "Sunni voices", Names(Credits.SunniNames));
        Section(p, "Shia voices", Names(Credits.ShiaNames));
        Section(p, "Prayer times", Theme.Text(Credits.MathLine));
        var take = Theme.Help(Credits.TakedownText);
        take.Margin = new Thickness(0, 18, 0, 0);
        p.Children.Add(take);
        var done = Theme.Button("Done", Close, primary: true);
        done.IsDefault = true;
        done.HorizontalAlignment = HorizontalAlignment.Right;
        done.Margin = new Thickness(0, 18, 0, 0);
        p.Children.Add(done);
        Content = new ScrollViewer { Content = new Border { Padding = new Thickness(20), Child = p }, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    static void Section(Panel p, string title, params UIElement[] items)
    {
        var t = Theme.Text(title, 14, weight: FontWeights.SemiBold);
        t.Margin = new Thickness(0, 18, 0, 6);
        p.Children.Add(t);
        foreach (var i in items) p.Children.Add(i);
    }

    static UIElement Names(System.Collections.Generic.IEnumerable<string> names)
    {
        var s = new StackPanel();
        foreach (var n in names) s.Children.Add(Theme.Text(n, 13));
        return s;
    }
}
