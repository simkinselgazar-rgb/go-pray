// MediaPauser.cs — pauses every other app's media right before the Athan sounds (PLAN.md §3 row 3).
// The public Windows.Media.Control API; spike Q2: works unpackaged, no prompt. The only file that may
// touch GlobalSystemMediaTransportControls, and it may only PAUSE (guard rule 8: one TryPauseAsync, no
// play/toggle/skip). Called from exactly one place, AthanPlayer.Play. Never resumes. Fire-and-forget
// with a 2 s budget; any failure is logged once and the Athan plays anyway. Calls (Teams/Zoom) are not
// media sessions, so they are untouched.

using System;
using System.Linq;
using System.Threading.Tasks;
using GoPray.Core;
using Windows.Media.Control;

namespace GoPray.App.Audio;

internal interface IMediaPausing
{
    void PauseOthers();
}

internal sealed class MediaPauser : IMediaPausing
{
    public void PauseOthers() => _ = Run();

    static async Task Run()
    {
        try
        {
            var work = PauseAll();
            if (await Task.WhenAny(work, Task.Delay(2000)) != work) CoreLog.Notice("media pause: still waiting after 2 s, moving on");
        }
        catch (Exception e) { CoreLog.Error("media pause failed: " + e.Message); }
    }

    static async Task PauseAll()
    {
        var mgr = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
        var playing = mgr.GetSessions()
            .Where(s => s.GetPlaybackInfo().PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing).ToList();
        // In parallel: each pause takes ~0.5 s (spike Q2).
        await Task.WhenAll(playing.Select(s => s.TryPauseAsync().AsTask()));
        if (playing.Count > 0) CoreLog.Notice($"media pause: asked {playing.Count} session(s) to pause");
    }
}
