// CitySearch.cs — the typed-city search, its states (skeleton / results / no match / offline), and
// "Enter coordinates instead". Port of CityMatch (Prayer/Geocoder.swift) and CitySearchModel
// (UI/SetupViewComponents.swift). The network lookup itself is in GoPray.App/Prayer/Geocoder.cs
// (guard rule 4: the only file that may touch the network).

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace GoPray.Core;

public sealed record CityMatch(string Name, string? Region, string? Country, string? CountryCode, double Latitude, double Longitude)
{
    public string Id => $"{Name}|{Region}|{CountryCode}|{Latitude.ToString(CultureInfo.InvariantCulture)}|{Longitude.ToString(CultureInfo.InvariantCulture)}";
    public string Title => Name;
    public string Subtitle => string.Join(", ", new[] { Region, Country }.Where(x => !string.IsNullOrEmpty(x)));
    /// <summary>What Settings stores as the city: "Toronto, Ontario" or just the name.</summary>
    public string Label => Subtitle.Length == 0 ? Name : $"{Name}, {Region ?? Country ?? ""}";
}

public sealed class GeocodeOfflineException(string message) : Exception(message);

public interface ICityGeocoding
{
    /// <summary>Empty list = no match. Throws GeocodeOfflineException when the service cannot be reached.</summary>
    Task<IReadOnlyList<CityMatch>> SearchAsync(string text, CancellationToken cancel);
}

/// <summary>"43.65, -79.38" → a place with no name lookup.</summary>
public static class CoordinateInput
{
    public static CityMatch? Parse(string text)
    {
        var parts = text.Split([',', ';', '\t', ' '], StringSplitOptions.RemoveEmptyEntries)
            .Select(p => double.TryParse(p, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : (double?)null).ToList();
        if (parts.Count != 2 || parts.Any(p => p == null)) return null;
        double lat = parts[0]!.Value, lon = parts[1]!.Value;
        if (lat is < -90 or > 90 || lon is < -180 or > 180) return null;
        return new CityMatch(string.Format(CultureInfo.InvariantCulture, "{0:0.00}°, {1:0.00}°", lat, lon), null, null, null, lat, lon);
    }
}

public enum SearchState { Idle, Searching, Results, NoMatch, Offline }

/// <summary>Creating the model never searches. A search only starts from QueryChanged (a keystroke: a user
/// action), after a short debounce; a newer keystroke cancels the older search.</summary>
public sealed class CitySearchModel(ICityGeocoding geocoder, TimeSpan? debounce = null)
{
    readonly TimeSpan _debounce = debounce ?? TimeSpan.FromMilliseconds(450);
    CancellationTokenSource? _cts;
    Task _task = Task.CompletedTask;

    public string Query { get; private set; } = "";
    public SearchState State { get; private set; } = SearchState.Idle;
    public IReadOnlyList<CityMatch> Results { get; private set; } = [];
    public bool CoordinateMode { get; set; }
    public string CoordinateText { get; set; } = "";
    public CityMatch? CoordinateMatch => CoordinateInput.Parse(CoordinateText);
    /// <summary>Raised on the caller's synchronization context whenever State changes.</summary>
    public event Action? Changed;

    public void QueryChanged(string text)
    {
        Query = text;
        _cts?.Cancel();
        var trimmed = text.Trim();
        if (trimmed.Length < 2) { Set(SearchState.Idle, []); return; }
        Set(SearchState.Searching, Results);
        var cts = _cts = new CancellationTokenSource();
        _task = Run(trimmed, cts.Token);
    }

    async Task Run(string q, CancellationToken token)
    {
        try
        {
            await Task.Delay(_debounce, token);
            var found = await geocoder.SearchAsync(q, token);
            if (token.IsCancellationRequested) return;
            Set(found.Count == 0 ? SearchState.NoMatch : SearchState.Results, found);
        }
        catch (OperationCanceledException) { }
        catch (Exception)
        {
            if (!token.IsCancellationRequested) Set(SearchState.Offline, []);
        }
    }

    void Set(SearchState s, IReadOnlyList<CityMatch> r) { State = s; Results = r; Changed?.Invoke(); }

    /// <summary>Waits for the search in flight. Tests only.</summary>
    public Task Settle() => _task;

    public const string NoMatchLine = "No match. Try a bigger city nearby, or enter coordinates.";
    public const string OfflineLine = "Can't reach the map service right now. Check your connection, or enter coordinates.";
    public const string CoordinateHint = "Latitude, then longitude. For example 43.65, -79.38.";
    public const string CoordinateError = "Use two numbers: latitude (-90 to 90), then longitude (-180 to 180).";
}
