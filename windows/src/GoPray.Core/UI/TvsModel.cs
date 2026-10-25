// TvsModel.cs — the one TV model (0.3.1): Settings → TVs and Setup's TV step both use it, so the scan, add, check and
// test logic exists once. The network work is the App's TvController behind ITvControlling; every change to the
// stored list goes through the host's normal settings path (SettingsStore.Mutate, which asks the gate first).

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace GoPray.Core;

public sealed class TvsModel
{
    readonly ITvControlling _tv;
    readonly Func<Settings> _settings;
    readonly Func<Func<Settings, Settings>, bool> _apply;
    readonly Func<bool> _isBlocked;
    readonly Action _refusedInBlock;
    readonly IClock _clock;
    readonly IPrayerScheduleProviding? _schedule;
    readonly Dictionary<string, string> _rowLines = new(StringComparer.Ordinal);

    static readonly TimeSpan StepTimeout = TimeSpan.FromSeconds(12);

    /// <param name="apply">The host's normal save path (true = saved).</param>
    /// <param name="refusedInBlock">How the host says "Settings open again after you pray."</param>
    public TvsModel(ITvControlling tv, Func<Settings> settings, Func<Func<Settings, Settings>, bool> apply, Func<bool> isBlocked,
                    Action refusedInBlock, IClock clock, IPrayerScheduleProviding? schedule)
    {
        _tv = tv; _settings = settings; _apply = apply; _isBlocked = isBlocked; _refusedInBlock = refusedInBlock;
        _clock = clock; _schedule = schedule;
    }

    public sealed record TvRow(string Id, string Name, string Host, bool Enabled, bool Installed);

    public IReadOnlyList<TvRow> Rows => _settings().Tvs.Select(t => new TvRow(t.Id, t.Name, t.Host, t.Enabled, t.Installed)).ToList();
    /// <summary>The last scan's TVs that are not on the list yet (an added one drops out).</summary>
    public IReadOnlyList<TvFound> Found { get; private set; } = [];
    /// <summary>A scan is running (Setup draws a skeleton row, never a spinner or a blank).</summary>
    public bool Searching { get; private set; }
    /// <summary>A scan, add or test is running: the buttons wait.</summary>
    public bool Busy { get; private set; }
    /// <summary>The section's line: the last scan's or action's result.</summary>
    public string? Notice { get; private set; }
    public event Action? Changed;

    /// <summary>One TV's line after its last add or test: Ready / not installed / couldn't reach / sent.</summary>
    public string? RowLine(string id) => _rowLines.GetValueOrDefault(id);

    void Say(string? line) { Notice = line; Changed?.Invoke(); }

    bool Refused()
    {
        if (_isBlocked()) { Notice = null; _refusedInBlock(); Changed?.Invoke(); return true; }
        if (Busy) return true;
        return false;
    }

    // MARK: scan

    public async Task<IReadOnlyList<TvFound>> FindTvs()
    {
        if (Refused()) return [];
        Busy = Searching = true; Found = []; Say(null);
        try
        {
            using var cts = new CancellationTokenSource(StepTimeout);
            var d = await _tv.Discover(cts.Token);
            var listed = _settings().Tvs.Select(t => t.Host).ToHashSet(StringComparer.Ordinal);
            Found = d.Found.Where(f => TvRules.IsAllowedHost(f.Host) && !listed.Contains(f.Host)).ToList();
            Notice = d.FirewallBlocks ? Copy.TvFirewall : Found.Count > 0 ? null : d.Found.Count > 0 ? Copy.TvAllListed : Copy.TvNoneFound;
            return Found;
        }
        catch (Exception e) { CoreLog.Notice("tv: find failed: " + e.Message); Notice = Copy.TvNoneFound; return []; }
        finally { Busy = Searching = false; Changed?.Invoke(); }
    }

    // MARK: add + check

    public Task<bool> AddFound(TvFound f) => AddTv(f.Host, f.Name);

    /// <summary>Add a TV by its address (typed, or picked from a scan). Only a private IPv4 literal. Like the Mac it is
    /// added first (the normal save path), then checked: the Go Pray channel and, for a typed address, the name come
    /// from the TV. A TV that can't be reached is kept with the defaults ("dev", installed) and the line says so.</summary>
    public async Task<bool> AddTv(string host, string? name = null)
    {
        host = (host ?? "").Trim();
        if (Refused()) return false;
        if (!TvRules.IsAllowedHost(host)) { Say(Copy.TvHostRefused); return false; }
        if (_settings().Tvs.Any(t => t.Host == host)) { Say(Copy.TvAlreadyListed); return false; }
        if (_settings().Tvs.Count >= TvRules.MaxTvs) { Say(Copy.InvalidLine); return false; }
        var id = Guid.NewGuid().ToString("D").ToUpperInvariant();
        var label = string.IsNullOrWhiteSpace(name) ? TvRules.DefaultName : name!;
        if (!_apply(s => s with { Tvs = s.Tvs.Append(new TvDevice(id, label, TvKind.Roku, host)).ToList() })) { Changed?.Invoke(); return false; }
        Found = Found.Where(f => f.Host != host).ToList();
        Busy = true; Say(null);
        try
        {
            var p = await Refresh(id, nameFromTv: string.IsNullOrWhiteSpace(name));
            Notice = p is not { Reachable: true } ? Copy.TvUnreachable : p.ChannelId == null ? Copy.TvNotInstalled : null;
            _rowLines[id] = p is not { Reachable: true } ? Copy.TvUnreachable : p.ChannelId == null ? Copy.TvNotInstalledHelp : Copy.TvReady;
        }
        finally { Busy = false; Changed?.Invoke(); }
        return true;
    }

    /// <summary>Look the Go Pray channel up on one TV and store it (the Mac's refreshTV). Found → its id, installed;
    /// none → installed false; unreachable → the TV keeps what it had. null when the TV is gone or the look failed.</summary>
    async Task<TvProbe?> Refresh(string id, bool nameFromTv = false)
    {
        if (_settings().Tvs.FirstOrDefault(t => t.Id == id) is not { } tv) return null;
        TvProbe p;
        try
        {
            using var cts = new CancellationTokenSource(StepTimeout);
            p = await _tv.Probe(tv.Host, cts.Token);
        }
        catch (Exception e) { CoreLog.Notice("tv: check failed: " + e.Message); return null; }
        if (!p.Reachable) return p;
        _apply(s => s with
        {
            Tvs = s.Tvs.Select(t => t.Id != id ? t : t with
            {
                ChannelId = p.ChannelId ?? t.ChannelId,
                Installed = p.ChannelId != null,
                Name = nameFromTv && !string.IsNullOrWhiteSpace(p.Name) ? p.Name! : t.Name,
            }).ToList(),
        });
        return p;
    }

    // MARK: edit

    public void SetEnabled(string id, bool on) =>
        _apply(s => s with { Tvs = s.Tvs.Select(t => t.Id == id ? t with { Enabled = on } : t).ToList() });

    public void Remove(string id)
    {
        if (_apply(s => s with { Tvs = s.Tvs.Where(t => t.Id != id).ToList() })) { _rowLines.Remove(id); Say(null); }
    }

    // MARK: test

    /// <summary>Test / "Play a test": look the channel up again (and store it), then launch the next prayer with the
    /// current voice, marked test=1.</summary>
    public async Task<bool> TestTv(string id)
    {
        if (Refused()) return false;
        if (_settings().Tvs.All(t => t.Id != id)) return false;
        Busy = true; Say(null);
        try
        {
            var p = await Refresh(id);
            if (p is not { Reachable: true }) return Line(id, Copy.TvTestFailed, false);
            if (p.ChannelId == null) return Line(id, Copy.TvNotInstalled, false, Copy.TvNotInstalledHelp);
            var tv = _settings().Tvs.First(t => t.Id == id);
            var prayer = _schedule?.NextAthan(_clock.Now)?.Prayer ?? Prayer.Dhuhr;
            using var cts = new CancellationTokenSource(StepTimeout);
            bool ok = await _tv.TestLaunch(tv.Host, tv.ChannelId, prayer, _settings().Voice, cts.Token);
            return Line(id, ok ? Copy.TvTestSent : Copy.TvTestFailed, ok);
        }
        catch (Exception e) { CoreLog.Notice("tv: test failed: " + e.Message); return Line(id, Copy.TvTestFailed, false); }
        finally { Busy = false; Changed?.Invoke(); }
    }

    bool Line(string id, string notice, bool result, string? rowLine = null)
    {
        Notice = notice;
        _rowLines[id] = rowLine ?? notice;
        return result;
    }
}
