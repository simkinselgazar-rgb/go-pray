# Spike: pause other media when the Athan starts

Tested 2026-10-22 on macOS 26.5.2, Xcode 26.6, Swift 6.3. Test tools: `src/` (build with `build.sh`).
Test subject 1: `FakePlayer.app`, a small app that plays a quiet tone and registers as the system Now Playing app (it logs every remote command it gets).
Test subject 2: a real local mp4 with sound in Safari (18 s, volume low, tab closed after).

## Short answer

**Method 1 works. Call `MRMediaRemoteSendCommand(kMRPause)` straight from Go Pray's own process. No helper, no perl, no prompt.**
It paused both the fake player and a real HTML5 video in Safari, from a Developer ID signed, hardened-runtime binary.
The Apple restriction on 15.4+ only blocks the READ calls (what is playing). Sending a command still works.

## Results per method

| # | Method | On 26.5.2 | Prompt |
|---|---|---|---|
| 1a | MediaRemote `SendCommand(kMRPause=1)` direct from our process | **WORKS** | none |
| 1b | MediaRemote read calls (`GetNowPlayingApplicationIsPlaying`, `GetNowPlayingInfo`) direct | **BLOCKED** (always `false` / empty) | none |
| 1c | Same calls hosted in `/usr/bin/perl` (mediaremote-adapter trick) | **WORKS** (reads return real state, send works) | none |
| 2 | AppleScript to Music/Spotify | Works only for those apps. Not pausing-tested (see below) | Automation prompt per app |
| 2 | AppleScript `do JavaScript` in Safari | **BLOCKED** until user enables a hidden developer setting | Automation prompt + hidden setting |
| 3 | Simulated media key (CGEvent) | NOT TESTED. Banned by `guard.sh` | Accessibility/input permission |
| 4 | `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` | Cannot control other apps (by design) | n/a |

## Evidence

**1a, direct send.** `build/mrtest` (Developer ID signed, `--options runtime`) called `send(1, nil)`. It returned `true`.
- FakePlayer log: `PAUSE cmd` received, state went `true` to `false`.
- Control: same app left alone 9 s with no command stayed `true`. So the pause was ours.
- Real world: Safari playing a local mp4. perl read `isPlaying=1`. Ran `mrtest`. perl read `isPlaying=0`.
- Catch: the process must stay alive about a second after sending. A process that exited right away did not deliver the pause. Go Pray is long-lived, so this is fine. Send first, do not `exit`.

**1b, direct reads blocked.** From the same signed binary, `isPlaying=false` and `info=[]` while the tone was audibly playing. This is the 15.4+ restriction.

**1c, perl host.** A tiny ad-hoc signed dylib loaded into `/usr/bin/perl` through `DynaLoader` read `isPlaying=1` correctly and sent pause successfully. So the known workaround still works on 26.5.2. We do not need it for pausing. It is only useful if we want to READ what is playing (for example "only pause if something is playing", or show "paused Safari" in the UI).

**Licence.** `ungive/mediaremote-adapter` is BSD 3-Clause (checked its LICENSE file). I only borrowed the idea (load a dylib into perl via DynaLoader). I wrote my own 20 line dylib. **No code vendored.** If we ever vendor theirs, we must keep the copyright notice and licence text.

**2, AppleScript.**
- Safari `do JavaScript` returned: "You must enable 'Allow JavaScript from Apple Events' in the Developer section of Safari Settings". Chrome has the same kind of setting (View > Developer). Asking a prayer-app user to turn those on is not acceptable UX. Not tested in Chrome (per brief: not running, not launched).
- Music: running on this Mac; I only read `player state` (`stopped`) and did not send pause to Ahmed's app. Spotify not running; not launched.
- Prompts (from how macOS works, not seen here because this host already had the grants): first call to each app shows "GoPray wants to access Safari/Music/Spotify". Needs `NSAppleEventsUsageDescription` and, with hardened runtime, the `com.apple.security.automation.apple-events` entitlement. One prompt per target app, so a user with 4 players gets 4 prompts at random moments. Bad UX, and it still misses YouTube in Chrome/Firefox/Brave without the developer setting.

**3, media key.** Not run. Reasoning only: it is a TOGGLE, so it would START things that are already paused. It goes to the same Now Playing target as method 1. Needs input permission. Strictly worse than method 1a, which sends pause only. Not needed.

**4, others.** `MPRemoteCommandCenter` only receives commands for our own app. `MPNowPlayingInfoCenter` only publishes our own state. Neither controls other apps. Per-app options (Music, Spotify scripting) are method 2. Nothing else credible found.

## The questions

**Does pausing need to be per-app?** No. One MediaRemote pause goes to the system's current Now Playing app, whatever it is: browser tab, Music, Spotify, Netflix in a browser.

**What happens with 2 things playing?** Only ONE gets paused. Test: FakePlayer1 and FakePlayer2 both playing. One pause paused only the most recent one (Player2). A second pause went to Player2 again (its log shows 2 PAUSE, Player1 got 0) and Player1 kept playing. So repeating the command does not help. This is rare (most people have one thing playing). Fix options: accept it, or use the perl read to check `isPlaying` and tell Ahmed. No clean way to reach the second one without per-app scripting.

**Does Zoom/FaceTime get paused? Should it?** Not tested (not running; I did not want to touch a call). Calls usually do not register as Now Playing, so they probably are NOT paused. A browser Meet or a video call that does register would be. **It should not be paused or interrupted**, because the person is in a call. Decision for Ahmed: if the app can read state, skip pause while a call app (zoom.us, FaceTime, Teams) is the running audio app. Untested, so treat as a to-do for the build.

**If nothing works?** Fall back silently: still play the Athan and show the cover. Never show an error. Log it only. Check the Bool return of `send`, but note it returned `true` even when we cannot tell if anyone listened, so do not rely on it as proof.

## Recommendation for the real build

1. Load MediaRemote with `dlopen`, `dlsym` `MRMediaRemoteSendCommand`. Send `kMRPause` (value 1). Do NOT use play/pause toggle.
2. Send it just BEFORE starting the Athan, wait about 300 ms, then play the Athan. Do not auto-resume.
3. If `dlopen`/`dlsym` fails, or anything throws: do nothing and continue silently. The private API can change in a future macOS, so wrap it in one small file with one function, `pauseOtherMedia()`.
4. No entitlement or Info.plist change needed for this path (it worked hardened-runtime, Developer ID, no sandbox). **Risk:** private API. Fine for Developer ID distribution. It would be rejected by the Mac App Store.
5. Skip the perl trick for v1. Add it later only if we want to read "is something playing" (for the Zoom skip rule or a UI note).
6. Do not use AppleScript or a media key.
7. Add a manual QA line: YouTube in Chrome and Firefox (not tested here), Spotify app, Music app. Safari local video and a fake Now Playing app are verified.

## Not tested / limits

- Chrome, Firefox, Spotify, Music pause, Netflix, YouTube: not touched (Ahmed's apps; brief said not to). Browsers publish Now Playing the same way Safari does, so they should behave the same, but that is a prediction.
- Automation prompt wording: not seen on this Mac (grants already existed on this host).
- Zoom/FaceTime: not tested.

## Correction: permission prompts I triggered (added 2026-10-22)

I wrote above that this host "already had the grants". That was wrong; I did not check. macOS TCC log shows two NEW Automation (Apple Events) grants, both for the client `dev.warp.Warp-Stable` (the Warp terminal that ran my `osascript` commands):
- Warp -> Safari (`com.apple.Safari`), granted 15:22:21. Caused by my `osascript` calls to count windows and run `do JavaScript`, later close the window and quit Safari.
- Warp -> Music (`com.apple.Music`), granted 15:22:43. Caused by my read-only `get player state` check.
These are Automation grants for Warp, not for Go Pray. They stay until revoked: System Settings > Privacy & Security > Automation > Warp (untick Safari and Music). Nothing else (Accessibility etc.) was requested by me.
