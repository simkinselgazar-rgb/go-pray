// CitySearchView.cs — the city search with its skeleton (spec §12), shared by Setup and Settings.
// Port of CitySearchView in UI/SetupViewComponents.swift. The result area has a fixed height: skeleton rows
// (a 140 pt bar over an 80 pt bar) swap for results in place, so nothing shifts. No spinner in content.

using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using GoPray.Core;

namespace GoPray.App.UI;

internal sealed class CitySearchView : StackPanel
{
    const double RowHeight = 46, ListHeight = RowHeight * 4;
    readonly CitySearchModel _m;
    readonly Action<CityMatch?> _picked;
    readonly TextBox _query = new() { Height = 30, FontSize = 13, Padding = new Thickness(6, 4, 6, 4) };
    readonly TextBox _coords = new() { Height = 30, FontFamily = Theme.Mono, FontSize = 12, Padding = new Thickness(6, 4, 6, 4) };
    readonly ContentControl _area = new() { Height = ListHeight };
    readonly TextBlock _coordHint = Theme.Help(CitySearchModel.CoordinateHint);
    readonly Button _switch;
    readonly Dispatcher _ui = Dispatcher.CurrentDispatcher;
    CityMatch? _selection;

    public CitySearchView(CitySearchModel model, Action<CityMatch?> picked)
    {
        _m = model;
        _picked = picked;
        System.Windows.Automation.AutomationProperties.SetName(_query, "City");
        System.Windows.Automation.AutomationProperties.SetName(_coords, "Latitude and longitude");
        _query.TextChanged += (_, _) => { Select(null); _m.QueryChanged(_query.Text); };
        _query.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter && _m.State == SearchState.Results && _selection == null) Select(_m.Results[0]); };
        _coords.TextChanged += (_, _) =>
        {
            _m.CoordinateText = _coords.Text;
            _coordHint.Text = _coords.Text.Length == 0 || _m.CoordinateMatch != null ? CitySearchModel.CoordinateHint : CitySearchModel.CoordinateError;
            Select(_m.CoordinateMatch);
        };
        _m.Changed += () => _ui.BeginInvoke(RenderArea);
        _switch = Theme.Link("Enter coordinates instead", Toggle);
        _switch.Margin = new Thickness(0, Theme.S12, 0, 0);
        Render();
        Loaded += (_, _) => _query.Focus();
    }

    void Toggle()
    {
        _m.CoordinateMode = !_m.CoordinateMode;
        Select(null);
        Render();
    }

    void Select(CityMatch? c)
    {
        _selection = c;
        _picked(c);
    }

    void Render()
    {
        Children.Clear();
        if (_m.CoordinateMode)
        {
            Children.Add(_coords);
            _coordHint.Margin = new Thickness(0, Theme.S8, 0, 0);
            Children.Add(_coordHint);
            Children.Add(new Border { Height = ListHeight - 4 });
        }
        else
        {
            Children.Add(_query);
            _area.Margin = new Thickness(0, Theme.S8, 0, 0);
            Children.Add(_area);
            RenderArea();
        }
        ((TextBlock)_switch.Content).Text = _m.CoordinateMode ? "Search for a city instead" : "Enter coordinates instead";
        Children.Add(_switch);
    }

    void RenderArea()
    {
        switch (_m.State)
        {
            case SearchState.Searching:
                var sk = new StackPanel();
                for (int i = 0; i < 3; i++) sk.Children.Add(SkeletonRow());
                System.Windows.Automation.AutomationProperties.SetName(sk, "Searching");
                _area.Content = sk;
                break;
            case SearchState.Results:
                var list = new ListBox { Height = ListHeight, BorderThickness = new Thickness(1), BorderBrush = Theme.Quaternary };
                foreach (var r in _m.Results)
                {
                    var item = new StackPanel { Margin = new Thickness(4, 4, 4, 4) };
                    item.Children.Add(Theme.Text(r.Title, 13, weight: FontWeights.SemiBold));
                    if (r.Subtitle.Length > 0) item.Children.Add(Theme.Text(r.Subtitle, 12, Theme.Secondary));
                    list.Items.Add(new ListBoxItem { Content = item, Tag = r, MinHeight = RowHeight - 8 });
                }
                list.SelectionChanged += (_, _) => Select((list.SelectedItem as ListBoxItem)?.Tag as CityMatch);
                _area.Content = list;
                break;
            case SearchState.NoMatch:
                _area.Content = Theme.Help(CitySearchModel.NoMatchLine);
                break;
            case SearchState.Offline:
                _area.Content = Theme.Help(CitySearchModel.OfflineLine);
                break;
            default:
                _area.Content = null;
                break;
        }
    }

    static UIElement SkeletonRow()
    {
        var p = new StackPanel { Height = RowHeight, Margin = new Thickness(Theme.S12, 8, 0, 0) };
        var a = new Border { Width = 140, Height = 12, CornerRadius = new CornerRadius(4), Background = Theme.Quaternary, HorizontalAlignment = HorizontalAlignment.Left };
        var b = new Border { Width = 80, Height = 9, CornerRadius = new CornerRadius(4), Background = Theme.Quaternary, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) };
        p.Children.Add(a); p.Children.Add(b);
        if (SystemParameters.ClientAreaAnimation)          // slow shimmer, off when Windows animations are off
        {
            var pulse = new DoubleAnimation(1, 0.55, TimeSpan.FromSeconds(1.4)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever };
            p.BeginAnimation(OpacityProperty, pulse);
        }
        return p;
    }
}
