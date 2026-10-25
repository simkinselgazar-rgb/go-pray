// LogonTaskRepairTests.cs — 0.3.2: reading the task back (`schtasks /query /xml`) and switching a disabled one on again.
// The round trip uses a test-only task name pointing at an exe that does not exist; it is deleted in `finally` and
// the test proves it is gone. The real "Go Pray" task is never touched.

using System;
using System.Diagnostics;
using System.IO;
using GoPray.App.Launch;
using GoPray.Core;
using Xunit;

namespace GoPray.App.Tests;

public class LogonTaskRepairTests
{
    [Fact]
    public void parseQueryReadsOurOwnXml()
    {
        const string exe = @"C:\Users\x\AppData\Local\Programs\Go Pray\GoPray.exe";
        var xml = LogonTask.Xml(@"PC\someone", exe, new DateTime(2026, 10, 24, 12, 0, 0));
        Assert.Equal(new LogonTaskInfo(true, exe), LogonTask.ParseQuery(xml));
        var off = xml.Replace("<Enabled>true</Enabled>\n    <Hidden>", "<Enabled>false</Enabled>\n    <Hidden>").Replace("<Enabled>true</Enabled>\r\n    <Hidden>", "<Enabled>false</Enabled>\r\n    <Hidden>");
        Assert.Contains("<Enabled>false</Enabled>", off);
        Assert.Equal(new LogonTaskInfo(false, exe), LogonTask.ParseQuery("\uFEFF" + off));
        Assert.Null(LogonTask.ParseQuery(""));
        Assert.Null(LogonTask.ParseQuery("ERROR: The system cannot find the file specified."));
        Assert.Null(LogonTask.ParseQuery("<!DOCTYPE t [<!ENTITY e \"x\">]><Task/>"));
    }

    static int Schtasks(string args)
    {
        using var p = Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "schtasks.exe"), args)
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true })!;
        p.StandardOutput.ReadToEnd(); p.StandardError.ReadToEnd();
        p.WaitForExit(15000);
        return p.ExitCode;
    }

    [Fact]
    public void aDisabledTaskIsSeenAndSwitchedBackOn()
    {
        var name = "GoPrayRepairTest-" + Guid.NewGuid().ToString("N")[..8];
        var exe = Path.Combine(Path.GetTempPath(), "gopray-no-such-dir-" + Guid.NewGuid().ToString("N"), "GoPray.exe");   // never runs
        var t = new LogonTask(exe, name);
        try
        {
            Assert.Null(t.Query());
            t.Register();
            Assert.Equal(new LogonTaskInfo(true, exe), t.Query());
            Assert.Equal(0, Schtasks($"/change /tn \"{name}\" /disable"));                // what an interrupted installer leaves
            Assert.Equal(new LogonTaskInfo(false, exe), t.Query());
            Assert.Equal(LogonRepairAction.Enable, LogonRepair.Decide(true, true, t.Query(), exe, false, _ => true));
            t.Enable();
            Assert.Equal(new LogonTaskInfo(true, exe), t.Query());
        }
        finally
        {
            Schtasks($"/delete /tn \"{name}\" /f");
        }
        Assert.NotEqual(0, Schtasks($"/query /tn \"{name}\""));                         // proved gone
    }
}
