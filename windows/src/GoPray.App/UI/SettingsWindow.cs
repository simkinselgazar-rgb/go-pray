// SettingsWindow.cs — one grouped form, 480 wide (spec §7). Port of UI/SettingsView.swift.
// Every control is disabled during a block, with one line on top saying why; the rule itself is enforced
// by the store through the gate, so a view bug cannot open a hole. No motion.

using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using GoPray.App.Blocker;
using GoPray.Core;

namespace GoPray.App.UI;

internal sealed class SettingsWindow : Window
{
    readonly SettingsModel _m;
    readonly Action _showCredits;
    readonly StackPanel _form = new();
    readonly DispatcherTimer _watch = new() { Interval = TimeSpan.FromSeconds(1) };
    bool _wasBlocked;

    public SettingsWindow(SettingsModel model, Action showCredits)
    {
        _m = model;
        _showCredits = showCredits;
        Title = "Go Pray Settings";
        Width = 480;
        Height = Math.Min(720, SystemParameters.WorkArea.Height - 60);
        ResizeMode = ResizeMode.CanMinimize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(Color.FromRgb(0xF7, 0xF7, 0xF7));
        FontFamily = Theme.Body;
        Content = new ScrollViewer { Content = new Border { Padding = new Thickness(Theme.S16), Child = _form }, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        _m.Changed += () => Dispatcher.BeginInvoke(Render);
        _m.Preview.Changed += () => Dispatcher.BeginInvoke(Render);
        // A block can start while Settings is open: re-render when the gate's answer changes.
        _watch.Tick += (_, _) => { if (_m.IsBlocked != _wasBlocked) Render(); };
        IsVisibleChanged += (_, _) => { if (IsVisible) { Render(); _watch.Start(); } else { _watch.Stop(); _m.Preview.Stop(); } };
    }

    internal void Render()
    {
        var s = _m.Settings;
        _wasBlocked = _m.IsBlocked;
        _form.Children.Clear();
        if (_m.IsBlocked || _m.Notice != null)
            _form.Children.Add(Theme.Notice(_m.IsBlocked ? Copy.BlockedLine : _m.Notice!, locked: _m.IsBlocked));
        var groups = new StackPanel { IsEnabled = !_m.IsBlocked };
        _form.Children.Add(groups);

        // Location
        var loc = Group(groups, "Location");
        var city = new DockPanel();
        var change = Theme.Button("Change…", ChangeCity);
        DockPanel.SetDock(change, Dock.Right);
        city.Children.Add(change);
        var cityText = new StackPanel();
        cityText.Children.Add(Theme.Text(s.City.Length == 0 ? "Not set" : s.City, 13));
        cityText.Children.Add(new TextBlock { Text = string.Format(CultureInfo.InvariantCulture, "{0:0.00}°, {1:0.00}°", s.Latitude, s.Longitude), FontFamily = Theme.Mono, FontSize = 11, Foreground = Theme.Secondary });
        city.Children.Add(cityText);
        loc.Children.Add(Row("City", city));

        // Prayer times
        var times = Group(groups, "Prayer times");
        var method = new ComboBox { MinWidth = 260 };
        foreach (var m in Labels.Methods) method.Items.Add(new ComboBoxItem { Content = m.DisplayName, Tag = m.Raw, IsSelected = m.Raw == s.Method });
        method.SelectionChanged += (_, _) => { if (method.SelectedItem is ComboBoxItem { Tag: string raw } && raw != _m.Settings.Method) _m.Apply(x => x with { Method = raw }); };
        times.Children.Add(Row("Method", method));
        times.Children.Add(Theme.Help(Labels.Method(s.Method)?.Detail ?? ""));
        times.Children.Add(Row("Asr", Theme.Segmented([1, 2], Labels.MadhabName, s.Madhab, v => _m.Apply(x => x with { Madhab = v }))));
        times.Children.Add(Theme.Help(Labels.MadhabHelp(s.Madhab)));
        var rule = new ComboBox { MinWidth = 260 };
        rule.Items.Add(new ComboBoxItem { Content = _m.AutomaticRuleLabel, Tag = null, IsSelected = s.HighLatitudeRule == null });
        foreach (var r in SettingsRules.HighLatitudeRules) rule.Items.Add(new ComboBoxItem { Content = Labels.RuleName(r), Tag = r, IsSelected = s.HighLatitudeRule == r });
        rule.SelectionChanged += (_, _) => { if (rule.SelectedItem is ComboBoxItem i && (string?)i.Tag != _m.Settings.HighLatitudeRule) _m.Apply(x => x with { HighLatitudeRule = (string?)i.Tag }); };
        times.Children.Add(Row("Far north or south", rule));
        times.Children.Add(Theme.Help(_m.RuleHelp));

        // Block
        var block = Group(groups, "Block");
        block.Children.Add(Row("Mode", Theme.Segmented([BlockMode.WholeScreen, BlockMode.CodingApps], Labels.ModeName, s.Mode, v => _m.Apply(x => x with { Mode = v }))));
        block.Children.Add(Theme.Help(Labels.ModeHelp(s.Mode)));
        var lockRow = new DockPanel();
        var lockLabel = new TextBlock { Text = $"{s.LockMinutes} min", Width = 52, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(lockLabel, Dock.Right);
        var lockSlider = new Slider { Minimum = LockPolicy.MinMinutes, Maximum = LockPolicy.MaxMinutes, Value = s.LockMinutes, IsSnapToTickEnabled = true, TickFrequency = 1, Width = 180 };
        System.Windows.Automation.AutomationProperties.SetName(lockSlider, "Break length");
        lockSlider.ValueChanged += (_, e) => lockLabel.Text = $"{(int)e.NewValue} min";
        lockSlider.LostMouseCapture += (_, _) => _m.Apply(x => x with { LockMinutes = (int)lockSlider.Value });
        lockSlider.KeyUp += (_, _) => _m.Apply(x => x with { LockMinutes = (int)lockSlider.Value });
        lockRow.Children.Add(lockLabel);
        lockRow.Children.Add(lockSlider);
        block.Children.Add(Row("Break length", lockRow));
        block.Children.Add(Theme.Help(SettingsModel.BreakHelp));
        var exits = new CheckBox { Content = "Allow emergency exits", IsChecked = s.EmergencyExitsEnabled, FontSize = 13, Margin = new Thickness(0, Theme.S12, 0, 0) };
        exits.Click += (_, _) => _m.SetEmergencyExitsEnabled(exits.IsChecked == true);
        block.Children.Add(exits);
        block.Children.Add(Theme.Help(Copy.AllowExitsHelp));
        block.Children.Add(Theme.Help(_m.EmergencyLine));

        // Blocked apps (v2, PLAN-v2 §1.3): defaults with a switch, the person's own with Remove, then "Add an app…".
        var apps = Group(groups, "Blocked apps");
        apps.Children.Add(Theme.Help(Copy.BlockedAppsHelp));
        foreach (var row in _m.AppRows)
        {
            var line = new DockPanel { Margin = new Thickness(0, Theme.S4, 0, 0) };
            if (row.IsDefault)
            {
                var on = new CheckBox { IsChecked = row.On, VerticalAlignment = VerticalAlignment.Center };
                System.Windows.Automation.AutomationProperties.SetName(on, row.Name);
                var id = row.Id;
                on.Click += (_, _) => _m.SetDefaultApp(id, on.IsChecked == true);
                DockPanel.SetDock(on, Dock.Right);
                line.Children.Add(on);
                line.Children.Add(Theme.Text(row.Name, 13, wrap: false));
            }
            else
            {
                var id = row.Id;
                var remove = Theme.Button("Remove", () => _m.RemoveApp(id));
                DockPanel.SetDock(remove, Dock.Right);
                line.Children.Add(remove);
                var text = new StackPanel();
                text.Children.Add(Theme.Text(row.Name, 13, wrap: false));
                text.Children.Add(new TextBlock { Text = row.Id, FontFamily = Theme.Mono, FontSize = 11, Foreground = Theme.Secondary });
                line.Children.Add(text);
            }
            apps.Children.Add(line);
        }
        var add = Theme.Button("Add an app…", AddApp);
        add.HorizontalAlignment = HorizontalAlignment.Left;
        add.Margin = new Thickness(0, Theme.S12, 0, 0);
        apps.Children.Add(add);
        if (_m.BlockedListEmpty) apps.Children.Add(Theme.Help(Copy.BlockedAppsEmpty));

        // Pause
        var pause = Group(groups, "Pause");
        if (_m.PauseState == PauseKind.Active)
        {
            var choose = new ComboBox { MinWidth = 160 };
            choose.Items.Add(new ComboBoxItem { Content = "Choose…", IsSelected = true, IsEnabled = false });
            foreach (var o in PauseOptions.All) choose.Items.Add(new ComboBoxItem { Content = Labels.PauseName(o), Tag = o });
            choose.SelectionChanged += (_, _) => { if (choose.SelectedItem is ComboBoxItem { Tag: PauseOption o }) _m.Pause(o); };
            pause.Children.Add(Row("Pause Go Pray", choose));
            pause.Children.Add(Theme.Help("For travel, illness or any time you can't pray. Only between prayers."));
        }
        else
        {
            pause.Children.Add(Row(_m.PauseSummary ?? "", Theme.Button("Resume", _m.Resume)));
            pause.Children.Add(Theme.Help("No screen rests while paused. Pausing and resuming only work between prayers."));
        }

        // Athan
        var athan = Group(groups, "Athan");
        var voice = new ComboBox { MinWidth = 220 };
        voice.Items.Add(new ComboBoxItem { Content = "Sunni", IsEnabled = false, FontWeight = FontWeights.SemiBold });
        foreach (var v in VoiceChoices.Sunni) voice.Items.Add(new ComboBoxItem { Content = "   " + v.Name, Tag = v.Voice, IsSelected = v.Voice == s.Voice });
        voice.Items.Add(new ComboBoxItem { Content = "Shia", IsEnabled = false, FontWeight = FontWeights.SemiBold });
        foreach (var v in VoiceChoices.Shia) voice.Items.Add(new ComboBoxItem { Content = "   " + v.Name, Tag = v.Voice, IsSelected = v.Voice == s.Voice });
        voice.SelectionChanged += (_, _) => { if (voice.SelectedItem is ComboBoxItem { Tag: Voice v } && v != _m.Settings.Voice) _m.Apply(x => x with { Voice = v }); };
        athan.Children.Add(Row("Voice", voice));
        athan.Children.Add(Theme.Help(VoiceChoices.FajrNote));
        double draft = s.AthanVolume;
        athan.Children.Add(SetupWindow.VolumeRow(s.AthanVolume, v => draft = v,
            () => { _m.Apply(x => x with { AthanVolume = (float)draft }); _m.Preview.Toggle(_m.Settings.Voice, (float)draft); }, _m.Preview.IsPlaying, Theme.S8));
        var commit = new System.Windows.Input.MouseButtonEventHandler((_, _) => { if (Math.Abs(draft - _m.Settings.AthanVolume) > 0.001) _m.Apply(x => x with { AthanVolume = (float)draft }); });
        athan.PreviewMouseUp += commit;
        if (_m.Preview.Failed) athan.Children.Add(Theme.Help("Couldn't play that one. Try another voice."));

        // General
        var general = Group(groups, "General");
        var login = new CheckBox { Content = "Launch at login", IsChecked = s.LaunchAtLogin, FontSize = 13 };
        login.Click += (_, _) => _m.SetLaunchAtLogin(login.IsChecked == true);
        general.Children.Add(login);
        if (!s.LaunchAtLogin) general.Children.Add(Theme.Help(Copy.LaunchAtLoginNote));
        var updates = new CheckBox { Content = "Check for updates automatically", IsChecked = s.CheckForUpdates, FontSize = 13, Margin = new Thickness(0, Theme.S12, 0, 0) };
        updates.Click += (_, _) => _m.SetCheckForUpdates(updates.IsChecked == true);
        general.Children.Add(updates);
        general.Children.Add(Theme.Help(Copy.CheckForUpdatesHelp));
        var credits = Theme.Link("Credits and thanks", _showCredits);
        credits.Margin = new Thickness(0, Theme.S12, 0, 0);
        general.Children.Add(credits);
    }

    void ChangeCity()
    {
        CityMatch? picked = null;
        var dlg = new Window
        {
            Title = "Change city", Width = 420, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Owner = this, FontFamily = Theme.Body, Background = Brushes.White,
        };
        var p = new StackPanel { Margin = new Thickness(Theme.S24) };
        var h = Theme.Heading("Where do you pray?");
        h.Margin = new Thickness(0, 0, 0, Theme.S16);
        p.Children.Add(h);
        Button? use = null;
        p.Children.Add(new CitySearchView(_m.Search, c => { picked = c; if (use != null) use.IsEnabled = c != null; }));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, Theme.S16, 0, 0) };
        var cancel = Theme.Button("Cancel", dlg.Close);
        cancel.IsCancel = true;
        use = Theme.Button("Use this city", () => { if (picked != null) _m.SetCity(picked); dlg.Close(); }, primary: true);
        use.IsDefault = true;
        use.IsEnabled = false;
        use.Margin = new Thickness(Theme.S8, 0, 0, 0);
        buttons.Children.Add(cancel); buttons.Children.Add(use);
        p.Children.Add(buttons);
        dlg.Content = p;
        dlg.ShowDialog();
    }

    /// <summary>"Add an app…": a running app with a window, or Browse… for an .exe. Never a typed name (PLAN-v2 §1.1 rule 5).</summary>
    void AddApp()
    {
        var dlg = new Window
        {
            Title = "Add an app", Width = 420, Height = 460, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Owner = this, FontFamily = Theme.Body, Background = Brushes.White,
        };
        var p = new DockPanel { Margin = new Thickness(Theme.S24) };
        var h = Theme.Heading("Pick a running app");
        h.Margin = new Thickness(0, 0, 0, Theme.S12);
        DockPanel.SetDock(h, Dock.Top);
        p.Children.Add(h);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, Theme.S16, 0, 0) };
        DockPanel.SetDock(buttons, Dock.Bottom);
        p.Children.Add(buttons);
        var list = new ListBox { MinHeight = 200 };
        foreach (var g in AppHider.RunningApps().GroupBy(a => BlockedApps.Normalize(a.Process)).OrderBy(g => g.Key))
        {
            if (BlockedApps.NeverBlock.Contains(g.Key)) continue;
            var first = g.First();
            var title = g.Select(a => a.Title).FirstOrDefault(t => t.Length > 0) ?? first.Process;
            var item = new StackPanel();
            item.Children.Add(Theme.Text(title.Length > 50 ? title[..50] + "…" : title, 13, wrap: false));
            item.Children.Add(new TextBlock { Text = first.Process + ".exe", FontFamily = Theme.Mono, FontSize = 11, Foreground = Theme.Secondary });
            list.Items.Add(new ListBoxItem { Content = item, Tag = (first.Process, ExeName(first.Process)) });
        }
        p.Children.Add(list);
        var browse = Theme.Button("Browse…", () =>
        {
            var open = new Microsoft.Win32.OpenFileDialog { Filter = "Apps (*.exe)|*.exe", Title = "Choose an app" };
            if (open.ShowDialog(dlg) != true) return;
            string? name = null;
            try { name = System.Diagnostics.FileVersionInfo.GetVersionInfo(open.FileName).FileDescription; } catch (System.IO.IOException) { }
            _m.AddApp(System.IO.Path.GetFileNameWithoutExtension(open.FileName), name);
            dlg.Close();
        });
        var cancel = Theme.Button("Cancel", dlg.Close);
        cancel.IsCancel = true;
        cancel.Margin = new Thickness(Theme.S8, 0, 0, 0);
        var addIt = Theme.Button("Add", () =>
        {
            if (list.SelectedItem is ListBoxItem { Tag: ValueTuple<string, string?> pick }) _m.AddApp(pick.Item1, pick.Item2);
            dlg.Close();
        }, primary: true);
        addIt.IsDefault = true;
        addIt.Margin = new Thickness(Theme.S8, 0, 0, 0);
        buttons.Children.Add(browse); buttons.Children.Add(cancel); buttons.Children.Add(addIt);
        dlg.Content = p;
        dlg.ShowDialog();
    }

    /// <summary>The friendly name of a running process's exe (FileDescription), if Windows lets us read it.</summary>
    static string? ExeName(string process)
    {
        try
        {
            var ps = System.Diagnostics.Process.GetProcessesByName(process);
            try { return ps.Select(x => { try { return x.MainModule?.FileVersionInfo.FileDescription; } catch (Exception) { return null; } }).FirstOrDefault(d => !string.IsNullOrWhiteSpace(d)); }
            finally { foreach (var x in ps) x.Dispose(); }
        }
        catch (Exception) { return null; }
    }

    static StackPanel Group(Panel parent, string title)
    {
        var header = Theme.Text(title, 12, Theme.Secondary, FontWeights.SemiBold);
        header.Margin = new Thickness(4, Theme.S16, 0, Theme.S8);
        parent.Children.Add(header);
        var inner = new StackPanel();
        parent.Children.Add(new Border
        {
            Background = Brushes.White, CornerRadius = new CornerRadius(8), BorderBrush = Theme.Quaternary, BorderThickness = new Thickness(1),
            Padding = new Thickness(Theme.S16, Theme.S12, Theme.S16, Theme.S12), Child = inner,
        });
        return inner;
    }

    static UIElement Row(string label, UIElement control)
    {
        // The label takes what it needs; the control gets the rest and is never clipped (a ComboBox stretches).
        var g = new Grid { Margin = new Thickness(0, Theme.S8, 0, Theme.S4) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var l = Theme.Text(label, 13, wrap: false);
        l.VerticalAlignment = VerticalAlignment.Center;
        l.Margin = new Thickness(0, 0, Theme.S12, 0);
        g.Children.Add(l);
        if (control is ComboBox cb) { cb.MinWidth = 0; cb.HorizontalAlignment = HorizontalAlignment.Stretch; }
        else if (control is FrameworkElement fe) fe.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(control, 1);
        g.Children.Add(control);
        return g;
    }
}
