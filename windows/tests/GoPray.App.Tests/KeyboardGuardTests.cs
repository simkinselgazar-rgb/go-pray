// KeyboardGuardTests.cs — the hook's pure decision, case by case (PLAN.md §6: "its callback is a pure
// function … unit-tested"). The real hook is exercised live by the debug harness, never here.

using GoPray.App.Shield;
using Xunit;

namespace GoPray.App.Tests;

public class KeyboardGuardTests
{
    const uint UP = 0x80, ALT = 0x20;
    const uint TAB = 0x09, ESC = 0x1B, L = 0x4C, D = 0x44, LWIN = 0x5B, RWIN = 0x5C, LCTRL = 0xA2, LSHIFT = 0xA0, A = 0x41, F4 = 0x73, DEL = 0x2E, LMENU = 0xA4;

    static KeyDecision[] Seq(params (uint vk, uint flags)[] events)
    {
        var s = new KeyState();
        var r = new KeyDecision[events.Length];
        for (int i = 0; i < events.Length; i++) r[i] = KeyboardGuard.Decide(events[i].vk, events[i].flags, ref s);
        return r;
    }

    const KeyDecision P = KeyDecision.Pass, S = KeyDecision.Swallow;

    [Fact] public void winTapIsSwallowed() => Assert.Equal([S, S], Seq((LWIN, 0), (LWIN, UP)));
    [Fact] public void rightWinToo() => Assert.Equal([S, S], Seq((RWIN, 0), (RWIN, UP)));
    [Fact] public void winDIsSwallowed() => Assert.Equal([S, S, S, S], Seq((LWIN, 0), (D, 0), (D, UP), (LWIN, UP)));
    [Fact] public void winTabIsSwallowed() => Assert.Equal([S, S, S, S], Seq((LWIN, 0), (TAB, 0), (TAB, UP), (LWIN, UP)));
    [Fact] public void winLPassesTheLSoWindowsCanLock() => Assert.Equal([S, P, P, S], Seq((LWIN, 0), (L, 0), (L, UP), (LWIN, UP)));
    [Fact] public void altTabIsSwallowedAltItselfPasses() => Assert.Equal([P, S, S, P], Seq((LMENU, ALT), (TAB, ALT), (TAB, ALT | UP), (LMENU, UP)));
    [Fact] public void altEscIsSwallowed() => Assert.Equal([P, S, S, P], Seq((LMENU, ALT), (ESC, ALT), (ESC, ALT | UP), (LMENU, UP)));
    [Fact] public void ctrlEscIsSwallowed() => Assert.Equal([P, S, S, P], Seq((LCTRL, 0), (ESC, 0), (ESC, UP), (LCTRL, UP)));
    [Fact] public void ctrlShiftEscIsSwallowed() => Assert.Equal([P, P, S, S, P, P], Seq((LCTRL, 0), (LSHIFT, 0), (ESC, 0), (ESC, UP), (LSHIFT, UP), (LCTRL, UP)));
    [Fact] public void altF4PassesTheWindowCancelsItsClosing() => Assert.Equal([P, P, P, P], Seq((LMENU, ALT), (F4, ALT), (F4, ALT | UP), (LMENU, UP)));
    [Fact] public void ctrlAltDelIsNeverTouched() => Assert.Equal([P, P, P], Seq((LCTRL, 0), (LMENU, ALT), (DEL, ALT)));
    [Fact] public void plainTypingPasses() => Assert.Equal([P, P, P, P], Seq((A, 0), (A, UP), (ESC, 0), (ESC, UP)));
    [Fact] public void afterWinIsReleasedKeysPassAgain() => Assert.Equal([S, S, P, P], Seq((LWIN, 0), (LWIN, UP), (D, 0), (D, UP)));
    [Fact] public void escAfterCtrlReleasedPasses() => Assert.Equal([P, P, P], Seq((LCTRL, 0), (LCTRL, UP), (ESC, 0)));

    [Fact]
    public void theHookIsNotInstalledByTests() => Assert.False(KeyboardGuard.IsInstalled);
}
