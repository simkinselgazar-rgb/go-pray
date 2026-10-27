// ShieldPalette.cs — per-prayer colours from the approved styles.css (--ground, --text), plus the
// Nabawi green, and the prayer names. Port of the palette in Shield/NativeFallbackShield.swift.

using System.Collections.Generic;
using System.Windows.Media;
using GoPray.Core;

namespace GoPray.App.Shield;

internal readonly record struct ShieldPalette(Color Ground, Color Text)
{
    public static readonly Color Nabawi = Hex(0x3e6b3a);
    public static readonly Color OnNabawi = Hex(0xf4eee2);

    public static Color Hex(int v) => Color.FromRgb((byte)((v >> 16) & 255), (byte)((v >> 8) & 255), (byte)(v & 255));

    public static ShieldPalette Of(Prayer p) => p switch
    {
        Prayer.Fajr => new(Hex(0x0e0705), Hex(0xf2e4cc)),
        Prayer.Dhuhr => new(Hex(0xf0eee7), Hex(0x17232a)),
        Prayer.Asr => new(Hex(0xf1ece4), Hex(0x2d1c0e)),
        Prayer.Maghrib => new(Hex(0xf1d9bd), Hex(0x241c0d)),
        _ => new(Hex(0x08080f), Hex(0xede9e1)),
    };

    public static readonly IReadOnlyDictionary<Prayer, (string Latin, string Arabic)> Names = new Dictionary<Prayer, (string, string)>
    {
        [Prayer.Fajr] = ("Fajr", "الفجر"), [Prayer.Dhuhr] = ("Dhuhr", "الظهر"), [Prayer.Asr] = ("Asr", "العصر"),
        [Prayer.Maghrib] = ("Maghrib", "المغرب"), [Prayer.Isha] = ("Isha", "العشاء"),
    };
}
