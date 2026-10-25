// SetupWindow.cs — first-run window, 520 x 600 (spec §7). Port of UI/SetupView.swift.
// Three steps (four with the optional TV step, 0.3.1) and a done screen, one question per step, native controls, no
// motion between steps.

using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using GoPray.Core;

namespace GoPray.App.UI;

internal sealed class SetupWindow : Window
{
    readonly SetupModel _m;
    readonly SceneBand _band = new(520, 96);
    readonly DockPanel _body = new() { Margin = new Thickness(Theme.S24), LastChildFill = true };
    CitySearchView? _search;

    internal SetupModel Model => _m;
    internal void Refresh() => Render();

    public SetupWindow(SetupModel model)
    {
        _m = model;
        Title = "Set up Go Pray";
        SizeToContent = SizeToContent.WidthAndHeight;       // the client area is exactly 520 x 600 (spec §7)
        ResizeMode = ResizeMode.CanMinimize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Brushes.White;
        FontFamily = Theme.Body;
        var dock = new DockPanel { LastChildFill = true, Width = 520, Height = 600 };
        DockPanel.SetDock(_band, Dock.Top);
        dock.Children.Add(_band);
        dock.Children.Add(_body);
        Content = dock;
        _m.Preview.Changed += () => Dispatcher.BeginInvoke(Render);
        if (_m.Tvs != null) _m.Tvs.Changed += () => Dispatcher.BeginInvoke(Render);
        Closed += (_, _) => _m.Preview.Stop();
        Loaded += (_, _) => Render();
    }

    void Render()
    {
        _band.Show(_m.HeaderPrayer);
        _body.Children.Clear();
        var top = new StackPanel();
        DockPanel.SetDock(top, Dock.Top);
        if (_m.Step != SetupStep.Done) top.Children.Add(Theme.Text($"Step {_m.StepNumber} of {_m.StepCount}", 11, Theme.Secondary));
        var title = Theme.Heading(_m.Title);
        title.Margin = new Thickness(0, Theme.S8, 0, Theme.S16);
        System.Windows.Automation.AutomationProperties.SetHeadingLevel(title, System.Windows.Automation.AutomationHeadingLevel.Level1);
        top.Children.Add(title);
        _body.Children.Add(top);
        var footer = Footer();
        DockPanel.SetDock(footer, Dock.Bottom);
        _body.Children.Add(footer);
        if (_m.Notice is { } n) { var note = Theme.Notice(n, locked: false); DockPanel.SetDock(note, Dock.Bottom); _body.Children.Add(note); }
        var content = new ContentControl { VerticalAlignment = VerticalAlignment.Top };
        content.Content = _m.Step switch
        {
            SetupStep.City => _search ??= new CitySearchView(_m.Search, c => { _m.PickedCity = c; RenderFooterOnly(); }),
            SetupStep.Method => MethodStep(),
            SetupStep.Mode => ModeStep(),
            SetupStep.Tv when _m.Tvs is { } tvm => TvStep(tvm),
            _ => DoneStep(),
        };
        _body.Children.Add(content);
    }

    Grid? _footer;
    void RenderFooterOnly()
    {
        if (_footer?.Parent is Panel p) { int i = p.Children.IndexOf(_footer); p.Children.RemoveAt(i); p.Children.Insert(i, Footer()); }
    }

    UIElement MethodStep()
    {
        var p = new StackPanel();
        var list = new ListBox { Height = 236, BorderBrush = Theme.Quaternary };
        foreach (var m in Labels.Methods)
        {
            var row = new StackPanel { Margin = new Thickness(4, 3, 4, 3) };
            row.Children.Add(Theme.Text(m.DisplayName, 13, weight: FontWeights.SemiBold));
            row.Children.Add(Theme.Text(m.Detail, 12, Theme.Secondary));
            var item = new ListBoxItem { Content = row, Tag = m.Raw };
            System.Windows.Automation.AutomationProperties.SetName(item, $"{m.DisplayName}. {m.Detail}");
            list.Items.Add(item);
            if (m.Raw == _m.Method) list.SelectedItem = item;
        }
        list.SelectionChanged += (_, _) => { if (list.SelectedItem is ListBoxItem { Tag: string raw }) _m.Method = raw; };
        // The suggested method can sit below the fold: show it, selected, on arrival.
        list.Loaded += (_, _) => { if (list.SelectedItem != null) list.ScrollIntoView(list.SelectedItem); };
        p.Children.Add(list);
        var asr = new StackPanel { Margin = new Thickness(0, Theme.S16, 0, 0) };
        var row2 = new StackPanel { Orientation = Orientation.Horizontal };
        row2.Children.Add(new TextBlock { Text = "Asr", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, Theme.S12, 0), FontSize = 13 });
        row2.Children.Add(Theme.Segmented([1, 2], Labels.MadhabName, _m.Madhab, v => { _m.Madhab = v; Render(); }));
        asr.Children.Add(row2);
        var help = Theme.Help(Labels.MadhabHelp(_m.Madhab));
        help.Margin = new Thickness(0, Theme.S8, 0, 0);
        asr.Children.Add(help);
        p.Children.Add(asr);
        return p;
    }

    UIElement ModeStep()
    {
        var p = new StackPanel();
        p.Children.Add(Theme.Segmented([BlockMode.WholeScreen, BlockMode.CodingApps], Labels.ModeName, _m.Mode, v => { _m.Mode = v; Render(); }));
        foreach (var mode in new[] { BlockMode.WholeScreen, BlockMode.CodingApps })
        {
            var t = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12, Margin = new Thickness(0, Theme.S8, 0, 0), Foreground = mode == _m.Mode ? Theme.Primary : Theme.Secondary };
            t.Inlines.Add(new System.Windows.Documents.Bold(new System.Windows.Documents.Run(Labels.ModeName(mode) + ". ")));
            t.Inlines.Add(new System.Windows.Documents.Run(Labels.ModeHelp(mode)));
            p.Children.Add(t);
        }
        p.Children.Add(VolumeRow(_m.Volume, v => _m.Volume = v, () => _m.Preview.Toggle(VoiceChoices.DefaultVoice, (float)_m.Volume), _m.Preview.IsPlaying, Theme.S24));
        if (_m.Preview.Failed) p.Children.Add(Theme.Help("Couldn't play the preview. You can pick another voice in Settings."));
        var login = new CheckBox { Content = "Launch at login", IsChecked = _m.LaunchAtLogin, Margin = new Thickness(0, Theme.S24, 0, 0), FontSize = 13 };
        login.Checked += (_, _) => { _m.LaunchAtLogin = true; Render(); };
        login.Unchecked += (_, _) => { _m.LaunchAtLogin = false; Render(); };
        p.Children.Add(login);
        if (_m.LaunchAtLogin) { var n = Theme.Help(Copy.LaunchAtLoginNote); n.Margin = new Thickness(0, Theme.S8, 0, 0); p.Children.Add(n); }
        return p;
    }

    internal static UIElement VolumeRow(double value, Action<double> set, Action preview, bool playing, double top)
    {
        var row = new DockPanel { Margin = new Thickness(0, top, 0, 0), LastChildFill = true };
        var label = new TextBlock { Text = "Athan volume", VerticalAlignment = VerticalAlignment.Center, FontSize = 13, Margin = new Thickness(0, 0, Theme.S8, 0) };
        var btn = Theme.Button(playing ? "Stop" : "Preview", preview, minWidth: 68);
        btn.Margin = new Thickness(Theme.S8, 0, 0, 0);
        DockPanel.SetDock(label, Dock.Left);
        DockPanel.SetDock(btn, Dock.Right);
        var slider = new Slider { Minimum = 0, Maximum = 1, Value = value, VerticalAlignment = VerticalAlignment.Center };
        System.Windows.Automation.AutomationProperties.SetName(slider, "Athan volume");
        slider.ValueChanged += (_, e) => set(e.NewValue);
        row.Children.Add(label); row.Children.Add(btn); row.Children.Add(slider);
        return row;
    }

    /// <summary>0.3.1: "Play the Athan on your TV?" over the shared TvsModel. The scan started as the step appeared;
    /// while it runs a skeleton row stands where the TVs will be.</summary>
    UIElement TvStep(TvsModel tvm)
    {
        var p = new StackPanel();
        p.Children.Add(Theme.Text(Copy.SetupTvLine, 13));
        var list = new StackPanel { Margin = new Thickness(0, Theme.S12, 0, 0) };
        foreach (var row in tvm.Rows)
        {
            var line = new DockPanel { Margin = new Thickness(0, Theme.S8, 0, 0) };
            var id = row.Id;
            var test = Theme.Button("Play a test", () => _ = tvm.TestTv(id));
            test.IsEnabled = !tvm.Busy;
            DockPanel.SetDock(test, Dock.Right);
            line.Children.Add(test);
            line.Children.Add(TvViews.NameAndHost(row.Name, row.Host, tvm.RowLine(id) ?? (row.Installed ? null : Copy.TvNotInstalledHelp)));
            list.Children.Add(line);
        }
        foreach (var f in tvm.Found)
        {
            var line = new DockPanel { Margin = new Thickness(0, Theme.S8, 0, 0) };
            var found = f;
            var add = Theme.Button("Add", () => _ = tvm.AddFound(found));
            add.IsEnabled = !tvm.Busy;
            DockPanel.SetDock(add, Dock.Right);
            line.Children.Add(add);
            line.Children.Add(TvViews.NameAndHost(f.Name, f.Host));
            list.Children.Add(line);
        }
        if (tvm.Searching) list.Children.Add(TvViews.SkeletonRow());
        p.Children.Add(new ScrollViewer { Content = list, MaxHeight = 250, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        // The scan's and the refusals' lines (a TV's own result is on its row).
        if (tvm.Notice is { } n && n is Copy.TvFirewall or Copy.TvNoneFound or Copy.TvAllListed or Copy.TvHostRefused or Copy.TvAlreadyListed or Copy.InvalidLine)
        {
            var help = Theme.Help(n);
            help.Margin = new Thickness(0, Theme.S8, 0, 0);
            p.Children.Add(help);
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, Theme.S12, 0, 0) };
        var again = Theme.Button("Find TVs again", () => _ = tvm.FindTvs());
        var byIp = Theme.Button("Add by address…", () => { if (TvViews.AskAddress(this) is { } host) _ = tvm.AddTv(host); });
        byIp.Margin = new Thickness(Theme.S8, 0, 0, 0);
        again.IsEnabled = byIp.IsEnabled = !tvm.Busy;
        buttons.Children.Add(again); buttons.Children.Add(byIp);
        p.Children.Add(buttons);
        return p;
    }

    UIElement DoneStep()
    {
        var p = new StackPanel();
        if (_m.NextLine is { } l) p.Children.Add(Theme.Text(l, 17));
        if (_m.LoginNote is { } n) { var t = Theme.Help(n); t.Margin = new Thickness(0, Theme.S12, 0, 0); p.Children.Add(t); }
        var where = Theme.Help("Go Pray lives in your notification area, next to the clock. It stays quiet until the next Athan.");
        where.Margin = new Thickness(0, Theme.S12, 0, 0);
        p.Children.Add(where);
        return p;
    }

    Grid Footer()
    {
        var g = new Grid { Margin = new Thickness(0, Theme.S16, 0, 0) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (_m.Step is SetupStep.Method or SetupStep.Mode or SetupStep.Tv)
        {
            var back = Theme.Button("Back", () => { _m.Back(); Render(); });
            back.HorizontalAlignment = HorizontalAlignment.Left;
            g.Children.Add(back);
        }
        if (_m.Step == SetupStep.Tv)
        {
            // Skip is the default until a TV is added, then Continue. Skip keeps any TV already added.
            var right = new StackPanel { Orientation = Orientation.Horizontal };
            var skip = Theme.Button("Skip", () => { _m.Skip(); Render(); }, primary: !_m.ContinueIsDefault);
            var go = Theme.Button("Continue", () => { _m.Next(); Render(); }, primary: _m.ContinueIsDefault);
            go.Margin = new Thickness(Theme.S8, 0, 0, 0);
            skip.IsDefault = !_m.ContinueIsDefault;
            go.IsDefault = _m.ContinueIsDefault;
            right.Children.Add(skip); right.Children.Add(go);
            Grid.SetColumn(right, 1);
            g.Children.Add(right);
            DockPanel.SetDock(g, Dock.Bottom);
            _footer = g;
            return g;
        }
        bool last = _m.Step == SetupStep.Mode && _m.Tvs == null;
        Button next = _m.Step == SetupStep.Done
            ? Theme.Button("Close", Close, primary: true)
            : Theme.Button(last ? "Finish" : "Next", () => { _m.Next(); Render(); }, primary: true);
        next.IsDefault = true;
        next.IsEnabled = _m.Step == SetupStep.Done || _m.CanGoNext;
        Grid.SetColumn(next, 1);
        g.Children.Add(next);
        DockPanel.SetDock(g, Dock.Bottom);
        _footer = g;
        return g;
    }
}
