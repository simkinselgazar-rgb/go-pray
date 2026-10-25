// LogonRepairTests.cs — 0.3.2 (PM ruling 2026-10-24, the zero-copies audit): what a starting copy does about the
// "Go Pray" task (#4 a disabled task, #5 a task that runs another exe), and the DEBUG-only mutex name (#2).

using System;
using System.IO;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

public class LogonRepairTests
{
    const string Installed = @"C:\Users\a\AppData\Local\Programs\Go Pray\GoPray.exe";
    const string Downloads = @"C:\Users\a\Downloads\GoPray\GoPray.exe";
    static readonly string[] InstallDirs = [@"C:\Users\a\AppData\Local\Programs\Go Pray", @"C:\Program Files\Go Pray"];

    static LogonRepairAction Decide(LogonTaskInfo? task, string thisExe, bool launchAtLogin = true, bool setupComplete = true, params string[] existing) =>
        LogonRepair.Decide(setupComplete, launchAtLogin, task, thisExe, LogonRepair.IsInstalledPath(thisExe, InstallDirs),
                           p => Array.Exists(existing, e => LogonRepair.SamePath(e, p)));

    // MARK: #4 a disabled task

    [Fact]
    public void aDisabledTaskIsReEnabledWhenLaunchAtLoginIsOn() =>
        Assert.Equal(LogonRepairAction.Enable, Decide(new(false, Installed), Installed, existing: Installed));

    [Fact]
    public void aDisabledTaskIsLeftAloneWhenLaunchAtLoginIsOff()
    {
        Assert.Equal(LogonRepairAction.None, Decide(new(false, Installed), Installed, launchAtLogin: false, existing: Installed));
        Assert.Equal(LogonRepairAction.None, Decide(null, Installed, launchAtLogin: false));      // and never created
        Assert.Equal(LogonRepairAction.None, Decide(new(false, Installed), Installed, setupComplete: false));
    }

    [Fact]
    public void aHealthyTaskIsLeftAlone()
    {
        Assert.Equal(LogonRepairAction.None, Decide(new(true, Installed), Installed, existing: Installed));
        Assert.Equal(LogonRepairAction.None, Decide(new(true, "\"" + Installed.ToUpperInvariant() + "\""), Installed, existing: Installed));   // quotes, case
    }

    [Fact]
    public void aMissingTaskIsRegistered() => Assert.Equal(LogonRepairAction.Register, Decide(null, Installed));

    // MARK: #5 the task runs another exe

    [Fact]
    public void theInstalledCopyTakesTheTaskFromAStrayOne() =>
        Assert.Equal(LogonRepairAction.ReRegister, Decide(new(true, Downloads), Installed, existing: [Downloads, Installed]));

    [Fact]
    public void anyCopyTakesTheTaskWhenItsExeIsGone()
    {
        Assert.Equal(LogonRepairAction.ReRegister, Decide(new(true, Downloads), Installed, existing: Installed));
        Assert.Equal(LogonRepairAction.ReRegister, Decide(new(true, Installed), Downloads, existing: Downloads));        // installed copy uninstalled
        Assert.Equal(LogonRepairAction.ReRegister, Decide(new(false, Downloads), @"D:\Other\GoPray.exe", existing: @"D:\Other\GoPray.exe"));
    }

    [Fact]
    public void aStrayCopyNeverTakesTheTaskFromAnInstalledOneThatExists()
    {
        Assert.Equal(LogonRepairAction.None, Decide(new(true, Installed), Downloads, existing: [Installed, Downloads]));
        Assert.Equal(LogonRepairAction.Enable, Decide(new(false, Installed), Downloads, existing: [Installed, Downloads]));   // but it is switched back on
    }

    [Fact]
    public void installedPathRule()
    {
        Assert.True(LogonRepair.IsInstalledPath(Installed, InstallDirs));
        Assert.True(LogonRepair.IsInstalledPath(@"c:\program files\go pray\GoPray.exe", InstallDirs));
        Assert.False(LogonRepair.IsInstalledPath(Downloads, InstallDirs));
        Assert.False(LogonRepair.IsInstalledPath(@"C:\Users\a\AppData\Local\Programs\Go Pray\sub\GoPray.exe", InstallDirs));
        Assert.True(LogonRepair.SamePath(@"C:\A\b\..\GoPray.exe", @"c:\a\GoPray.exe"));
    }

    // MARK: #2 the DEBUG-only mutex name

#if DEBUG
    [Fact]
    public void aDebugRunWithItsOwnStateFolderGetsItsOwnMutexName()
    {
        Assert.Equal(@"Local\GoPray.Instance", LaunchDecision.MutexNameFor(null));
        Assert.Equal(@"Local\GoPray.Instance", LaunchDecision.MutexNameFor(""));
        var a = LaunchDecision.MutexNameFor(@"C:\Temp\gp-run-1");
        Assert.StartsWith(@"Local\GoPray.Instance.DebugRun.", a);
        Assert.Equal(a, LaunchDecision.MutexNameFor(@"c:\temp\gp-run-1\"));                 // stable across processes and spellings
        Assert.NotEqual(a, LaunchDecision.MutexNameFor(@"C:\Temp\gp-run-2"));
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("GOPRAY_DEBUG_STATE_DIR")))
            Assert.Equal(LaunchDecision.MutexName, LaunchDecision.MutexNameForThisRun());
    }
#endif
}
