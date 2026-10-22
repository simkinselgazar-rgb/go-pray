// CodingApps.swift — the hardcoded list of apps hidden in "Coding apps only" mode.
// Lane D. A static list inside the signed bundle on purpose (Architecture Plan §C, Mode B):
// not a user file, so it cannot be edited to dodge a block.
//
// Verified with scripts/bundle-ids.sh on 2026-10-22 (Ahmed's Mac). Installed and confirmed:
//   Claude com.anthropic.claudefordesktop | Terminal com.apple.Terminal | iTerm2 com.googlecode.iterm2
//   Warp dev.warp.Warp-Stable | "ChatGPT.app" com.openai.codex (this is the Codex app) | VS Code com.microsoft.VSCode
//   Xcode (Xcode-26-Beta.app) com.apple.dt.Xcode | Chrome com.google.Chrome | Safari com.apple.Safari
//   Brave com.brave.Browser
// NOT installed here, so the ID comes from the plan or the vendor and is UNVERIFIED on this Mac:
//   Ghostty, Cursor, VS Code Insiders, Windsurf, Zed, Arc, Firefox, Edge, Dia, Opera, Vivaldi, ChatGPT (com.openai.chat).
// A wrong ID here is harmless (nothing matches, nothing is hidden); a missing ID leaves that app usable.
//
// Xcode is IN the list: he codes in it, and hide never stops a build or loses a buffer.

import Foundation

enum CodingApps {
    static let bundleIDs: Set<String> = [
        // AI + terminals
        "com.anthropic.claudefordesktop",   // Claude desktop
        "com.apple.Terminal",
        "com.googlecode.iterm2",            // iTerm2
        "dev.warp.Warp-Stable",             // Warp
        "com.mitchellh.ghostty",            // Ghostty (UNVERIFIED)
        "com.openai.codex",                 // Codex (the /Applications/ChatGPT.app on this Mac)
        "com.openai.chat",                  // ChatGPT desktop (UNVERIFIED)
        // Editors
        "com.todesktop.230313mzl4w4u92",    // Cursor (UNVERIFIED)
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",     // (UNVERIFIED)
        "com.exafunction.windsurf",         // Windsurf (UNVERIFIED)
        "dev.zed.Zed",                      // (UNVERIFIED)
        "com.apple.dt.Xcode",
        // Browsers
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",       // Arc (UNVERIFIED)
        "org.mozilla.firefox",              // (UNVERIFIED)
        "com.brave.Browser",
        "com.microsoft.edgemac",            // Edge (UNVERIFIED)
        "company.thebrowser.dia",           // Dia (UNVERIFIED)
        "com.operasoftware.Opera",          // (UNVERIFIED)
        "com.vivaldi.Vivaldi",              // (UNVERIFIED)
    ]
}
