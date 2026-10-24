// SetupSettingsModels.cs — the state behind Setup and Settings. Port of UI/SetupViewModel.swift and
// UI/SettingsViewModel.swift (including AthanPreview). Every change goes through SettingsStore.Mutate,
// which asks the gate first; the views only show the gate's answer ("Settings open again after you pray.").

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace GoPray.Core;

/// <summary>The Task Scheduler logon task (Windows counterpart of the Mac's LoginAgentManaging).</summary>
public interface ILogonTask
{
    bool IsRegistered { get; }
    void Register();
    void Unregister();
}

/// <summary>Preview of an Athan through the app's one IAthanPlaying. Never touches OnFinished (the gate owns it),
/// and never stops audio that a block started.</summary>
public sealed class AthanPreview(IAthanPlaying audio, Func<bool> isBlocked)
{
    public bool IsPlaying { get; private set; }
    public bool Failed { get; private set; }
    public event Action? Changed;

    /// <summary>Dhuhr on purpose: Fajr ignores the chosen voice, so it would not preview it.</summary>
    public void Toggle(Voice voice, float volume)
    {
        if (IsPlaying) { Stop(); return; }
        if (isBlocked()) return;
        Failed = false;
        try
        {
            audio.Play(Prayer.Dhuhr, voice, volume);
            IsPlaying = true;
            _ = Watch();
        }
        catch (Exception) { Failed = true; }
        Changed?.Invoke();
    }

    async Task Watch()
    {
        while (IsPlaying)
        {
            await Task.Delay(400);
            // A block took the audio over (or the file ended): let go without stopping it.
            if (isBlocked() || !audio.IsPlaying) { IsPlaying = false; Changed?.Invoke(); }
        }
    }

    /// <summary>Stops our preview only, never a block's Athan.</summary>
    public void Stop()
    {
        if (IsPlaying && !isBlocked()) audio.Stop();
        IsPlaying = false;
        Changed?.Invoke();
    }
}

public enum SetupStep { City, Method, Mode, Done }

/// <summary>Nothing is saved until the last step: one Mutate writes the city, method, madhab, mode, volume and
/// launch-at-login together with SetupComplete = true. That false→true flip tells the gate not to block the
/// prayer that is already open (CONTRACT-NOTES #28).</summary>
public sealed class SetupModel
{
    readonly SettingsStore _store;
    readonly IPrayerScheduleProviding _schedule;
    readonly IClock _clock;
    readonly ILogonTask _logon;
    readonly Func<TimeZoneInfo> _zone;
    bool _methodTouched;
    CityMatch? _picked;
    string _method = "muslimWorldLeague";

    public SetupModel(SettingsStore store, IPrayerScheduleProviding schedule, IClock clock, IAthanPlaying audio,
                      ILogonTask logon, ICityGeocoding geocoder, BlockGate gate, Func<TimeZoneInfo>? zone = null)
    {
        _store = store; _schedule = schedule; _clock = clock; _logon = logon;
        _zone = zone ?? (() => TimeZoneInfo.Local);
        Search = new CitySearchModel(geocoder);
        Preview = new AthanPreview(audio, () => gate.IsBlocked);
    }

    public CitySearchModel Search { get; }
    public AthanPreview Preview { get; }
    public SetupStep Step { get; private set; } = SetupStep.City;
    public int Madhab { get; set; } = 1;
    public BlockMode Mode { get; set; } = BlockMode.WholeScreen;
    public double Volume { get; set; } = SettingsRules.Defaults.AthanVolume;
    public bool LaunchAtLogin { get; set; } = true;
    public string? LoginNote { get; private set; }
    public string? Notice { get; private set; }
    public string? NextLine { get; private set; }

    public CityMatch? PickedCity
    {
        get => _picked;
        set
        {
            _picked = value;
            // The suggestion follows the country until the person picks a method themselves.
            if (value != null && !_methodTouched) _method = Labels.SuggestedMethod(value.CountryCode);
        }
    }

    public string Method
    {
        get => _method;
        set { _method = value; _methodTouched = true; }
    }

    public int StepNumber => Math.Min((int)Step + 1, 3);
    public bool CanGoNext => Step switch { SetupStep.City => PickedCity != null, SetupStep.Done => false, _ => true };

    public string Title => Step switch
    {
        SetupStep.City => "Where do you pray?",
        SetupStep.Method => "How are your times worked out?",
        SetupStep.Mode => "How should Go Pray stop you?",
        _ => "You're set.",
    };

    /// <summary>The prayer whose colours dress the header: the next one, else Dhuhr.</summary>
    public Prayer HeaderPrayer => _schedule.NextAthan(_clock.Now)?.Prayer ?? Prayer.Dhuhr;

    public void Next()
    {
        Notice = null;
        switch (Step)
        {
            case SetupStep.City: if (PickedCity != null) Step = SetupStep.Method; break;
            case SetupStep.Method: Step = SetupStep.Mode; break;
            case SetupStep.Mode: Finish(); break;
        }
    }

    public void Back()
    {
        if (Step is SetupStep.City or SetupStep.Done) return;
        Preview.Stop();
        Step = Step - 1;
    }

    void Finish()
    {
        if (PickedCity is not { } city) { Step = SetupStep.City; return; }
        Preview.Stop();
        try { _store.Authorize(); } catch (SettingsBlockedException) { Notice = Copy.BlockedLine; return; }
        bool login = false;
        if (LaunchAtLogin)
        {
            try { _logon.Register(); login = true; }
            catch (Exception) { LoginNote = "Couldn't turn on launch at login. You can try again in Settings."; }
        }
        try
        {
            _store.Mutate(s => s with
            {
                City = city.Label, Latitude = city.Latitude, Longitude = city.Longitude,
                Method = _method, Madhab = Madhab, Mode = Mode, AthanVolume = (float)Volume,
                LaunchAtLogin = login, SetupComplete = true,
            });
        }
        catch (SettingsBlockedException) { Notice = Copy.BlockedLine; return; }
        catch (Exception) { Notice = Copy.InvalidLine; return; }
        NextLine = _schedule.NextAthan(_clock.Now) is { } n
            ? $"Next: {Labels.PrayerName(n.Prayer)} at {TimeText.Clock(n.At, _zone())}."
            : "We couldn't work out times for that place. Check the city in Settings.";
        Step = SetupStep.Done;
    }
}

public enum PauseKind { Active, Until, UntilResumed }

public sealed class SettingsModel
{
    readonly SettingsStore _store;
    readonly BlockGate _gate;
    readonly IClock _clock;
    readonly ILogonTask _logon;
    readonly Func<TimeZoneInfo> _zone;
    readonly IReadOnlyList<(string Id, string Name)> _defaults;

    public SettingsModel(SettingsStore store, BlockGate gate, IClock clock, IAthanPlaying audio, ILogonTask logon,
                         ICityGeocoding geocoder, Func<TimeZoneInfo>? zone = null, IReadOnlyList<(string Id, string Name)>? defaultApps = null)
    {
        _store = store; _gate = gate; _clock = clock; _logon = logon;
        _zone = zone ?? (() => TimeZoneInfo.Local);
        _defaults = defaultApps ?? [];
        Search = new CitySearchModel(geocoder);
        Preview = new AthanPreview(audio, () => gate.IsBlocked);
    }

    public CitySearchModel Search { get; }
    public AthanPreview Preview { get; }
    public Settings Settings => _store.Settings;
    public bool IsBlocked => _gate.IsBlocked;
    /// <summary>One short line about the last thing that did not work. Cleared by the next success.</summary>
    public string? Notice { get; private set; }
    public event Action? Changed;

    /// <summary>Applies a change through the store. A refusal becomes one line, not an alert.</summary>
    public bool Apply(Func<Settings, Settings> change)
    {
        try { _store.Mutate(change); Notice = null; return true; }
        catch (SettingsBlockedException) { Notice = Copy.BlockedLine; }
        catch (Exception) { Notice = Copy.InvalidLine; }
        finally { Changed?.Invoke(); }
        return false;
    }

    public void SetCity(CityMatch m) => Apply(s => s with { City = m.Label, Latitude = m.Latitude, Longitude = m.Longitude });

    /// <summary>The logon task is a side effect of the setting, so the gate is asked before it runs.</summary>
    public void SetLaunchAtLogin(bool on)
    {
        try { _store.Authorize(); } catch (SettingsBlockedException) { Notice = Copy.BlockedLine; Changed?.Invoke(); return; }
        const string failed = "Couldn't change launch at login. Try again in a moment.";
        if (on)
        {
            try { _logon.Register(); } catch (Exception) { Notice = failed; Changed?.Invoke(); return; }
            Apply(s => s with { LaunchAtLogin = true });
        }
        else
        {
            if (!Apply(s => s with { LaunchAtLogin = false })) return;
            try { _logon.Unregister(); }
            catch (Exception) { Apply(s => s with { LaunchAtLogin = true }); Notice = failed; Changed?.Invoke(); }
        }
    }

    public PauseKind PauseState =>
        Settings.PausedUntil is not { } until || until <= _clock.Now ? PauseKind.Active
        : until == DateTimes.DistantFuture ? PauseKind.UntilResumed : PauseKind.Until;

    public void Pause(PauseOption o)
    {
        try { _store.Pause(o, _clock.Now, _zone()); Notice = null; }
        catch (SettingsBlockedException) { Notice = Copy.BlockedLine; }
        catch (Exception) { Notice = Copy.InvalidLine; }
        Changed?.Invoke();
    }

    public void Resume()
    {
        try { _store.Resume(_clock.Now); Notice = null; }
        catch (SettingsBlockedException) { Notice = Copy.BlockedLine; }
        catch (Exception) { Notice = Copy.InvalidLine; }
        Changed?.Invoke();
    }

    public string? PauseSummary => PauseState switch
    {
        PauseKind.Until => "Paused until " + TimeText.Day(Settings.PausedUntil!.Value, _zone()),
        PauseKind.UntilResumed => "Paused until you resume",
        _ => null,
    };

    // MARK: v2 — Blocked apps (PLAN-v2 §1.3). Every change goes through Apply → Mutate → the gate.

    /// <summary>One row of the list. Default rows have a switch; the person's own rows have Remove.</summary>
    public sealed record AppRow(string Id, string Name, bool IsDefault, bool On);

    public IReadOnlyList<AppRow> AppRows
    {
        get
        {
            var off = Settings.DisabledDefaultApps.Select(BlockedApps.Normalize).ToHashSet(StringComparer.Ordinal);
            var rows = _defaults.Select(d => new AppRow(BlockedApps.Normalize(d.Id), d.Name, true, !off.Contains(BlockedApps.Normalize(d.Id)))).ToList();
            rows.AddRange(Settings.CustomApps.Where(c => c.Platform == BlockedApps.Current).Select(c => new AppRow(c.Id, c.Name, false, true)));
            return rows;
        }
    }

    /// <summary>True when Coding apps mode would rest nothing (honour system, PLAN-v2 §1.1 rule 7).</summary>
    public bool BlockedListEmpty => BlockedApps.Effective(Settings, _defaults.Select(d => d.Id)).Count == 0;

    public void SetDefaultApp(string id, bool on)
    {
        var n = BlockedApps.Normalize(id);
        Apply(s => s with
        {
            DisabledDefaultApps = on
                ? s.DisabledDefaultApps.Where(x => BlockedApps.Normalize(x) != n).ToList()
                : s.DisabledDefaultApps.Append(n).ToList(),
        });
    }

    /// <summary>Add a picked app (an exe name or a running window's process). Never-blockable picks and duplicates
    /// only set the notice line. A default that was turned off is turned back on.</summary>
    public bool AddApp(string processOrExe, string? name)
    {
        var id = BlockedApps.Normalize(processOrExe);
        if (id.Length == 0) return false;
        if (BlockedApps.IsNeverBlock(id)) { Notice = Copy.CantRestThat; Changed?.Invoke(); return false; }
        var row = AppRows.FirstOrDefault(r => r.Id == id);
        if (row is { IsDefault: true, On: false }) { SetDefaultApp(id, true); return true; }
        if (row != null) { Notice = Copy.AlreadyListed; Changed?.Invoke(); return false; }
        var label = string.IsNullOrWhiteSpace(name) ? processOrExe.Trim() : name.Trim();
        return Apply(s => s with { CustomApps = s.CustomApps.Append(new CustomApp(id, label, BlockedApps.Current)).ToList() });
    }

    public void RemoveApp(string id)
    {
        var n = BlockedApps.Normalize(id);
        Apply(s => s with { CustomApps = s.CustomApps.Where(c => !(c.Platform == BlockedApps.Current && BlockedApps.Normalize(c.Id) == n)).ToList() });
    }

    // MARK: v2 — Emergency exits (PLAN-v2 §9.2) and updates (§8.1 rule 8)

    public void SetEmergencyExitsEnabled(bool on) => Apply(s => s with { EmergencyExitsEnabled = on });
    public string EmergencyLine => Copy.EmergencyLine(Settings.EmergencyExitsEnabled, _gate.EmergencyExitsRemaining);
    public void SetCheckForUpdates(bool on) => Apply(s => s with { CheckForUpdates = on });

    /// <summary>"Automatic (Seventh of the night)" — the high-latitude rule the library would pick here.</summary>
    public string AutomaticRuleLabel
    {
        get
        {
            var auto = Settings.Latitude > 48 ? "seventhOfTheNight" : "middleOfTheNight";
            return $"Automatic ({Labels.RuleName(auto)})";
        }
    }

    public string RuleHelp => "For cities where the sky never gets fully dark in summer. " + Labels.RuleHelp(PrayerSchedule.EffectiveHighLatitudeRule(Settings));
    public static string BreakHelp => $"How long the screen rests after each Athan. Never under {LockPolicy.MinMinutes} minutes. A new length starts at the next prayer.";
}
