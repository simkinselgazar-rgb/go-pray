#!/bin/bash
# bundle-ids.sh — print the real bundle ID of every "coding apps" candidate that is installed,
# and compare it with GoPray/Blocker/CodingApps.swift. Read-only. Lane D.
#
#   scripts/bundle-ids.sh
#
# Exit 0 always; read the MISMATCH / NOT INSTALLED lines.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
swift_file="$here/GoPray/Blocker/CodingApps.swift"

# "Name|App bundle file name(s) separated by /"
apps='Claude|Claude.app
Terminal|Terminal.app
iTerm2|iTerm.app
Warp|Warp.app
Ghostty|Ghostty.app
Codex|Codex.app
ChatGPT (this Mac: Codex)|ChatGPT.app
Cursor|Cursor.app
VS Code|Visual Studio Code.app
VS Code Insiders|Visual Studio Code - Insiders.app
Windsurf|Windsurf.app
Zed|Zed.app
Xcode|Xcode.app/Xcode-26-Beta.app
Chrome|Google Chrome.app
Safari|Safari.app
Arc|Arc.app
Firefox|Firefox.app
Brave|Brave Browser.app
Edge|Microsoft Edge.app
Dia|Dia.app
Opera|Opera.app
Vivaldi|Vivaldi.app'

dirs=("/Applications" "$HOME/Applications" "/System/Applications" "/System/Applications/Utilities" "/Applications/Utilities")
listed="$(sed 's|//.*$||' "$swift_file" 2>/dev/null | grep -oE '"[A-Za-z0-9._-]+\.[A-Za-z0-9._-]+(\.[A-Za-z0-9._-]+)*"' | tr -d '"' | sort -u)"

found_ids=""
while IFS='|' read -r name file; do
  path=""
  IFS='/' read -ra alts <<< "$file"
  for alt in "${alts[@]}"; do
    for d in "${dirs[@]}"; do [ -d "$d/$alt" ] && { path="$d/$alt"; break 2; }; done
  done
  if [ -z "$path" ]; then printf '%-18s NOT INSTALLED\n' "$name"; continue; fi
  id="$(mdls -raw -name kMDItemCFBundleIdentifier "$path" 2>/dev/null)"
  if [ -z "$id" ] || [ "$id" = "(null)" ]; then
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist" 2>/dev/null)"
  fi
  found_ids="$found_ids $id"
  if echo "$listed" | grep -qxF "$id"; then s="in list"; else s="MISMATCH: not in CodingApps.swift"; fi
  printf '%-18s %-45s %s\n' "$name" "$id" "$s"
done <<< "$apps"

echo
echo "Listed in CodingApps.swift but no installed app has that ID (cannot verify here):"
for id in $listed; do
  case " $found_ids " in *" $id "*) ;; *) echo "  $id" ;; esac
done
