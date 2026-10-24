// UpdateChecker.cs — "is there a newer Go Pray?" (PLAN-v2 §8). The only file besides Prayer/Geocoder.cs that may
// touch the network, and the only one that knows GitHub's URLs, verifies a download or starts an installer
// (guard.ps1 rule 4).
//
// Rules (§8.1):
//  1. One anonymous GET of the repo's releases list (User-Agent "GoPray", no ids, no cookies: no telemetry). Drafts and
//     prereleases are skipped; only tags "win-v<major>.<minor>.<patch>" count; the highest wins.
//  2. Offered only when strictly newer than the running version.
//  3. 30 s after launch, then every 24 h, and on wake when the last check is older than 24 h, if Settings.CheckForUpdates
//     is on; "Check for updates…" always works. NEVER while a block is up: no request, no download, no installer.
//  4. The asset must be exactly https://github.com/<repo>/releases/download/<tag>/GoPray-Setup-<ver>.exe (+ .sha256),
//     at most 300 MB. Redirects are followed by hand, https only, to GitHub's download hosts only.
//  5. Verify before running, or delete: SHA-256 equals the .sha256 asset, WinVerifyTrust accepts the signature, and the
//     signer's CN is "Ahmed Elgazar". Any failure: the file is deleted and the menu says so.
//  6. Run the installer, then quit (the gate allows it: rule 3 excluded blocks). Inno closes nothing else.
//  7. update.json (schemaVersion, lastCheckedAt, latest) is this file's alone; corrupt = never checked. Downloads go to
//     <data>\updates\, cleared at launch.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using GoPray.Core;

namespace GoPray.App.Update;

/// <summary>The network side (tests use a fake).</summary>
internal interface IUpdateTransport
{
    Task<string> GetText(Uri url, CancellationToken cancel);
    /// <summary>Downloads to <paramref name="path"/>; throws past <paramref name="maxBytes"/>.</summary>
    Task Download(Uri url, string path, long maxBytes, CancellationToken cancel);
}

/// <summary>sha256 + Authenticode + signer CN (tests use a fake).</summary>
internal interface IUpdateVerifier
{
    bool Verify(string file, string expectedSha256);
}

internal enum UpdateStatus { Idle, Checking, UpToDate, Available, Downloading, Failed }

internal sealed record UpdateRelease(string Tag, Version Version, Uri Setup, Uri Sha256, long Size);

internal sealed class UpdateChecker
{
    public const string Repo = "simkinselgazar-rgb/go-pray";
    public const string TagPrefix = "win-v";
    public const string SignerName = "Ahmed Elgazar";
    public const long MaxBytes = 300L * 1024 * 1024;
    public static readonly TimeSpan Interval = TimeSpan.FromHours(24);
    public static readonly TimeSpan FirstDelay = TimeSpan.FromSeconds(30);
    static readonly Uri ReleasesApi = new("https://api.github.com/repos/" + Repo + "/releases?per_page=30");
    static readonly string DownloadPrefix = "https://github.com/" + Repo + "/releases/download/";
    public static readonly Uri ReleasesPage = new("https://github.com/" + Repo + "/releases");

    readonly IUpdateTransport _net;
    readonly IUpdateVerifier _verify;
    readonly Version _current;
    readonly string _dir;
    readonly Func<bool> _isBlocked, _automatic;
    readonly IClock _clock;
    readonly Action<string> _runAndQuit;
    readonly SemaphoreSlim _one = new(1, 1);

    public UpdateStatus Status { get; private set; } = UpdateStatus.Idle;
    public UpdateRelease? Latest { get; private set; }
    public string? Message { get; private set; }
    public event Action? Changed;
    /// <summary>Tests: how many times a check reached the network.</summary>
    public int Requests { get; private set; }

    public UpdateChecker(Version current, string directory, Func<bool> isBlocked, Func<bool> automatic, IClock clock,
                         Action<string> runAndQuit, IUpdateTransport? transport = null, IUpdateVerifier? verifier = null)
    {
        _current = new Version(current.Major, current.Minor, Math.Max(0, current.Build));
        _dir = directory; _isBlocked = isBlocked; _automatic = automatic; _clock = clock; _runAndQuit = runAndQuit;
        _net = transport ?? new HttpTransport();
        _verify = verifier ?? new SignatureVerifier();
    }

    public string UpdatesDir => Path.Combine(_dir, "updates");
    public string MemoryFile => Path.Combine(_dir, "update.json");

    /// <summary>At launch: clear old downloads. The caller's timer then calls <see cref="AutomaticCheck"/>.</summary>
    public void ClearDownloads()
    {
        try { if (Directory.Exists(UpdatesDir)) Directory.Delete(UpdatesDir, recursive: true); }
        catch (Exception e) { CoreLog.Notice("updates folder not cleared yet: " + e.Message); }
    }

    /// <summary>The 30 s / daily / wake check: only when switched on, not blocked, and the last one is ≥ 24 h old.</summary>
    public async Task AutomaticCheck()
    {
        if (!_automatic() || _isBlocked()) return;
        if (LastCheckedAt() is { } last && _clock.Now - last < Interval && _clock.Now >= last) return;
        await Check();
    }

    /// <summary>"Check for updates…": works with the switch off, never during a block.</summary>
    public Task CheckNow() => Check(manual: true);

    async Task Check(bool manual = false)
    {
        if (_isBlocked()) return;
        if (!await _one.WaitAsync(0)) return;
        try
        {
            Set(UpdateStatus.Checking, null);
            Requests++;
            string body;
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30))) body = await _net.GetText(ReleasesApi, cts.Token);
            var best = Pick(body, _current);
            Remember(best);
            Latest = best;
            Set(best != null ? UpdateStatus.Available : UpdateStatus.UpToDate, best != null ? null : (manual ? "You're up to date." : null));
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or OperationCanceledException or IOException or JsonException or FormatException or InvalidOperationException)
        {
            CoreLog.Notice("update check failed: " + e.Message);
            Set(UpdateStatus.Failed, "Couldn't reach GitHub. Try later.");
        }
        finally { _one.Release(); }
    }

    /// <summary>The "Update available: Download" click. Verify or delete; then run the installer and quit.</summary>
    public async Task DownloadAndOpen()
    {
        if (Latest is not { } r || _isBlocked()) return;
        if (!await _one.WaitAsync(0)) return;
        string? setup = null;
        try
        {
            Set(UpdateStatus.Downloading, "Downloading…");
            Directory.CreateDirectory(UpdatesDir);
            setup = Path.Combine(UpdatesDir, $"GoPray-Setup-{r.Version.ToString(3)}.exe");
            var shaFile = setup + ".sha256";
            using (var cts = new CancellationTokenSource(TimeSpan.FromMinutes(10)))
            {
                await _net.Download(r.Sha256, shaFile, 4096, cts.Token);
                await _net.Download(r.Setup, setup, MaxBytes, cts.Token);
            }
            var expected = File.ReadAllText(shaFile).Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
            if (!_verify.Verify(setup, expected))
            {
                Delete(setup); Delete(shaFile);
                CoreLog.Error("update download failed verification; deleted");
                Set(UpdateStatus.Failed, "Couldn't verify the download. Get it from GitHub.");
                return;
            }
            if (_isBlocked()) { Set(UpdateStatus.Available, null); return; }   // a block started while downloading
            CoreLog.Notice($"update {r.Tag}: verified, running the installer");
            _runAndQuit(setup);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or OperationCanceledException or IOException or InvalidOperationException or UnauthorizedAccessException)
        {
            if (setup != null) { Delete(setup); Delete(setup + ".sha256"); }
            CoreLog.Notice("update download failed: " + e.Message);
            Set(UpdateStatus.Failed, "Couldn't reach GitHub. Try later.");
        }
        finally { _one.Release(); }
    }

    /// <summary>Runs a verified installer, outside any block (the caller quits right after).</summary>
    public static void RunInstaller(string setup) => Process.Start(new ProcessStartInfo(setup) { UseShellExecute = true });

    /// <summary>"Couldn't verify the download. Get it from GitHub." → the releases page in the browser.</summary>
    public static void OpenReleasesPage() => Process.Start(new ProcessStartInfo(ReleasesPage.AbsoluteUri) { UseShellExecute = true });

    void Set(UpdateStatus s, string? message) { Status = s; Message = message; Changed?.Invoke(); }

    static void Delete(string p) { try { File.Delete(p); } catch (Exception) { /* best effort */ } }

    // MARK: picking a release (pure, tested)

    internal static UpdateRelease? Pick(string releasesJson, Version current)
    {
        using var doc = JsonDocument.Parse(releasesJson);
        if (doc.RootElement.ValueKind != JsonValueKind.Array) throw new FormatException("releases is not an array");
        UpdateRelease? best = null;
        foreach (var rel in doc.RootElement.EnumerateArray())
        {
            if (rel.ValueKind != JsonValueKind.Object) continue;
            if (Bool(rel, "draft") || Bool(rel, "prerelease")) continue;
            if (!rel.TryGetProperty("tag_name", out var t) || t.ValueKind != JsonValueKind.String) continue;
            var tag = t.GetString()!;
            if (ParseTag(tag) is not { } v || v <= current || (best != null && v <= best.Version)) continue;
            var name = $"GoPray-Setup-{v.ToString(3)}.exe";
            Uri? setup = null, sha = null;
            long size = 0;
            if (rel.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
                foreach (var a in assets.EnumerateArray())
                {
                    var an = a.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString() : null;
                    var url = a.TryGetProperty("browser_download_url", out var u) && u.ValueKind == JsonValueKind.String ? u.GetString() : null;
                    if (an == name) { setup = Pinned(url, tag, name); size = a.TryGetProperty("size", out var sz) && sz.TryGetInt64(out var l) ? l : 0; }
                    else if (an == name + ".sha256") sha = Pinned(url, tag, name + ".sha256");
                }
            if (setup == null || sha == null || size <= 0 || size > MaxBytes) continue;    // off our path, missing or too big
            best = new UpdateRelease(tag, v, setup, sha, size);
        }
        return best;
    }

    /// <summary>"win-v0.2.0" → 0.2.0. Anything else (no prefix, "-beta", four parts) → null.</summary>
    internal static Version? ParseTag(string tag)
    {
        if (!tag.StartsWith(TagPrefix, StringComparison.Ordinal)) return null;
        var parts = tag[TagPrefix.Length..].Split('.');
        if (parts.Length != 3 || !parts.All(p => p.Length is > 0 and <= 6 && p.All(char.IsAsciiDigit))) return null;
        return new Version(int.Parse(parts[0]), int.Parse(parts[1]), int.Parse(parts[2]));
    }

    /// <summary>The URL must be exactly our repo's download path for this tag and asset.</summary>
    static Uri? Pinned(string? url, string tag, string asset) =>
        url == DownloadPrefix + tag + "/" + asset && Uri.TryCreate(url, UriKind.Absolute, out var u) ? u : null;

    static bool Bool(JsonElement o, string key) => o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;

    // MARK: update.json

    internal DateTime? LastCheckedAt()
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllBytes(MemoryFile));
            var r = doc.RootElement;
            if (r.GetProperty("schemaVersion").GetInt32() != 1) return null;
            return DateTimeOffset.Parse(r.GetProperty("lastCheckedAt").GetString()!, System.Globalization.CultureInfo.InvariantCulture).UtcDateTime;
        }
        catch (Exception) { return null; }        // missing or corrupt = never checked
    }

    void Remember(UpdateRelease? latest)
    {
        try
        {
            Directory.CreateDirectory(_dir);
            var o = new Dictionary<string, object?>
            {
                ["lastCheckedAt"] = _clock.Now.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture),
                ["latest"] = latest == null ? null : new Dictionary<string, object> { ["assetURL"] = latest.Setup.AbsoluteUri, ["size"] = latest.Size, ["tag"] = latest.Tag, ["version"] = latest.Version.ToString(3) },
                ["schemaVersion"] = 1,
            };
            var tmp = MemoryFile + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(o, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(tmp, MemoryFile, overwrite: true);
        }
        catch (Exception e) { CoreLog.Notice("update.json not written: " + e.Message); }
    }

    // MARK: the real network

    sealed class HttpTransport : IUpdateTransport
    {
        static readonly string[] Hosts = ["api.github.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"];
        static readonly HttpClient Http = new(new SocketsHttpHandler
        {
            AllowAutoRedirect = false,                       // every hop is checked below
            ConnectTimeout = TimeSpan.FromSeconds(10),
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.None,
        }) { Timeout = Timeout.InfiniteTimeSpan };

        static HttpRequestMessage Request(Uri url)
        {
            var m = new HttpRequestMessage(HttpMethod.Get, url);
            m.Headers.UserAgent.ParseAdd("GoPray");
            m.Headers.Accept.ParseAdd(url.Host == "api.github.com" ? "application/vnd.github+json" : "application/octet-stream");
            return m;
        }

        static async Task<HttpResponseMessage> Follow(Uri url, CancellationToken cancel)
        {
            for (int hop = 0; hop < 5; hop++)
            {
                if (url.Scheme != Uri.UriSchemeHttps || !Hosts.Contains(url.Host)) throw new InvalidOperationException("redirect to " + url.Host + " refused");
                var res = await Http.SendAsync(Request(url), HttpCompletionOption.ResponseHeadersRead, cancel);
                if ((int)res.StatusCode is >= 300 and < 400 && res.Headers.Location is { } next)
                {
                    res.Dispose();
                    url = next.IsAbsoluteUri ? next : new Uri(url, next);
                    continue;
                }
                res.EnsureSuccessStatusCode();
                return res;
            }
            throw new InvalidOperationException("too many redirects");
        }

        public async Task<string> GetText(Uri url, CancellationToken cancel)
        {
            using var res = await Follow(url, cancel);
            return await res.Content.ReadAsStringAsync(cancel);
        }

        public async Task Download(Uri url, string path, long maxBytes, CancellationToken cancel)
        {
            using var res = await Follow(url, cancel);
            if (res.Content.Headers.ContentLength is { } len && len > maxBytes) throw new InvalidOperationException("download too large");
            await using var src = await res.Content.ReadAsStreamAsync(cancel);
            await using var dst = File.Create(path);
            var buf = new byte[81920];
            long total = 0;
            int n;
            while ((n = await src.ReadAsync(buf, cancel)) > 0)
            {
                total += n;
                if (total > maxBytes) throw new InvalidOperationException("download too large");
                await dst.WriteAsync(buf.AsMemory(0, n), cancel);
            }
        }
    }

    // MARK: verification

    internal sealed class SignatureVerifier : IUpdateVerifier
    {
        public bool Verify(string file, string expectedSha256)
        {
            try
            {
                if (expectedSha256.Length != 64) return false;
                using (var s = File.OpenRead(file))
                    if (!Convert.ToHexString(SHA256.HashData(s)).Equals(expectedSha256, StringComparison.OrdinalIgnoreCase)) return false;
                if (WinTrust.Check(file) != 0) return false;
#pragma warning disable SYSLIB0057 // the signer of an Authenticode file; no non-obsolete API returns it
                using var cert = new X509Certificate2(X509Certificate.CreateFromSignedFile(file));
#pragma warning restore SYSLIB0057
                return cert.GetNameInfo(X509NameType.SimpleName, forIssuer: false) == SignerName;
            }
            catch (Exception e) when (e is IOException or CryptographicException or UnauthorizedAccessException) { return false; }
        }
    }

    static class WinTrust
    {
        static readonly Guid GenericVerifyV2 = new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct FileInfo { public uint cbStruct; public string pcwszFilePath; public IntPtr hFile; public IntPtr pgKnownSubject; }

        [StructLayout(LayoutKind.Sequential)]
        struct Data
        {
            public uint cbStruct; public IntPtr pPolicyCallbackData; public IntPtr pSIPClientData; public uint dwUIChoice;
            public uint fdwRevocationChecks; public uint dwUnionChoice; public IntPtr pFile; public uint dwStateAction;
            public IntPtr hWVTStateData; public IntPtr pwszURLReference; public uint dwProvFlags; public uint dwUIContext;
            public IntPtr pSignatureSettings;
        }

        [DllImport("wintrust.dll", CharSet = CharSet.Unicode)]
        static extern int WinVerifyTrust(IntPtr hwnd, [MarshalAs(UnmanagedType.LPStruct)] Guid action, IntPtr data);

        /// <summary>0 = trusted. No UI, whole-chain revocation check, state closed again.</summary>
        public static int Check(string path)
        {
            var fi = new FileInfo { cbStruct = (uint)Marshal.SizeOf<FileInfo>(), pcwszFilePath = path };
            IntPtr pFile = Marshal.AllocHGlobal(Marshal.SizeOf<FileInfo>());
            IntPtr pData = Marshal.AllocHGlobal(Marshal.SizeOf<Data>());
            try
            {
                Marshal.StructureToPtr(fi, pFile, false);
                var d = new Data
                {
                    cbStruct = (uint)Marshal.SizeOf<Data>(), dwUIChoice = 2 /* WTD_UI_NONE */, fdwRevocationChecks = 1 /* WTD_REVOKE_WHOLECHAIN */,
                    dwUnionChoice = 1 /* WTD_CHOICE_FILE */, pFile = pFile, dwStateAction = 1 /* WTD_STATEACTION_VERIFY */,
                };
                Marshal.StructureToPtr(d, pData, false);
                int result = WinVerifyTrust(IntPtr.Zero, GenericVerifyV2, pData);
                d = Marshal.PtrToStructure<Data>(pData);
                d.dwStateAction = 2;                         // WTD_STATEACTION_CLOSE
                Marshal.StructureToPtr(d, pData, true);
                WinVerifyTrust(IntPtr.Zero, GenericVerifyV2, pData);
                return result;
            }
            finally
            {
                Marshal.DestroyStructure<FileInfo>(pFile);
                Marshal.FreeHGlobal(pFile);
                Marshal.FreeHGlobal(pData);
            }
        }
    }
}
