// SettingsStore.cs — settings.json on disk, and the ONE door for changing settings.
// Port of Prayer/SettingsStore.swift (CONTRACT-NOTES #3, #5, #14, #26, #27).
//
// Every change goes through Mutate, and Mutate asks the gate first (AuthorizeSettingsChange: throws
// SettingsBlockedException during a block). That covers mode, break length, pause and resume too.
// With no gate attached the store refuses everything (fail closed): a wiring slip can never open a
// hole in a block.

using System;
using System.IO;

namespace GoPray.Core;

public sealed class SettingsStore
{
    public Settings Settings { get; private set; }
    /// <summary>True when settings.json could not be read and was set aside (the app starts fresh).</summary>
    public bool LoadedFromCorruptFile { get; private set; }
    /// <summary>True if the last write to disk failed. The change is still live in memory.</summary>
    public bool LastSaveFailed { get; private set; }

    /// <summary>Called after a change was applied and saved. Wire to scheduler.Handle(SettingsChanged).</summary>
    public Action<Settings>? OnChange { get; set; }

    WeakReference<ISettingsChangeAuthorizing>? _gate;
    readonly string _directory;

    public string FilePath => Path.Combine(_directory, "settings.json");

    public SettingsStore(string? directory = null)
    {
        _directory = directory ?? StateStore.DefaultDirectory();
        Settings = SettingsRules.Defaults;
        Settings = Load();
    }

    public void Attach(ISettingsChangeAuthorizing gate) => _gate = new WeakReference<ISettingsChangeAuthorizing>(gate);

    // MARK: Changing settings

    /// <summary>Throws SettingsBlockedException during a block, and also when no gate is attached. Call it
    /// before any side effect that belongs to a setting (e.g. creating the logon task).</summary>
    public void Authorize()
    {
        if (_gate is null || !_gate.TryGetTarget(out var gate)) throw new SettingsBlockedException();
        gate.AuthorizeSettingsChange();
    }

    /// <summary>Apply <paramref name="change"/>, clamp what has a range, reject what is invalid, save, notify.
    /// The gate is asked first, so a refused change never runs <paramref name="change"/> at all.</summary>
    public void Mutate(Func<Settings, Settings> change)
    {
        Authorize();
        var next = change(Settings).Sanitized();
        next.Validate();
        if (next == Settings) return;
        Settings = next;
        Save();
        OnChange?.Invoke(next);
    }

    /// <summary>Pause (1 day / 3 days / 1 week / until resumed). Only between prayers.</summary>
    public void Pause(PauseOption option, DateTime now, TimeZoneInfo? zone = null)
    {
        var until = option.Until(now, zone);
        Mutate(s => s with { PausedUntil = until });
    }

    /// <summary>Resume now (CONTRACT-NOTES #27: set PausedUntil to now). Only between prayers.</summary>
    public void Resume(DateTime now)
    {
        if (Settings.PausedUntil == null) return;
        Mutate(s => s with { PausedUntil = now });
    }

    // MARK: Disk

    Settings Load()
    {
        byte[] data;
        try { data = File.ReadAllBytes(FilePath); }
        catch { return SettingsRules.Defaults; }                     // first run
        try
        {
            var s = SettingsRules.DecodeSettings(data).Sanitized();
            s.Validate();
            return s;
        }
        catch (Exception e)
        {
            // Keep the unreadable file for inspection and start fresh. Fresh = setup not complete =
            // nothing blocks until the person sets up again.
            var aside = Path.Combine(_directory, $"settings.corrupt-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}.json");
            try { File.Move(FilePath, aside); } catch { /* fail open */ }
            LoadedFromCorruptFile = true;
            CoreLog.Error($"settings.json unreadable, set aside: {e.Message}");
            return SettingsRules.Defaults;
        }
    }

    void Save()
    {
        var tmp = Path.Combine(_directory, $".settings.{Guid.NewGuid():N}.tmp");
        try
        {
            Directory.CreateDirectory(_directory);
            File.WriteAllBytes(tmp, Settings.Encode());
            File.Move(tmp, FilePath, overwrite: true);
            LastSaveFailed = false;
        }
        catch (Exception e)
        {
            LastSaveFailed = true;
            CoreLog.Error($"settings.json save failed: {e.Message}");
        }
        finally
        {
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch { /* best effort */ }
        }
    }
}
