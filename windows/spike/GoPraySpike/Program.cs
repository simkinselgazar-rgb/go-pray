using System;
using System.IO;
using System.Linq;
using System.Threading;

namespace GoPraySpike;

// Go Pray Windows Phase 0 spike. Throwaway. Modes:
//   shield [--seconds 15] [--nohook] [--noreassert] [--log name]   Q1
//   keys --steps a,b,c [--log name]                               Q1 tester (SendInput)
//   steal                                                          Q1 foreground thief
//   media-target / media-pause                                     Q2
//   idle [--minutes 8]                                             Q3 (Task Scheduler target)
//   web --scenes <dir>                                             Q4
//   audio --athan <dir> [--noplay]                                 Q5
//   hider --marker <title marker>                                  Q6
static class Program
{
    [STAThread]
    static int Main(string[] a)
    {
        var mode = a.FirstOrDefault() ?? "";
        switch (mode)
        {
            case "shield": ShieldMode.Run(a); break;
            case "keys": KeysMode.Run(a); break;
            case "steal": StealMode.Run(a); break;
            case "media-target": MediaMode.Target(a); break;
            case "media-pause": MediaMode.Pause(a); break;
            case "idle": Idle(a); break;
            case "web": WebMode.Run(a); break;
            case "audio": AudioMode.Run(a); break;
            case "hider": HiderMode.Run(a); break;
            default: return 2;
        }
        return 0;
    }

    static void Idle(string[] a)
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GoPraySpike");
        Directory.CreateDirectory(dir);
        File.AppendAllText(Path.Combine(dir, "task-starts.log"),
            $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} start pid={Environment.ProcessId} args={string.Join(' ', a)}{Environment.NewLine}");
        Thread.Sleep(TimeSpan.FromMinutes(Math.Clamp(IntArg(a, "--minutes", 8), 1, 15)));
        File.AppendAllText(Path.Combine(dir, "task-starts.log"), $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} clean exit pid={Environment.ProcessId}{Environment.NewLine}");
    }

    public static string StrArg(string[] a, string k, string d) { int i = Array.IndexOf(a, k); return i >= 0 && i + 1 < a.Length ? a[i + 1] : d; }
    public static int IntArg(string[] a, string k, int d) => int.TryParse(StrArg(a, k, ""), out var v) ? v : d;
}
