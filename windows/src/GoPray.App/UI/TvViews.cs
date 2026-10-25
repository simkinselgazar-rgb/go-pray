// TvViews.cs — the small pieces Settings → TVs and Setup's TV step draw the same way (0.3.1). The logic is the shared
// TvsModel in Core; this file only draws.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace GoPray.App.UI;

internal static class TvViews
{
    /// <summary>"Add by address": the TV's address, or null on Cancel. The model checks it (private IPv4 only).</summary>
    public static string? AskAddress(Window owner)
    {
        string? result = null;
        var dlg = new Window
        {
            Title = "Add a TV", Width = 420, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Owner = owner, FontFamily = Theme.Body, Background = Brushes.White,
        };
        var p = new StackPanel { Margin = new Thickness(Theme.S24) };
        var h = Theme.Heading("The TV's address");
        h.Margin = new Thickness(0, 0, 0, Theme.S8);
        p.Children.Add(h);
        p.Children.Add(Theme.Help("On the TV: Settings → Network → About. It looks like 192.168.1.20."));
        var box = new TextBox { FontFamily = Theme.Mono, FontSize = 13, Margin = new Thickness(0, Theme.S12, 0, 0), MaxLength = 15 };
        System.Windows.Automation.AutomationProperties.SetName(box, "TV address");
        p.Children.Add(box);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, Theme.S16, 0, 0) };
        var cancel = Theme.Button("Cancel", dlg.Close);
        cancel.IsCancel = true;
        var add = Theme.Button("Add", () => { result = box.Text; dlg.Close(); }, primary: true);
        add.IsDefault = true;
        add.Margin = new Thickness(Theme.S8, 0, 0, 0);
        buttons.Children.Add(cancel); buttons.Children.Add(add);
        p.Children.Add(buttons);
        dlg.Content = p;
        dlg.Loaded += (_, _) => box.Focus();
        dlg.ShowDialog();
        return result;
    }

    /// <summary>A TV's name over its address (mono), with an optional line under them.</summary>
    public static StackPanel NameAndHost(string name, string host, string? line = null)
    {
        var text = new StackPanel();
        text.Children.Add(Theme.Text(name, 13, wrap: false));
        text.Children.Add(new TextBlock { Text = host, FontFamily = Theme.Mono, FontSize = 11, Foreground = Theme.Secondary });
        if (line != null) text.Children.Add(Theme.Help(line));
        return text;
    }

    /// <summary>The placeholder row a scan shows while it runs: two quiet bars where a TV will be (no spinner, no blank).</summary>
    public static UIElement SkeletonRow()
    {
        var p = new StackPanel { Margin = new Thickness(0, Theme.S8, 0, 0) };
        System.Windows.Automation.AutomationProperties.SetName(p, "Looking for TVs");
        p.Children.Add(new Border { Width = 180, Height = 12, CornerRadius = new CornerRadius(3), Background = Theme.Quaternary, HorizontalAlignment = HorizontalAlignment.Left });
        p.Children.Add(new Border { Width = 110, Height = 9, CornerRadius = new CornerRadius(3), Background = Theme.Quaternary, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 5, 0, 0), Opacity = 0.7 });
        return p;
    }
}
