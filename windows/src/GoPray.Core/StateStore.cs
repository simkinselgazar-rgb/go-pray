// StateStore.cs — state.json on disk (§C.2). Port of Core/StateStore.swift.
// Atomic write: a temp file in the same directory, flushed to disk, then File.Move(overwrite) —
// MoveFileEx(REPLACE_EXISTING) on the same NTFS volume, so a half-written state.json is impossible.
// A bad file is moved aside and reads as idle (fail open). %LOCALAPPDATA% is user-only by its
// default ACL (the Mac's 0600).

using System;
using System.IO;

namespace GoPray.Core;

public sealed class StateStore(string directory)
{
    public abstract record LoadResult
    {
        /// <summary>First run: idle.</summary>
        public sealed record Missing : LoadResult;
        public sealed record Loaded(BlockStateFile State) : LoadResult;
        /// <summary>Renamed to state.corrupt-&lt;unix&gt;.json: idle.</summary>
        public sealed record Corrupt(string? MovedTo) : LoadResult;
    }

    public string Directory { get; } = directory;
    public string FilePath => Path.Combine(Directory, "state.json");

    /// <summary><c>%LOCALAPPDATA%\GoPray\</c> — the one place the app keeps state, settings and launch.json.</summary>
    public static string DefaultDirectory()
    {
#if DEBUG
        // DEBUG only (the Mac's TestHost folder): tests and screenshot runs never touch the real files.
        // Release has no switch: no environment variable can move state.json.
        var o = Environment.GetEnvironmentVariable("GOPRAY_DEBUG_STATE_DIR");
        if (!string.IsNullOrEmpty(o)) return o;
#endif
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GoPray");
    }

    public LoadResult Load()
    {
        byte[] data;
        try { data = File.ReadAllBytes(FilePath); }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) { return new LoadResult.Missing(); }
        catch (Exception e)
        {
            CoreLog.Error($"state.json unreadable: {e.Message}");
            return new LoadResult.Corrupt(Quarantine("unreadable"));
        }
        try { return new LoadResult.Loaded(BlockStateFile.Decode(data)); }
        catch (Exception e)
        {
            CoreLog.Error($"state.json does not decode: {e.Message}");
            return new LoadResult.Corrupt(Quarantine("decode"));
        }
    }

    /// <summary>Read-only look for the launch decision: true only when state.json decodes and holds a
    /// block. Never quarantines (the gate's launch does that).</summary>
    public bool PeekHasOpenBlock()
    {
        try { return BlockStateFile.Decode(File.ReadAllBytes(FilePath)).CurrentBlock is not null; }
        catch { return false; }
    }

    public void Save(BlockStateFile state)
    {
        System.IO.Directory.CreateDirectory(Directory);
        var data = state.Encode();
        var tmp = Path.Combine(Directory, $".state.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var fs = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                fs.Write(data);
                fs.Flush(flushToDisk: true);
            }
            File.Move(tmp, FilePath, overwrite: true);
        }
        finally
        {
            if (File.Exists(tmp)) File.Delete(tmp);
        }
    }

    /// <summary>Moves state.json aside as state.corrupt-&lt;unix&gt;.json. Returns the new path, or null if there
    /// was nothing to move (or the move failed; then the file is deleted).</summary>
    public string? Quarantine(string reason)
    {
        if (!File.Exists(FilePath)) return null;
        long stamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var dest = Path.Combine(Directory, $"state.corrupt-{stamp}.json");
        for (int n = 1; File.Exists(dest); n++) dest = Path.Combine(Directory, $"state.corrupt-{stamp}-{n}.json");
        try
        {
            File.Move(FilePath, dest);
            CoreLog.Error($"state.json quarantined ({reason}) → {Path.GetFileName(dest)}");
            return dest;
        }
        catch (Exception e)
        {
            try { File.Delete(FilePath); } catch { /* fail open: nothing more to do */ }
            CoreLog.Error($"state.json quarantine failed, deleted: {e.Message}");
            return null;
        }
    }

#if DEBUG
    public void Wipe()
    {
        try { File.Delete(FilePath); } catch { /* debug only */ }
    }
#endif
}

/// <summary>Core's only log sink. The app points it at its log file; tests leave it silent.</summary>
public static class CoreLog
{
    public static Action<string> Sink { get; set; } = _ => { };
    public static void Notice(string m) => Sink("notice " + m);
    public static void Error(string m) => Sink("error " + m);
}
