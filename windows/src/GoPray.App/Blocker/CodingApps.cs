// CodingApps.cs — the compiled-in list of apps minimised in "Coding apps only" mode (PLAN.md §3 row 2).
// A static list inside the signed exe on purpose: not a user file, so it cannot be edited to dodge a block.
// Process names, compared case-insensitively (spike Q6: Warp's process is "warp"). Console windows belong
// to the shell inside them (cmd, powershell, pwsh), and Windows Terminal windows to WindowsTerminal.
// Seen on Ahmed's PC (spike Q6, 2026-10-23): cmd, msedge, Cursor, WindowsTerminal, warp, powershell, ChatGPT.
// The rest come from the plan and are UNVERIFIED here; a wrong name is harmless (nothing matches).

using System;
using System.Collections.Generic;
using System.Linq;

namespace GoPray.App.Blocker;

internal static class CodingApps
{
    /// <summary>process name → the name the notice shows ("Cursor is resting until you pray.").</summary>
    public static readonly IReadOnlyDictionary<string, string> Names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        // AI + terminals
        ["claude"] = "Claude",
        ["ChatGPT"] = "ChatGPT",
        ["Codex"] = "Codex",                         // UNVERIFIED exe name
        ["WindowsTerminal"] = "Windows Terminal",
        ["OpenConsole"] = "Terminal",
        ["conhost"] = "Console",
        ["cmd"] = "Command Prompt",
        ["powershell"] = "PowerShell",
        ["pwsh"] = "PowerShell",
        ["warp"] = "Warp",
        ["wezterm-gui"] = "WezTerm",
        ["alacritty"] = "Alacritty",
        ["mintty"] = "Git Bash",
        // Editors
        ["Code"] = "Visual Studio Code",
        ["Code - Insiders"] = "Visual Studio Code Insiders",
        ["Cursor"] = "Cursor",
        ["Windsurf"] = "Windsurf",
        ["zed"] = "Zed",
        ["devenv"] = "Visual Studio",
        ["rider64"] = "Rider",
        ["idea64"] = "IntelliJ IDEA",
        // Browsers
        ["chrome"] = "Google Chrome",
        ["msedge"] = "Microsoft Edge",
        ["firefox"] = "Firefox",
        ["brave"] = "Brave",
        ["Arc"] = "Arc",
        ["opera"] = "Opera",
        ["vivaldi"] = "Vivaldi",
    };

    public static bool IsListed(string processName) => Names.ContainsKey(processName);
    public static string DisplayName(string processName) => Names.TryGetValue(processName, out var n) ? n : processName;
}
