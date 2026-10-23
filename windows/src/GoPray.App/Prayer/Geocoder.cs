// Geocoder.cs — typed city → coordinates. The ONLY file allowed to touch the network (guard rule 4).
// PLAN.md §2: Windows has no keyless OS geocoder, so this is Open-Meteo's geocoding API (GeoNames data,
// no key, no account). Called only from a user action in the city search field (typing, after a short
// pause). Never at launch, never in the background, no location permission: it sends the typed text
// and nothing else.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using GoPray.Core;

namespace GoPray.App.Places;   // folder Prayer/ (guard rule 4 pins the network to Prayer/Geocoder.cs)

internal sealed class Geocoder : ICityGeocoding
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(8) };

    public async Task<IReadOnlyList<CityMatch>> SearchAsync(string text, CancellationToken cancel)
    {
        var q = text.Trim();
        if (q.Length < 2) return [];
        var url = "https://geocoding-api.open-meteo.com/v1/search?name=" + Uri.EscapeDataString(q) + "&count=10&language=en&format=json";
        string body;
        try { body = await Http.GetStringAsync(url, cancel); }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested) { throw; }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException) { throw new GeocodeOfflineException(e.Message); }
        return Parse(body);
    }

    /// <summary>Places with coordinates and a name, de-duplicated, at most 5 (a short list reads faster).</summary>
    internal static IReadOnlyList<CityMatch> Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        if (!doc.RootElement.TryGetProperty("results", out var results) || results.ValueKind != JsonValueKind.Array) return [];
        var seen = new HashSet<string>();
        var list = new List<CityMatch>();
        foreach (var r in results.EnumerateArray())
        {
            if (!r.TryGetProperty("name", out var n) || !r.TryGetProperty("latitude", out var la) || !r.TryGetProperty("longitude", out var lo)) continue;
            string? S(string k) => r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            var m = new CityMatch(n.GetString() ?? "", S("admin1"), S("country"), S("country_code"), la.GetDouble(), lo.GetDouble());
            if (m.Name.Length == 0 || !seen.Add(m.Label + m.CountryCode)) continue;
            list.Add(m);
            if (list.Count == 5) break;
        }
        return list;
    }
}
