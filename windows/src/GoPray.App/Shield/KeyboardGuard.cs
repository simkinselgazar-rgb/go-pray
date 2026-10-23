// KeyboardGuard.cs — the low-level keyboard hook, installed ONLY while a whole-screen block is up
// (Ahmed's decision 2, PLAN.md §3 row 1; spike Q1: without it Start cannot be won back).
//
// It swallows the reflex escapes: the Win key (and Win+anything except L), Alt+Tab, Alt+Esc, Ctrl+Esc,
// Ctrl+Shift+Esc. Every other key passes. Win+L and Ctrl+Alt+Del are handled by Windows below any hook
// and always work (walking away is allowed). Alt+F4 passes; the shield window cancels its Closing.
//
// This file is the only one with SetWindowsHookEx (guard rule 7), and it may not store, log or write
// anything (guard bans files, consoles, loggers, string builders and collections here). The decision
// is a pure function of the key event and three modifier flags; nothing about a key outlives the call.
// Windows itself drops a hook that does not answer within LowLevelHooksTimeout, and the hook dies with
// the process, so a hung or crashed Go Pray can never keep the keyboard.

using System;
using System.Runtime.InteropServices;

namespace GoPray.App.Shield;

internal enum KeyDecision { Pass, Swallow }

/// <summary>Modifier state the decision needs. Reset at every install.</summary>
internal struct KeyState
{
    public bool Win, Ctrl, Shift;
}

internal static partial class KeyboardGuard
{
    const int WH_KEYBOARD_LL = 13;
    const uint LLKHF_ALTDOWN = 0x20, LLKHF_UP = 0x80;
    const uint VK_TAB = 0x09, VK_ESCAPE = 0x1B, VK_L = 0x4C, VK_LWIN = 0x5B, VK_RWIN = 0x5C,
               VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1, VK_LCONTROL = 0xA2, VK_RCONTROL = 0xA3;

    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    // DllImport, not LibraryImport: the source generator does not marshal delegates.
    [DllImport("user32.dll", EntryPoint = "SetWindowsHookExW", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc fn, IntPtr hMod, uint threadId);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UnhookWindowsHookEx(IntPtr hook);
    [LibraryImport("user32.dll")]
    private static partial IntPtr CallNextHookEx(IntPtr hook, int nCode, IntPtr wParam, IntPtr lParam);
    [LibraryImport("kernel32.dll", EntryPoint = "GetModuleHandleW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr GetModuleHandle(string? name);

    static IntPtr _hook;
    static KeyState _state;
    static readonly HookProc Proc = Callback;   // kept alive for the life of the process

    public static bool IsInstalled => _hook != IntPtr.Zero;
    /// <summary>How many key events the hook has seen since the process started (a count, never a key).
    /// Lets a test prove the hook is gone after a block.</summary>
    public static int EventsSeen { get; private set; }

    /// <summary>The whole rule. Pure: the same event and state always give the same answer.</summary>
    public static KeyDecision Decide(uint vk, uint flags, ref KeyState s)
    {
        bool up = (flags & LLKHF_UP) != 0;
        bool alt = (flags & LLKHF_ALTDOWN) != 0;
        if (vk is VK_LCONTROL or VK_RCONTROL or VK_CONTROL) s.Ctrl = !up;
        if (vk is VK_LSHIFT or VK_RSHIFT or VK_SHIFT) s.Shift = !up;
        if (vk is VK_LWIN or VK_RWIN) { s.Win = !up; return KeyDecision.Swallow; }   // Start, and every Win+ combo
        if (s.Win && vk != VK_L) return KeyDecision.Swallow;                         // Win+D, Win+Tab, … (Win+L is the OS's)
        if (vk == VK_TAB && alt) return KeyDecision.Swallow;                         // Alt+Tab
        if (vk == VK_ESCAPE && (alt || s.Ctrl)) return KeyDecision.Swallow;          // Alt+Esc, Ctrl+Esc, Ctrl+Shift+Esc
        return KeyDecision.Pass;
    }

    /// <summary>Install on the calling (UI) thread. Idempotent. Returns whether the hook is now in place.</summary>
    public static bool Install()
    {
        if (_hook != IntPtr.Zero) return true;
        _state = default;
        _hook = SetWindowsHookEx(WH_KEYBOARD_LL, Proc, GetModuleHandle(null), 0);
        return _hook != IntPtr.Zero;
    }

    /// <summary>Remove. Idempotent; called at block end, fail-open, tear-down and process exit.</summary>
    public static void Uninstall()
    {
        if (_hook == IntPtr.Zero) return;
        UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
        _state = default;
    }

    static IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            EventsSeen++;
            uint vk = (uint)Marshal.ReadInt32(lParam, 0);      // KBDLLHOOKSTRUCT.vkCode
            uint flags = (uint)Marshal.ReadInt32(lParam, 8);   // KBDLLHOOKSTRUCT.flags
            if (Decide(vk, flags, ref _state) == KeyDecision.Swallow) return new IntPtr(1);
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }
}
