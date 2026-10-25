# Go Pray for Windows 0.3.0: the Athan on your Roku TV

Built 2026-10-24 on `windows`, from the PM's TV brief and its two amendments. It matches Mac 0.3.0 (4ee25e8, CONTRACT-NOTES #56).

At each Athan the PC asks the Roku TVs on the home Wi-Fi to open the Go Pray Roku app. The PC block itself is unchanged; the TV is extra.

## Where it lives

- **`GoPray.Core/Tv/Tvs.cs`** holds the rules and the storage, with no networking:
  - `TvDevice`, the same shape as the Mac's `TVDevice`.
  - `TvRules.IsAllowedHost`: an IPv4 literal in 10/8, 172.16/12, 192.168/16 or 169.254/16. Leading zeros are refused and so are hostnames. It is checked when a TV is saved and again before every request.
  - The channel id rule `^(dev|[0-9]{1,10})$`.
  - The 3-minute launch window.
  - Reading and writing `tvs` in settings.json.
  - `ITvLaunching` and `ITvControlling`.
- **`GoPray.App/Tv/TvController.cs`** is the only code that talks to a TV.
- **`BlockGate.Present`**: on a fresh block start only, right after the Athan starts (or fails to start), `CallTvs` hands the enabled TVs to the controller once. It does nothing:
  - after a relaunch mid-block,
  - on Silence,
  - when Go Pray is paused (no block starts),
  - when the PC wakes more than 3 minutes after the prayer's real Athan time. That case logs `tv: skipped, late wake`.

  If the controller throws, the gate logs one line and the block carries on unchanged.

## The contract (Roku ECP, port 8060)

- **Athan launch:** `GET /query/active-app` first. If our channel is already the active app, nothing is sent and the log says `tv: already playing`. If the check fails, the launch is sent anyway. The launch itself is `POST /launch/<channelId>?prayer=<p>&voice=<sunni|shia>.<stem>`, with an empty body and the values URL-encoded. Fajr still sends the chosen voice.
- **Test:** the same launch with `&test=1` added, and no active-app check.
- **Channel id:** read from `GET /query/apps`. It is the `<app>` whose name starts with "Go Pray"; a numeric id beats `dev`. It is looked up when a TV is added and on every Test press, then stored. At Athan time the stored id is used. A TV with `installed: false` is skipped, with one log line.
- **Name:** `GET /query/device-info` → `friendly-device-name`.
- **Discovery:** an SSDP M-SEARCH with `ST: roku:ecp`, waiting 3 s. The TV's address is the reply's sender, never the LOCATION header. The search is sent from **every private IPv4 interface**, because on this PC Windows routes multicast to the Hyper-V "Default Switch" first. With a single socket on the default route, nothing came back.
- **Untrusted replies:**
  - 3 s per request; no redirects, no proxy, no cookies.
  - At most 512 KB is read, as a stream, then the reader stops. A larger Content-Length is refused before anything is read.
  - The XML reader has DTDs prohibited and no resolver.
  - A junk id is dropped.
  - Every failure is one log line.

## settings.json `tvs`

The entry is `{channelId, enabled, host, id, installed, kind:"roku", name}`, keys sorted, always written (like the Mac).

- Decoding follows the Mac and is tolerant. Only `id`, `host` and `kind` are required; `name` defaults to "", `channelId` to `"dev"`, and `enabled` and `installed` to `true`.
- A bad entry is dropped on its own. A `tvs` that is not an array reads as `[]`.
- Sanitizing on save matches the Mac's `cleanTVs`:
  - the host and name are trimmed, and an empty name becomes "Roku TV";
  - a junk channel id becomes `dev`;
  - a non-LAN host is dropped;
  - entries are deduped by id and by host;
  - the list is capped at 8.

## Settings → TVs

- Each TV row shows the name, the address, an on/off switch, **Test** and **Remove**. When the app isn't found, the row also says "Go Pray isn't installed on this TV yet".
- Below the rows: **Find TVs** (new TVs only, each with Add) and **Add by address…**. Like on the Mac, a TV is added first and then checked. A TV that can't be reached is kept with the defaults, and the line says so.
- The help line reads "Your TV needs the Go Pray Roku app."
- During a block the whole section is read-only, like the rest of Settings.

## Windows Firewall (checked live, 2026-10-24)

- **What happened:** the Wi-Fi here is on the **Public** profile. Discovery from the real `GoPray.exe` (Debug `--debug-find-tvs`) found the Roku. There was no firewall prompt, and no rule exists for GoPray.exe afterwards.
- **Why:** Windows allows unicast replies to our own multicast search for 3 s ("Allow unicast response", on by default on every profile).
- **When the firewall line shows:** after a search that found nothing, and only if the firewall's own policy really drops the replies. That means either "Allow unicast response" is off on a current profile, or there is an enabled inbound block rule for this exe. The policy is read through `HNetCfg.FwPolicy2`, which a standard user can read.
- **What the line says:** how an administrator can turn the setting back on, or to add the TV by its address. Adding by address works through the firewall, because it is an outbound connection.
- The blocking case was not run live, because that would mean changing a system setting. A unit test covers it through the seam.

## guard.ps1, rule 4b

- Sockets, `NetworkInterface` and the ECP paths are allowed only in `TvController.cs`.
- Name lookups are not allowed anywhere, and neither are `localhost`, `127.0.0.1` or `IPAddress.Loopback` in the app's source.
- Every string literal in `TvController.cs` is checked. It may not contain a URL (`://`), a dotted hostname, or an IP literal other than the SSDP group `239.255.255.250`.
- Seven new negative controls cover:
  - a planted hostname,
  - a planted URL,
  - a planted IP literal,
  - a socket elsewhere,
  - an ECP path elsewhere,
  - a name lookup,
  - loopback added to the host rule.

## Tests

- **Core `TvTests`:**
  - the host and channel id rules;
  - `tvs` with and without the key, bad entries dropped, Mac-style cleaning;
  - the gate: a live Athan gives one call; a wake at +2 min calls; at +10 min it doesn't (the block still shows); at exactly 3 min it calls, at 3 min + 1 s it doesn't;
  - more gate cases: no second call on a relaunch, none on Silence, none while paused, still a call when the PC audio fails, no call for disabled TVs, a throwing controller leaves the block unchanged;
  - the Settings model: add, refuse, unreachable, not installed, Test re-checks and stores, read-only during a block, Find, remove and toggle.
- **App `TvControllerTests`**, against a fake TV on loopback that is reachable only through the test seam:
  - the exact URL, an empty body and no `test`; fajr with sunni and shia voices; encoding; `test=1` on Test with no check;
  - the active-app cases: ours (no POST), another app (POST), a failed check (500, junk, DTD, endless body; POST in each case);
  - a TV that is off gives one log line; a hanging TV doesn't hold up the hand-off;
  - disabled and not-installed TVs; public hosts and loopback refused by the production rule; a junk channel id is never sent;
  - channel lookup: dev only, published plus dev, none, junk ids, DTD refused;
  - no redirects; the over-cap stream stops early; a Content-Length over the cap is refused;
  - discovery uses the sender, and the firewall case.
- **`TvSettingsUiTests`** draws the section for real.
- **`liveRoku`** runs only with `GOPRAY_LIVE_TV=<ip>`.

## 0.3.1: the TV step in first-run setup (PM, 2026-10-24)

- **The shared model.** `GoPray.Core/UI/TvsModel.cs` is the one TV model. It does the scan, add (then check), test, toggle and remove, and keeps the found list and the skeleton flag (`Searching`), the section line and each TV's own line.
  - Settings → TVs (`SettingsModel.Tvs`) and Setup's TV step (`SetupModel.Tvs`) both use it.
  - Saves go through the host's normal path: `SettingsModel.Apply` in Settings, `SettingsStore.Mutate` in Setup. Both ask the gate first.
  - No new network code.
- **The step.** `SetupStep.Tv` is a new last step, "Step 4 of 4", and appears only when TV support is wired. Existing users (setup done) never see Setup.
  - Title: "Play the Athan on your TV?" The line under it: "If you have a Roku TV, Go Pray can play the Athan on it at each prayer. Your TV needs the free Go Pray Roku app."
  - The scan starts as the step appears, and a skeleton row stands in while it runs (no spinner, no blank).
  - Found TVs are listed with Add. Below them: "Find TVs again" and "Add by address…" (the same dialog and rule as Settings, `TvViews.AskAddress`).
- **After Add**, the row shows one of:
  - "Ready";
  - "Go Pray isn't installed on this TV yet. Search 'Go Pray' in the Roku Channel Store.";
  - "Couldn't reach a TV at that address…".

  The firewall line belongs to the scan, so it shows under the list after a scan that the firewall really blocked.
- **"Play a test"** is `TvsModel.TestTv`: the Test path, with `test=1`.
- **Buttons:** Back, Skip and Continue. Skip is the default until a TV is added, then Continue is. Skip only finishes setup; it saves nothing of its own and keeps any TV already added. A TV added in this step is saved at once, before the rest of setup.
