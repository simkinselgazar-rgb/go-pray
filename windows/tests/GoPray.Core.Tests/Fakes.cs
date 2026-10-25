// Fakes.cs — recording fakes of the core interfaces. Port of GoPrayTests/Core/Fakes.swift.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using GoPray.Core;

namespace GoPray.Core.Tests;

/// <summary>A fixed timetable, the same every UTC day:
/// Fajr 05:00, sunrise 06:30, Dhuhr 12:00, Asr 15:30, Maghrib 18:00, Isha 19:30.</summary>
public sealed class FakeSchedule : IPrayerScheduleProviding
{
    public static readonly DateTime Day0 = new(2026, 10, 22, 0, 0, 0, DateTimeKind.Utc);
    public static readonly (Prayer Prayer, double Offset)[] Offsets =
    [
        (Prayer.Fajr, 5 * 3600), (Prayer.Dhuhr, 12 * 3600), (Prayer.Asr, 15.5 * 3600), (Prayer.Maghrib, 18 * 3600), (Prayer.Isha, 19.5 * 3600),
    ];
    public const double SunriseOffset = 6.5 * 3600;

    /// <summary>false → every call returns null (bad lat/lon, library error).</summary>
    public bool Valid { get; set; } = true;

    public static DateTime At(Prayer prayer, int day = 0) =>
        Day0.AddSeconds(day * 86_400 + Offsets.First(o => o.Prayer == prayer).Offset);
    public static DateTime Sunrise(int day = 0) => Day0.AddSeconds(day * 86_400 + SunriseOffset);

    static List<(Prayer, DateTime)> Athans() =>
        Enumerable.Range(-2, 6).SelectMany(d => Offsets.Select(o => (o.Prayer, At(o.Prayer, d)))).OrderBy(x => x.Item2).ToList();

    static int DayIndex(DateTime t) => (int)Math.Floor((t - Day0).TotalSeconds / 86_400);

    public DayTimes? Times(DateTime day)
    {
        if (!Valid) return null;
        int d = DayIndex(day);
        return new DayTimes(At(Prayer.Fajr, d), Sunrise(d), At(Prayer.Dhuhr, d), At(Prayer.Asr, d), At(Prayer.Maghrib, d), At(Prayer.Isha, d));
    }

    public PrayerWindow? Window(DateTime t)
    {
        if (!Valid) return null;
        var all = Athans();
        int i = all.FindLastIndex(a => a.Item2 <= t);
        if (i < 0 || i + 1 >= all.Count) return null;
        var (p, at) = all[i];
        var end = p == Prayer.Fajr ? Sunrise(DayIndex(at)) : all[i + 1].Item2;
        return new PrayerWindow(p, at, end);
    }

    public (Prayer Prayer, DateTime At)? NextAthan(DateTime t)
    {
        if (!Valid) return null;
        foreach (var a in Athans()) if (a.Item2 > t) return (a.Item1, a.Item2);
        return null;
    }
}

public sealed class FakeShield : IShieldPresenting
{
    public IShieldDelegate? Delegate { get; set; }
    public List<ShieldContext> Shows { get; } = [];
    public List<ShieldContext> Updates { get; } = [];
    public int DismissCount { get; private set; }
    public List<EndKind> DismissKinds { get; } = [];
    public int TearDownCount { get; private set; }
    /// <summary>true: dismiss completes at once. false: held in PendingDismiss.</summary>
    public bool AutoCompleteDismiss { get; set; } = true;
    public Action? PendingDismiss { get; private set; }

    public void Show(ShieldContext ctx) => Shows.Add(ctx);
    public void Update(ShieldContext ctx) => Updates.Add(ctx);
    public void Dismiss(Action thenIdle, EndKind kind = EndKind.Confirmed)
    {
        DismissCount++;
        DismissKinds.Add(kind);
        if (AutoCompleteDismiss) thenIdle(); else PendingDismiss = thenIdle;
    }
    public void TearDown() => TearDownCount++;
}

public sealed class FakeAudioException : Exception;

public sealed class FakeAudio : IAthanPlaying
{
    public bool IsPlaying { get; private set; }
    public Action? OnFinished { get; set; }
    public List<(Prayer Prayer, Voice Voice, float Volume)> Plays { get; } = [];
    public int StopCount { get; private set; }
    public bool ThrowOnPlay { get; set; }
    int _remaining;

    public void Play(Prayer prayer, Voice voice, float volume)
    {
        if (ThrowOnPlay) throw new FakeAudioException();
        Plays.Add((prayer, voice, volume));
        IsPlaying = true;
        _remaining = 180_000;
    }
    public void Stop() { StopCount++; IsPlaying = false; _remaining = 0; }
    public int RemainingMs() => _remaining;
    public void Finish() { IsPlaying = false; _remaining = 0; OnFinished?.Invoke(); }
}

public sealed class FakeHider : IAppHiding
{
    public Action<string>? OnReHide { get; set; }
    public int StartCount { get; private set; }
    public int StopCount { get; private set; }
    /// <summary>The ids of every Start, in order.</summary>
    public List<IReadOnlySet<string>> Started { get; } = [];
    public void Start(IReadOnlySet<string> ids) { StartCount++; Started.Add(ids); }
    public void Stop() => StopCount++;
}

/// <summary>0.3.0: records every block-start TV hand-off. Throw = a controller bug (the block must not care).</summary>
public sealed class FakeTvs : ITvLaunching
{
    public List<(IReadOnlyList<TvDevice> Tvs, Prayer Prayer, Voice Voice)> Calls { get; } = [];
    public bool Throw { get; set; }
    public void AthanStarted(IReadOnlyList<TvDevice> tvs, Prayer prayer, Voice voice)
    {
        Calls.Add((tvs, prayer, voice));
        if (Throw) throw new InvalidOperationException("tv controller bug");
    }
}

public static class TestSettings
{
    public static Settings Test(BlockMode mode = BlockMode.WholeScreen, bool setupComplete = true,
                                int lockMinutes = LockPolicy.DefaultMinutes, DateTime? pausedUntil = null) => new()
    {
        City = "Testville", Latitude = 40.7, Longitude = -74.0, Method = "moonsightingCommittee", Madhab = 1,
        HighLatitudeRule = null, Mode = mode, Voice = Voice.Sunni("test-voice"), AthanVolume = 0.8f,
        LaunchAtLogin = false, SetupComplete = setupComplete, ReduceMotion = false,
        LockMinutes = lockMinutes, PausedUntil = pausedUntil,
    };
}

/// <summary>One gate + its fakes over a temp state directory. Relaunch() builds a new gate from the same
/// directory, like a crash + Task Scheduler restart.</summary>
public sealed class Harness : IDisposable
{
    public string Dir { get; }
    public FakeClock Clock { get; }
    public FakeSchedule Schedule { get; } = new();
    public Settings Settings { get; set; }
    public FakeShield Shield { get; private set; } = new();
    public FakeAudio Audio { get; private set; } = new();
    public FakeHider Hider { get; private set; } = new();
    /// <summary>Kept across Relaunch, so a test can count every call a block ever made.</summary>
    public FakeTvs Tvs { get; } = new();
    public BlockGate Gate { get; private set; } = null!;
    /// <summary>v2: the compiled-in defaults the gate captures from (a small fixed list).</summary>
    public static readonly string[] Defaults = ["Code", "cursor", "chrome", "WindowsTerminal"];
    public string MirrorDir => Path.Combine(Dir, "mirror");
    public EmergencyLedger Ledger => new(Dir, MirrorDir, TimeZoneInfo.Utc);

    public Harness(DateTime start, Settings? settings = null, string? dir = null)
    {
        Dir = dir ?? Path.Combine(Path.GetTempPath(), "gopray-tests-" + Guid.NewGuid().ToString("N"));
        Clock = new FakeClock(start);
        Settings = settings ?? TestSettings.Test();
        MakeGate();
    }

    public void MakeGate() =>
        Gate = new BlockGate(Clock, new StateStore(Dir), Schedule, Shield, Audio, Hider, () => Settings,
                             leavingTimeout: TimeSpan.FromMilliseconds(200), systemReduceMotion: () => false,
                             ledger: Ledger, defaultApps: Defaults, tvs: Tvs);

    /// <summary>New process: fresh fakes, same file on disk, then the launch re-evaluation.</summary>
    public void Relaunch()
    {
        Shield = new FakeShield(); Audio = new FakeAudio(); Hider = new FakeHider();
        MakeGate();
        Gate.Reevaluate(ReevalReason.Launch);
    }

    public string StateFile => Path.Combine(Dir, "state.json");

    public BlockStateFile DiskState() => BlockStateFile.Decode(File.ReadAllBytes(StateFile));

    public List<string> CorruptFiles() =>
        Directory.Exists(Dir) ? Directory.GetFiles(Dir).Select(f => Path.GetFileName(f)).Where(n => n.StartsWith("state.corrupt-")).ToList() : [];

    public void Dispose()
    {
        try { Directory.Delete(Dir, recursive: true); } catch { /* temp */ }
    }
}
