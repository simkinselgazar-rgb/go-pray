# Mac-shaped fixtures

Written by hand in the exact form the Mac app's Swift `JSONEncoder` produces
(`.prettyPrinted, .sortedKeys`; state dates with milliseconds, settings dates whole seconds;
`Voice` as Swift's synthesized enum shape; nil optionals omitted; idle `block` = `null`).
The city has non-ASCII letters on purpose.

TODO (PM): replace or add real files copied from Ahmed's Mac
(`~/Library/Application Support/GoPray/state.json` idle + mid-block, `settings.json`, city removed),
as PLAN.md §8 item 3 says. The tests load every `mac-*.json` here.
