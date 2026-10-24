# Mac-shaped fixtures

Written by hand in the exact form the Mac app's Swift `JSONEncoder` produces
(`.prettyPrinted, .sortedKeys`; state dates with milliseconds, settings dates whole seconds;
`Voice` as Swift's synthesized enum shape; nil optionals omitted; idle `block` = `null`).
The city has non-ASCII letters on purpose.

TODO (PM): replace or add real files copied from Ahmed's Mac
(`~/Library/Application Support/GoPray/state.json` idle + mid-block, `settings.json`, city removed),
as PLAN.md §8 item 3 says. The tests load every `mac-*.json` here.

v2 (2026-10-24): `mac-settings-v2.json` and `mac-state-block-v2.json` are hand-written in the same Swift shape from
the v2 contract (PLAN-v2 §1.2, §9.2; Mac CONTRACT-NOTES #49–#55). Replace them with real Mac v2 files when lane-v2
lands on main.
