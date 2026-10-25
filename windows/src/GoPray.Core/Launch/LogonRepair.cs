// LogonRepair.cs — what a running copy does about the "Go Pray" task when it starts (0.3.2, PM ruling 2026-10-24).
// The audit's zero-copies paths: (#4) an interrupted installer leaves the task DISABLED (its pause is never undone),
// and (#5) the task runs an exe that is gone (Launch at login was turned on from a copy that was later deleted).
// Pure, so every case is unit-tested; GoPray.App/App/AppHost.RepairLogonTask reads the task and carries it out.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace GoPray.Core;

/// <summary>The registered task as schtasks reports it: enabled, and the exe its one action runs.</summary>
public sealed record LogonTaskInfo(bool Enabled, string Command);

public enum LogonRepairAction
{
    /// <summary>Nothing to do (or nothing we may do).</summary>
    None,
    /// <summary>No task although launch at login is on: create it (pointing at this exe).</summary>
    Register,
    /// <summary>The task runs another exe: create it again, pointing at this one (it is created enabled).</summary>
    ReRegister,
    /// <summary>The task is right but switched off: `schtasks /change /enable`.</summary>
    Enable,
}

public static class LogonRepair
{
    /// <summary>Only after setup and only with launch at login on (off = the person removed the task on purpose:
    /// leave it alone). Re-point the task at this exe when the old exe no longer exists, or when this exe is the
    /// installed copy (an installed copy beats a stray one in Downloads; a stray copy never takes the task from an
    /// installed one that still exists). Otherwise re-enable a disabled task.</summary>
    public static LogonRepairAction Decide(bool setupComplete, bool launchAtLogin, LogonTaskInfo? task, string thisExe,
                                           bool thisIsInstalled, Func<string, bool> fileExists)
    {
        if (!setupComplete || !launchAtLogin) return LogonRepairAction.None;
        if (task == null) return LogonRepairAction.Register;
        if (!SamePath(task.Command, thisExe) && (thisIsInstalled || !fileExists(Unquote(task.Command))))
            return LogonRepairAction.ReRegister;
        return task.Enabled ? LogonRepairAction.None : LogonRepairAction.Enable;
    }

    /// <summary>The installer's per-user location ({localappdata}\Programs\Go Pray), or a Program Files "Go Pray" folder.</summary>
    public static bool IsInstalledPath(string exe, IEnumerable<string> installDirs) =>
        installDirs.Where(d => !string.IsNullOrEmpty(d)).Any(d => SamePath(Path.GetDirectoryName(Full(exe)) ?? "", d));

    public static string Unquote(string s) => (s ?? "").Trim().Trim('"').Trim();

    static string Full(string p)
    {
        try { return Path.GetFullPath(Unquote(p)); } catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return Unquote(p); }
    }

    /// <summary>Windows paths: case-insensitive, quotes and a trailing separator ignored, relative parts resolved.</summary>
    public static bool SamePath(string a, string b) =>
        string.Equals(Full(a).TrimEnd('\\', '/'), Full(b).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);
}
