// AthanPlayer.cs — IAthanPlaying on NAudio (MIT). Port of Audio/AthanPlayer.swift + Voices.swift.
// - Files: <app>\Resources\athan\{sunni,shia}\<stem>.mp3 and athan\fajr\<fajr stem>.mp3 (synced from the Mac tree).
// - Fajr always plays Sheikh Hamed from 9.0 s (spike Q5: Mp3FileReader seeks exactly). The file stays unedited.
// - The system volume and mute are never touched: AthanVolume maps to WaveOutEvent.Volume only.
// - Stop() never calls OnFinished; only a natural end does (the gate handles its own stops).
// - Other media is paused right before the sound starts, and only if the file opened (a throw never pauses).

using System;
using System.IO;
using System.Windows.Threading;
using GoPray.Core;
using NAudio.Wave;

namespace GoPray.App.Audio;

internal sealed class AthanException(string message) : Exception(message);

internal sealed class AthanPlayer : IAthanPlaying
{
    readonly string _root;
    readonly IMediaPausing _pauser;
    readonly Dispatcher _ui = Dispatcher.CurrentDispatcher;
    WaveOutEvent? _out;
    Mp3FileReader? _reader;

    public AthanPlayer(string? root = null, IMediaPausing? pauser = null)
    {
        _root = root ?? Path.Combine(AppContext.BaseDirectory, "Resources", "athan");
        _pauser = pauser ?? new MediaPauser();
    }

    public Action? OnFinished { get; set; }
    public bool IsPlaying => _out?.PlaybackState == PlaybackState.Playing;
    /// <summary>Seconds into the file; 0 when nothing is loaded.</summary>
    public double Position => _reader?.CurrentTime.TotalSeconds ?? 0;

    public static double StartOffset(Prayer p) => p == Prayer.Fajr ? VoiceChoices.FajrStartOffset : 0;

    /// <summary>The file for a prayer. Fajr ignores the voice. Never falls back to another file.</summary>
    public string FileFor(Prayer prayer, Voice voice)
    {
        if (prayer == Prayer.Fajr) return Existing(Path.Combine(_root, "fajr", VoiceChoices.FajrStem + ".mp3"));
        if (!VoiceChoices.IsValid(voice)) throw new AthanException("unknown voice");
        return Existing(Path.Combine(_root, voice.Kind == VoiceKind.Sunni ? "sunni" : "shia", voice.Stem + ".mp3"));
    }

    static string Existing(string p) => File.Exists(p) ? p : throw new AthanException("missing file " + Path.GetFileName(p));

    public void Play(Prayer prayer, Voice voice, float volume)
    {
        Stop();
        var file = FileFor(prayer, voice);
        Mp3FileReader reader;
        try { reader = new Mp3FileReader(file); }
        catch (Exception) { throw new AthanException("cannot decode " + Path.GetFileName(file)); }
        double offset = StartOffset(prayer);
        if (offset > 0) reader.CurrentTime = TimeSpan.FromSeconds(Math.Min(offset, Math.Max(0, reader.TotalTime.TotalSeconds - 0.1)));
        var output = new WaveOutEvent { Volume = Math.Clamp(volume, 0f, 1f) };
        output.Init(reader);
        output.PlaybackStopped += (_, _) => _ui.BeginInvoke(() =>
        {
            if (_out != output) return;            // stopped by us, or an older player
            Release();
            OnFinished?.Invoke();
        });
        _pauser.PauseOthers();                     // the one place other media is paused
        _out = output;
        _reader = reader;
        output.Play();
    }

    /// <summary>Idempotent. Does not call OnFinished.</summary>
    public void Stop()
    {
        var o = _out;
        if (o == null) return;
        _out = null;
        try { o.Stop(); } catch (Exception) { /* already stopped */ }
        Release(o);
    }

    void Release(WaveOutEvent? o = null)
    {
        (o ?? _out)?.Dispose();
        if (o == null) _out = null;
        _reader?.Dispose();
        _reader = null;
    }

    public int RemainingMs()
    {
        if (!IsPlaying || _reader is not { } r) return 0;
        return Math.Max(0, (int)Math.Round((r.TotalTime - r.CurrentTime).TotalMilliseconds));
    }
}
