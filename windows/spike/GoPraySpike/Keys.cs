using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace GoPraySpike;

// Tester for Q1: injects the reflex-escape chords with SendInput while a shield is up and records
// what is in front afterwards. Spike only (the real build's guard bans SendInput).
// Never injects Win+L (would lock Ahmed's PC) and cannot inject Ctrl+Alt+Del (SAS).
static class KeysMode
{
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)]
    struct U { [FieldOffset(0)] public KEYBDINPUT k; [FieldOffset(0)] public MOUSEINPUT m; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public U u; }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] i, int size);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out N.POINT p);

    const uint KEYUP = 2;
    static void K(ushort vk, bool up)
    {
        var i = new INPUT[] { new() { type = 1, u = new U { k = new KEYBDINPUT { wVk = vk, dwFlags = up ? KEYUP : 0 } } } };
        SendInput(1, i, Marshal.SizeOf<INPUT>());
        Thread.Sleep(40);
    }
    static void Chord(params ushort[] vks) { foreach (var v in vks) K(v, false); for (int j = vks.Length - 1; j >= 0; j--) K(vks[j], true); }

    const ushort WIN = 0x5B, ALT = 0x12, CTRL = 0x11, SHIFT = 0x10, TAB = 0x09, ESC = 0x1B, D = 0x44, F4 = 0x73;

    public static void Run(string[] a)
    {
        Log.Open(Program.StrArg(a, "--log", "q1-keys"));
        var steps = Program.StrArg(a, "--steps", "win,alttab,wintab,ctrlesc,altesc,ctrlshiftesc,wind,altf4,steal,clicktaskbar").Split(',');
        Thread.Sleep(Program.IntArg(a, "--delay", 2500));   // let the shield come up
        var tray = N.FindWindow("Shell_TrayWnd", null);
        N.GetWindowRect(tray, out var tr);
        foreach (var s in steps)
        {
            var before = N.Describe(N.GetForegroundWindow());
            if (!before.StartsWith("GoPraySpike"))
            {
                Log.W($"STOP: foreground is {before}, not the spike shield; not injecting more keys");
                break;
            }
            Log.W($"--> {s}");
            switch (s)
            {
                case "win": Chord(WIN); break;
                case "alttab": K(ALT, false); K(TAB, false); K(TAB, true); Thread.Sleep(300); K(ALT, true); break;
                case "wintab": Chord(WIN, TAB); break;
                case "ctrlesc": Chord(CTRL, ESC); break;
                case "altesc": Chord(ALT, ESC); break;
                case "ctrlshiftesc": Chord(CTRL, SHIFT, ESC); break;
                case "wind": Chord(WIN, D); break;
                case "altf4": Chord(ALT, F4); break;
                case "steal":
                    var p = Process.Start(new ProcessStartInfo(Environment.ProcessPath!, "steal") { UseShellExecute = false });
                    N.AllowSetForegroundWindow(p!.Id);
                    break;
                case "clicktaskbar":
                    GetCursorPos(out var old);
                    SetCursorPos((tr.L + tr.R) / 2, (tr.T + tr.B) / 2);
                    var i = new INPUT[] {
                        new() { type = 0, u = new U { m = new MOUSEINPUT { flags = 2 } } },
                        new() { type = 0, u = new U { m = new MOUSEINPUT { flags = 4 } } } };
                    SendInput(2, i, Marshal.SizeOf<INPUT>());
                    Thread.Sleep(100);
                    SetCursorPos(old.X, old.Y);
                    break;
            }
            for (int t = 0; t < 6; t++)
            {
                Thread.Sleep(150);
                Log.W($"    +{(t + 1) * 150}ms fg={N.Describe(N.GetForegroundWindow())}");
            }
            Thread.Sleep(300);
        }
        Log.W("keys done");
    }
}
