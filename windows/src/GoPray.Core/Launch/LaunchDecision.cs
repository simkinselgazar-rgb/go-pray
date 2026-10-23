// LaunchDecision.cs — one Go Pray at a time, and the ONE place that decides whether a launch runs.
// Windows replacement for App/SingleInstance.swift (PLAN.md §2 "Single instance", Phase 0 bug 1,
// PM ruling 2026-10-23).
//
// How the app gets started:
//   - by hand (Start menu, the installer's "Launch Go Pray", a double-click): no argument;
//   - by the Task Scheduler task "Go Pray", whose ONE action is `GoPray.exe --tick`. The task has a
//     logon trigger and a time trigger repeating every minute (MultipleInstancesPolicy = IgnoreNew),
//     because RestartOnFailure never fires after Task Manager's End task (spike Q3).
//
// The single instance is a named mutex, `Local\GoPray.Instance` (Local\ = this logon session only).
//
// A tick runs only when (a) state.json holds an open block, or (b) the user did NOT quit on purpose
// in this logon session. A deliberate Quit (allowed only with no block up: gate.ShouldAllowQuit) writes
// launch.json { "userQuitLogonId": <this logon session's id> }. A tick in a NEW logon session sees a
// different id, so "cleared at the next logon start" needs no trigger-specific argument (one task
// action serves both triggers). A launch by hand clears the flag.

using System;
using System.IO;
using System.Text.Json;

namespace GoPray.Core;

public enum LaunchKind
{
    /// <summary>Opened by the person (no argument).</summary>
    ByHand,
    /// <summary>Started by the Task Scheduler task (<c>--tick</c>): at logon and every minute.</summary>
    Tick,
}

public enum LaunchPlan
{
    /// <summary>We hold the mutex (or there is no usable mutex): wire the gate, tray and shield.</summary>
    Wire,
    /// <summary>A tick that has nothing to do: exit 0 at once, no UI.</summary>
    ExitQuietly,
    /// <summary>Opened by hand while another copy runs: ask it to show itself (unless blocked) and exit 0.</summary>
    AskHolderToShowAndExit,
}

public readonly record struct LaunchFacts(
    LaunchKind Kind,
    /// <summary>true = we created/own the mutex, false = another copy holds it, null = the mutex could not
    /// be created (a broken mutex must never stop the app: decide as if we hold it).</summary>
    bool? GotMutex,
    /// <summary>StateStore.PeekHasOpenBlock().</summary>
    bool OpenBlockInState,
    /// <summary>launch.json's userQuitLogonId, or null.</summary>
    string? UserQuitLogonId,
    /// <summary>This logon session's id (the token's AuthenticationId LUID), or null if unknown.</summary>
    string? CurrentLogonId);

public static class LaunchDecision
{
    public const string TickArgument = "--tick";
    public const string MutexName = @"Local\GoPray.Instance";
    /// <summary>RegisterWindowMessage name the loser broadcasts so the holder opens Setup/Settings.</summary>
    public const string ShowMessageName = "GoPray.Show";
    /// <summary>Broadcast by `--uninstall-task` (the uninstaller): the holder quits, but only when no block is up
    /// (gate.ShouldAllowQuit). During a block it stays, so the uninstaller cannot remove the running exe until the
    /// block ends: uninstalling is never a quicker way out than the block itself.</summary>
    public const string QuitMessageName = "GoPray.Quit";

    public static LaunchKind KindOf(string[] args) =>
        Array.IndexOf(args, TickArgument) >= 0 ? LaunchKind.Tick : LaunchKind.ByHand;

    /// <summary>The whole rule. Pure, so it is unit-tested case by case.</summary>
    public static LaunchPlan Decide(LaunchFacts f)
    {
        if (f.GotMutex == false)
            return f.Kind == LaunchKind.ByHand ? LaunchPlan.AskHolderToShowAndExit : LaunchPlan.ExitQuietly;
        if (f.Kind == LaunchKind.ByHand) return LaunchPlan.Wire;
        if (f.OpenBlockInState) return LaunchPlan.Wire;                         // (a) a block is open: resume it
        return QuitThisSession(f) ? LaunchPlan.ExitQuietly : LaunchPlan.Wire;   // (b) not quit on purpose
    }

    /// <summary>The person quit on purpose in this same logon session. An unknown current id never
    /// matches, so the app runs (fail toward running: it never blocks without a prayer anyway).</summary>
    public static bool QuitThisSession(LaunchFacts f) =>
        f.UserQuitLogonId is { Length: > 0 } quit && f.CurrentLogonId is { Length: > 0 } cur
        && string.Equals(quit, cur, StringComparison.Ordinal);

    /// <summary>After Wire: should launch.json's flag be cleared? (A hand launch, or a new logon session.)</summary>
    public static bool ShouldClearUserQuit(LaunchFacts f) =>
        f.UserQuitLogonId != null && (f.Kind == LaunchKind.ByHand || !QuitThisSession(f));
}

/// <summary>launch.json next to state.json. Separate file so state.json stays exactly the Mac's v1 shape.</summary>
public sealed class LaunchStateStore(string directory)
{
    public string FilePath => Path.Combine(directory, "launch.json");

    /// <summary>The logon id of a deliberate Quit, or null (missing or unreadable file = not quit).</summary>
    public string? ReadUserQuitLogonId()
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllBytes(FilePath));
            return doc.RootElement.TryGetProperty("userQuitLogonId", out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        }
        catch { return null; }
    }

    /// <summary>Quit was chosen. Callers check gate.ShouldAllowQuit() first; this refuses a block anyway.</summary>
    public void RecordUserQuit(string logonId, BlockGate gate)
    {
        if (!gate.ShouldAllowQuit()) throw new InvalidOperationException("Quit is not allowed during a block.");
        Directory.CreateDirectory(directory);
        var tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(new { userQuitLogonId = logonId }));
        File.Move(tmp, FilePath, overwrite: true);
    }

    public void ClearUserQuit()
    {
        try { File.Delete(FilePath); } catch { /* nothing to clear */ }
    }
}
