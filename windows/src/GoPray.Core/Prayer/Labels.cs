// Labels.cs — plain-language names and help lines for every setting. Port of the UI-copy half of
// Prayer/Settings.swift and of Prayer/VoiceChoices.swift (same words, so the PM can diff the copy).

using System;
using System.Collections.Generic;
using System.Linq;

namespace GoPray.Core;

public sealed record MethodInfo(string Raw, string DisplayName, string ShortName, string Detail);

public static class Labels
{
    /// <summary>The methods we offer, in adhan-swift's order ("other" is not a choice).</summary>
    public static readonly IReadOnlyList<MethodInfo> Methods =
    [
        new("muslimWorldLeague", "Muslim World League", "MWL", "Fajr at 18°, Isha at 17°. A common default."),
        new("egyptian", "Egyptian General Authority", "Egyptian", "Fajr at 19.5°, Isha at 17.5°."),
        new("karachi", "University of Islamic Sciences, Karachi", "Karachi", "Fajr and Isha at 18°. Used across South Asia."),
        new("ummAlQura", "Umm al-Qura, Makkah", "Umm al-Qura", "Fajr at 18.5°. Isha 90 minutes after Maghrib."),
        new("dubai", "Dubai (UAE)", "Dubai", "Fajr and Isha at 18.2°. Used in the UAE."),
        new("moonsightingCommittee", "Moonsighting Committee", "Moonsighting", "Seasonal Fajr and Isha. Suits North America and the UK."),
        new("northAmerica", "ISNA (North America)", "ISNA", "Fajr and Isha at 15°. Used by many North American mosques."),
        new("kuwait", "Kuwait", "Kuwait", "Fajr at 18°, Isha at 17.5°."),
        new("qatar", "Qatar", "Qatar", "Fajr at 18°. Isha 90 minutes after Maghrib."),
        new("singapore", "Singapore, Malaysia, Indonesia", "Singapore", "Fajr at 20°, Isha at 18°."),
        new("tehran", "Tehran (Institute of Geophysics)", "Tehran", "Fajr at 17.7°, Isha at 14°."),
        new("turkey", "Turkey (Diyanet)", "Diyanet", "Close to the Diyanet timetable. Best inside Turkey."),
    ];

    public static MethodInfo? Method(string raw) => Methods.FirstOrDefault(m => m.Raw == raw);

    /// <summary>The method most mosques in a country follow. A suggestion, never forced.</summary>
    public static string SuggestedMethod(string? countryCode) => countryCode?.ToUpperInvariant() switch
    {
        "US" or "CA" => "northAmerica",
        "GB" => "moonsightingCommittee",
        "SA" => "ummAlQura",
        "EG" or "SD" or "LY" or "DZ" or "SY" or "LB" or "IQ" or "PS" or "JO" => "egyptian",
        "PK" or "IN" or "BD" or "AF" => "karachi",
        "AE" => "dubai",
        "KW" => "kuwait",
        "QA" => "qatar",
        "SG" or "MY" or "ID" or "BN" => "singapore",
        "IR" => "tehran",
        "TR" => "turkey",
        _ => "muslimWorldLeague",
    };

    public static string MadhabName(int madhab) => madhab == 2 ? "Hanafi" : "Standard";
    public static string MadhabHelp(int madhab) => madhab == 2
        ? "Asr starts later, when a shadow is twice as long as the object."
        : "Shafi, Maliki and Hanbali. Asr starts when a shadow is as long as the object.";

    public static string RuleName(string raw) => raw switch
    {
        "middleOfTheNight" => "Middle of the night",
        "seventhOfTheNight" => "Seventh of the night",
        "twilightAngle" => "Twilight angle",
        _ => raw,
    };
    public static string RuleHelp(string raw) => raw switch
    {
        "middleOfTheNight" => "Fajr and Isha never pass the middle of the night.",
        "seventhOfTheNight" => "Isha ends the first seventh of the night, Fajr starts the last seventh.",
        "twilightAngle" => "Splits the night by the Fajr and Isha angles.",
        _ => "",
    };

    public static string ModeName(BlockMode m) => m == BlockMode.WholeScreen ? "Whole screen" : "Coding apps only";
    public static string ModeChip(BlockMode m) => m == BlockMode.WholeScreen ? "Whole screen" : "Coding apps";
    public static string ModeHelp(BlockMode m) => m == BlockMode.WholeScreen
        ? "A calm screen covers everything until you pray."
        : "Only your coding apps rest. Your agents keep running.";

    public static string PauseName(PauseOption o) => o switch
    {
        PauseOption.OneDay => "For 1 day",
        PauseOption.ThreeDays => "For 3 days",
        PauseOption.OneWeek => "For 1 week",
        _ => "Until I resume",
    };

    public static string PrayerName(Prayer p) => p switch
    {
        Prayer.Fajr => "Fajr", Prayer.Dhuhr => "Dhuhr", Prayer.Asr => "Asr", Prayer.Maghrib => "Maghrib", _ => "Isha",
    };
    public static string PrayerArabic(Prayer p) => p switch
    {
        Prayer.Fajr => "الفجر", Prayer.Dhuhr => "الظهر", Prayer.Asr => "العصر", Prayer.Maghrib => "المغرب", _ => "العشاء",
    };
}

public sealed record VoiceChoice(Voice Voice, string Name);

/// <summary>The 16 Sunni and 12 Shia PrayTimes.org recordings. Fajr always uses Sheikh Hamed (not a choice).</summary>
public static class VoiceChoices
{
    public static readonly IReadOnlyList<VoiceChoice> Sunni = new (string, string)[]
    {
        ("Abdul-Basit", "Abdul Basit"), ("Abdul-Ghaffar", "Abdul Ghaffar"), ("Abdul-Hakam", "Abdul Hakam"),
        ("Adhan-Alaqsa", "Adhan Al-Aqsa"), ("Adhan-Egypt", "Adhan Egypt"), ("Adhan-Halab", "Adhan Halab"),
        ("Adhan-Madinah", "Adhan Madinah"), ("Adhan-Makkah", "Adhan Makkah"), ("Al-Hussaini", "Al-Hussaini"),
        ("Bakir-Bash", "Bakir Bash"), ("Hafez", "Hafez"), ("Hafiz-Murad", "Hafiz Murad"),
        ("Minshawi", "Minshawi"), ("Naghshbandi", "Naghshbandi"), ("Saber", "Saber"), ("Sharif-Doman", "Sharif Doman"),
    }.Select(v => new VoiceChoice(Voice.Sunni(v.Item1), v.Item2)).ToList();

    public static readonly IReadOnlyList<VoiceChoice> Shia = new (string, string)[]
    {
        ("Aghati", "Aghati"), ("Ghalwash", "Ghalwash"), ("Kazem-Zadeh", "Kazem Zadeh"),
        ("Moazzen-Zadeh", "Moazzen Zadeh"), ("Mohammad-Zadeh", "Mohammad Zadeh"), ("Rezaeian", "Rezaeian"),
        ("Rowhani-Nejad", "Rowhani Nejad"), ("Salimi", "Salimi"), ("Sharif", "Sharif"),
        ("Sobhdel", "Sobhdel"), ("Tasvieh-Chi", "Tasviyechi"), ("Tookhi", "Tookhi"),
    }.Select(v => new VoiceChoice(Voice.Shia(v.Item1), v.Item2)).ToList();

    public static IEnumerable<VoiceChoice> All => Sunni.Concat(Shia);
    public static Voice DefaultVoice => SettingsRules.DefaultVoice;
    public const string FajrStem = "C-egypt-cairo-mahmoudeya-sheikhhamed-fajr";
    /// <summary>Fajr always starts here: a playback offset, not a cut (the file stays unedited, CC BY-NC-ND).</summary>
    public const double FajrStartOffset = 9.0;
    public const string FajrNote = "Fajr always uses Sheikh Hamed's Athan, from the Mahmoudeya mosque in Cairo.";

    public static string Name(Voice v) => All.FirstOrDefault(c => c.Voice == v)?.Name ?? "Custom";
    public static bool IsValid(Voice v) => All.Any(c => c.Voice == v);
}

/// <summary>The credits screen text. Port of UI/CreditsViewData.swift.</summary>
public static class Credits
{
    public const string TakedownEmail = "hello@simkinselgazar.com";
    public const string TakedownLine = "If you own one of these recordings and want it removed, email us and we'll take it out.";
    public const string PrayTimesName = "PrayTimes.org";
    public const string PrayTimesUrl = "https://praytimes.org/docs/adhan";
    public const string PrayTimesLine = "Athan recordings from PrayTimes.org (© 2007–2026 PrayTimes.org).";
    public const string FajrLine = "Adhan al-Fajr, Sheikh Hamed, Mahmoudeya mosque, Cairo. Anna Kipervaser, On Look Films, LLC: Voices and Faces of the Adhan: Cairo. University of Cambridge, CC BY-NC-ND 3.0.";
    public const string FajrNote = "Played whole and unedited. It starts a few seconds in, to skip the quiet lead-in.";
    /// <summary>Windows only: the prayer math is a port of adhan-swift (MIT), see docs/adhan.md.</summary>
    public const string MathLine = "Prayer times: a C# port of adhan-swift by Batoul Apps (MIT License).";
    public static IEnumerable<string> SunniNames => VoiceChoices.Sunni.Select(v => v.Name);
    public static IEnumerable<string> ShiaNames => VoiceChoices.Shia.Select(v => v.Name);
    public static string TakedownText => string.IsNullOrEmpty(TakedownEmail) ? TakedownLine : $"{TakedownLine} ({TakedownEmail})";
}

public static class Copy
{
    public const string BlockedLine = "Settings open again after you pray.";
    public const string InvalidLine = "That didn't look right. Try again.";
    /// <summary>Windows version of the Mac's LoginAgentCopy.firstRunNote (no system prompt on Windows).</summary>
    public const string LaunchAtLoginNote = "Go Pray adds itself to Task Scheduler so it starts when you sign in and comes back if it is closed. Turn this off to remove it.";

    // v2 (PLAN-v2 §1.3, §9.2, §9.3, §8.1)
    public const string BlockedAppsHelp = "Only these apps rest in Coding apps mode. Turn ours off, or add your own. Changes start at the next prayer.";
    public const string BlockedAppsEmpty = "Nothing is on the list, so Coding apps mode rests nothing.";
    public const string CantRestThat = "Go Pray can't rest that one. It's part of Windows.";
    public const string AlreadyListed = "Already on the list.";

    // 0.3.0 TVs (PM brief 2026-10-24)
    public const string TvHelp = "Your TV needs the Go Pray Roku app.";
    public const string TvNotInstalled = "Go Pray isn't installed on this TV yet";
    public const string TvHostRefused = "Use the TV's address on your home Wi-Fi, like 192.168.1.20.";
    public const string TvAlreadyListed = "That TV is already on the list.";
    public const string TvUnreachable = "Couldn't reach a TV at that address. Check that it's on and on the same Wi-Fi.";
    public const string TvTestSent = "Sent. The TV should open Go Pray now.";
    public const string TvTestFailed = "Couldn't reach the TV. Check that it's on and on the same Wi-Fi.";
    public const string TvNoneFound = "No TVs found. Check that the TV is on and on the same Wi-Fi, or add it by its address (on the TV: Settings → Network → About).";
    public const string TvAllListed = "Every TV found is already on the list.";
    // 0.3.1 Setup's TV step
    public const string SetupTvTitle = "Play the Athan on your TV?";
    public const string SetupTvLine = "If you have a Roku TV, Go Pray can play the Athan on it at each prayer. Your TV needs the free Go Pray Roku app.";
    public const string TvReady = "Ready";
    public const string TvNotInstalledHelp = "Go Pray isn't installed on this TV yet. Search 'Go Pray' in the Roku Channel Store.";
    public const string TvFirewall = "Windows Firewall is blocking the replies from TVs. To allow them, an administrator can open Windows Defender Firewall → Advanced settings → Windows Defender Firewall Properties → this network's tab → Settings… and set \"Allow unicast response\" to Yes. Or add the TV by its address (on the TV: Settings → Network → About).";
    public const string AllowExitsHelp = "Up to 5 a year, for the days you truly can't stop. Off means no exit button at all. Changes start at the next prayer.";
    public const string CheckForUpdatesHelp = "Once a day, from GitHub. Nothing about you is sent.";

    /// <summary>"Emergency exits: 3 of 5 left this year" / "…: none left until 1 January" / "…: off".</summary>
    public static string EmergencyLine(bool enabled, int left) =>
        !enabled ? "Emergency exits: off"
        : left <= 0 ? "Emergency exits: none left until 1 January"
        : $"Emergency exits: {left} of {EmergencyExitPolicy.Total} left this year";

    /// <summary>The shield footer: "Hold for emergency exit · 3 of 5 left this year".</summary>
    public static string EmergencyButton(int left) => $"Hold for emergency exit · {left} of {EmergencyExitPolicy.Total} left this year";

    public const string EmergencyHolding = "Keep holding…";
    public const string EmergencyCardTitle = "Use an emergency exit?";

    /// <summary>"This ends the block now. Asr will count as missed, not prayed. You'll have 2 of 5 left this year."</summary>
    public static string EmergencyCardBody(Prayer p, int left) =>
        $"This ends the block now. {Labels.PrayerName(p)} will count as missed, not prayed. "
        + (left <= 1 ? "This is your last one this year." : $"You'll have {left - 1} of {EmergencyExitPolicy.Total} left this year.");

    public const string EmergencyNotNow = "Not now";
    public const string EmergencyUseIt = "Use it";
    public const string EmergencyFailed = "Couldn't use the exit. Try again in a moment.";
}
