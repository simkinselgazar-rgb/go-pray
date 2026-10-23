// LogonTask.cs — the Task Scheduler task "Go Pray" (PLAN.md §3 row 5, spike Q3, PM ruling 2026-10-23).
// Created by the app itself on Setup "Finish" and the Settings toggle, never by the installer (so a
// hand-copied exe works too); removed by the toggle and by the uninstaller (`GoPray.exe --uninstall-task`).
// Per user, "run only when the user is logged on", least privilege. Two triggers, one action (`--tick`):
// at logon of this user, and every minute (IgnoreNew), because RestartOnFailure never fires after
// Task Manager's End task. LaunchDecision.Decide is what makes a tick exit at once when it has nothing to do.
// schtasks.exe with an XML definition: no extra package, and exactly what the spike measured.

using System;
using System.Diagnostics;
using System.IO;
using System.Security;
using System.Security.Principal;
using GoPray.Core;

namespace GoPray.App.Launch;

internal sealed class LogonTask(string? exePath = null, string name = LogonTask.DefaultName) : ILogonTask
{
    public const string DefaultName = "Go Pray";
    readonly string _exe = exePath ?? Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "GoPray.exe");

    /// <summary>The task XML (Task Scheduler schema 1.4). Pure: unit-tested.</summary>
    public static string Xml(string user, string exe, DateTime startBoundaryLocal)
    {
        string u = SecurityElement.Escape(user), e = SecurityElement.Escape(exe);
        return $"""
        <?xml version="1.0" encoding="UTF-16"?>
        <Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
          <RegistrationInfo><Description>Go Pray: starts at sign-in and comes back within a minute if it is closed. Remove it by turning off Launch at login in Go Pray's Settings.</Description></RegistrationInfo>
          <Triggers>
            <LogonTrigger><Enabled>true</Enabled><UserId>{u}</UserId></LogonTrigger>
            <TimeTrigger><Enabled>true</Enabled><StartBoundary>{startBoundaryLocal:yyyy-MM-ddTHH:mm:ss}</StartBoundary><Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition></TimeTrigger>
          </Triggers>
          <Principals><Principal id="Author"><UserId>{u}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
          <Settings>
            <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
            <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
            <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
            <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
            <StartWhenAvailable>false</StartWhenAvailable>
            <Enabled>true</Enabled>
            <Hidden>false</Hidden>
          </Settings>
          <Actions Context="Author"><Exec><Command>{e}</Command><Arguments>{LaunchDecision.TickArgument}</Arguments></Exec></Actions>
        </Task>
        """;
    }

    public bool IsRegistered => Schtasks($"/query /tn \"{name}\"").Code == 0;

    public void Register()
    {
        var user = WindowsIdentity.GetCurrent().Name;
        var tmp = Path.Combine(Path.GetTempPath(), "gopray-task-" + Guid.NewGuid().ToString("N") + ".xml");
        try
        {
            File.WriteAllText(tmp, Xml(user, _exe, DateTime.Now.AddMinutes(1)), System.Text.Encoding.Unicode);
            var r = Schtasks($"/create /tn \"{name}\" /xml \"{tmp}\" /f");
            if (r.Code != 0) throw new InvalidOperationException("schtasks /create failed: " + r.Out.Trim());
            CoreLog.Notice("logon task registered");
        }
        finally { try { File.Delete(tmp); } catch (IOException) { } }
    }

    public void Unregister()
    {
        if (!IsRegistered) return;
        var r = Schtasks($"/delete /tn \"{name}\" /f");
        if (r.Code != 0) throw new InvalidOperationException("schtasks /delete failed: " + r.Out.Trim());
        CoreLog.Notice("logon task removed");
    }

    static (int Code, string Out) Schtasks(string args)
    {
        var psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "schtasks.exe"), args)
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        using var p = Process.Start(psi)!;
        string o = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
        p.WaitForExit(15000);
        return (p.ExitCode, o);
    }
}
