# Manual checks by Ahmed + two-monitor run (2026-10-23)

Ahmed, real keyboard, `GoPray.exe --debug-shield --lock 10 --cap 15` (DEBUG harness):
- Win, Alt+Tab, Win+D, Ctrl+Shift+Esc, Alt+F4: **none opened anything**.
- **Win+L locked** the PC.
- **Ctrl+Alt+Del showed the security screen.** "Cancel" and "Task Manager" both returned to the shield:
  Task Manager starts, but under the topmost shield, which takes the foreground back. Lock, sign out and
  switch user from that screen still work (never trapped). Stricter than PLAN §6, which accepted
  "Ctrl+Alt+Del → Task Manager → End task" as a bypass. **PM ruling 2026-10-23: keep it.** Task Manager is not a bypass during whole-screen blocks (by design); sign-out is. PLAN.md §6 updated.

Two monitors (Ahmed added a 2560x1440 screen to the left of the 1920x1080 @125% laptop; mixed scale, negative
coordinates), `two-monitors.log`:
- 2 windows: Full on DISPLAY1 (0,0,1920x1080), Art on DISPLAY2 (-2560,-95,2560x1440), both **exact**, both pages ready in < 0.5 s.
- What is on top at the centre of each monitor, and at both taskbars (Shell_TrayWnd + Shell_SecondaryTrayWnd): **the shield**.
- Hook installed at start, removed at confirm. Not yet tried: unplugging a monitor mid-block (the rebuild path).
