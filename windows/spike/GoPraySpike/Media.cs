using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Windows.Media;
using Windows.Media.Control;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace GoPraySpike;

// Q2. "media-target": a silent, looping SMTC session we own (title GOPRAY-SPIKE-TARGET), max 45 s.
// "media-pause": the GSMTC loop from an unpackaged exe. SAFETY: it lists every session but only
// pauses sessions whose title contains GOPRAY-SPIKE, so Ahmed's own Spotify/Edge are never touched.
static class MediaMode
{
    public const string Marker = "GOPRAY-SPIKE";

    public static string SilentWav()
    {
        var p = Path.Combine(Path.GetTempPath(), "GOPRAY-SPIKE-silence.wav");
        if (File.Exists(p)) return p;
        int rate = 8000, secs = 60;
        using var bw = new BinaryWriter(File.Create(p));
        int data = rate * secs * 2;
        bw.Write("RIFF"u8); bw.Write(36 + data); bw.Write("WAVE"u8); bw.Write("fmt "u8); bw.Write(16);
        bw.Write((short)1); bw.Write((short)1); bw.Write(rate); bw.Write(rate * 2); bw.Write((short)2); bw.Write((short)16);
        bw.Write("data"u8); bw.Write(data); bw.Write(new byte[data]);
        return p;
    }

    public static void Target(string[] a)
    {
        Log.Open("q2-media-target");
        // MTA thread: on the STA main thread a sleeping thread never sees the SMTC pause command.
        Task.Run(() => TargetBody(a)).GetAwaiter().GetResult();
    }

    static void TargetBody(string[] a)
    {
        var player = new MediaPlayer { IsLoopingEnabled = true, Volume = 0 };
        player.Source = MediaSource.CreateFromUri(new Uri(SilentWav()));
        var smtc = player.SystemMediaTransportControls;
        player.CommandManager.IsEnabled = true;
        var u = smtc.DisplayUpdater;
        u.Type = MediaPlaybackType.Music;
        u.MusicProperties.Title = Marker + "-TARGET";
        u.MusicProperties.Artist = "Go Pray spike (silent)";
        u.Update();
        player.CurrentStateChanged += (s, _) => Log.W($"target state -> {s.CurrentState}");
        player.Play();
        Log.W("target playing (silent, volume 0)");
        for (int i = 0; i < Program.IntArg(a, "--seconds", 45); i++) { Thread.Sleep(1000); if (i % 3 == 0) Log.W($"target poll state={player.CurrentState} smtcStatus={smtc.PlaybackStatus}"); }
        Log.W("target exit");
    }

    public static void Pause(string[] a)
    {
        Log.Open(Program.StrArg(a, "--log", "q2-media-pause"));
        Task.Run(async () =>
        {
            var fgBefore = N.Describe(N.GetForegroundWindow());
            var t0 = Log.T;
            var mgr = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            Log.W($"RequestAsync returned in {Log.T - t0:0} ms, mgr={(mgr != null)} fg before={fgBefore} after={N.Describe(N.GetForegroundWindow())}");
            var sessions = mgr!.GetSessions();
            Log.W($"sessions={sessions.Count}");
            foreach (var s in sessions)
            {
                var info = s.GetPlaybackInfo();
                string title = "";
                try { title = (await s.TryGetMediaPropertiesAsync()).Title ?? ""; } catch { }
                bool mine = title.Contains(Marker) || s.SourceAppUserModelId == "GoPraySpike.exe";
                Log.W($"  session app={s.SourceAppUserModelId} status={info.PlaybackStatus} canPause={info.Controls.IsPauseEnabled} {(mine ? "title=" + title + " (OURS)" : "(not ours: title not logged, not touched)")}");
                if (!mine || info.PlaybackStatus != GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing) continue;
                var t1 = Log.T;
                var pause = s.TryPauseAsync().AsTask();
                var done = await Task.WhenAny(pause, Task.Delay(2000));
                bool res = done == pause && pause.Result;
                await Task.Delay(500);
                Log.W($"  TryPauseAsync -> {res} in {Log.T - t1:0} ms; status now={s.GetPlaybackInfo().PlaybackStatus}");
            }
            Log.W($"fg at end={N.Describe(N.GetForegroundWindow())}");
        }).GetAwaiter().GetResult();
        Log.W("pause done");
    }
}


