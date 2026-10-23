using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using NAudio.Wave;
using NLayer.NAudioSupport;

namespace GoPraySpike;

// Q5: decode every athan MP3 end to end (no sound) with Mp3FileReader (ACM), MediaFoundationReader and
// NLayer; Fajr seek to 9.0 s; then two short quiet plays (<= 2.5 s each, volume 0.08).
static class AudioMode
{
    public static void Run(string[] a)
    {
        Log.Open("q5-audio");
        var dir = Program.StrArg(a, "--athan", "");
        var files = Directory.GetFiles(dir, "*.mp3", SearchOption.AllDirectories).OrderBy(f => f).ToArray();
        Log.W($"files={files.Length}");
        int ok1 = 0, ok2 = 0, ok3 = 0;
        foreach (var f in files)
        {
            var rel = Path.GetRelativePath(dir, f);
            string fmt = "";
            try { using var r = new Mp3FileReader(f); var m = r.Mp3WaveFormat; fmt = $"{m.SampleRate} Hz {m.Channels} ch {r.TotalTime.TotalSeconds:0.0} s"; } catch { }
            string a1 = Decode(() => new Mp3FileReader(f), ref ok1);
            string a2 = Decode(() => new MediaFoundationReader(f), ref ok2);
            string a3 = Decode(() => new Mp3FileReaderBase(f, wf => new Mp3FrameDecompressor(wf)), ref ok3);
            Log.W($"{rel,-55} [{fmt}]  ACM:{a1}  MF:{a2}  NLayer:{a3}");
        }
        Log.W($"DECODE OK  Mp3FileReader(ACM)={ok1}/{files.Length}  MediaFoundation={ok2}/{files.Length}  NLayer={ok3}/{files.Length}");

        var fajr = files.First(f => f.Contains("fajr"));
        using (var r = new Mp3FileReader(fajr))
        {
            r.CurrentTime = TimeSpan.FromSeconds(9.0);
            Log.W($"fajr seek 9.0 -> CurrentTime={r.CurrentTime.TotalSeconds:0.0000} s pos={r.Position} bytes/s={r.WaveFormat.AverageBytesPerSecond}");
            var buf = new byte[r.WaveFormat.AverageBytesPerSecond / 10];
            int n = r.Read(buf, 0, buf.Length);
            Log.W($"fajr after first read CurrentTime={r.CurrentTime.TotalSeconds:0.0000} s (read {n} bytes)");
        }
        if (!a.Contains("--noplay"))
        {
            Play(fajr, 9.0, "fajr from 9.0 s");
            var low = files.First(f => { using var r = new Mp3FileReader(f); return r.Mp3WaveFormat.SampleRate < 16000; });
            Play(low, 0, "lowest-rate file");
        }
        Log.W("audio done");
    }

    static string Decode(Func<WaveStream> mk, ref int ok)
    {
        var sw = Stopwatch.StartNew();
        try
        {
            using var r = mk();
            var buf = new byte[65536]; long total = 0; int n;
            while ((n = r.Read(buf, 0, buf.Length)) > 0) total += n;
            double secs = (double)total / r.WaveFormat.AverageBytesPerSecond;
            ok++;
            return $"ok {secs:0.0}s/{sw.ElapsedMilliseconds}ms";
        }
        catch (Exception e) { return "FAIL " + e.GetType().Name + ": " + e.Message.Split('\n')[0]; }
    }

    static void Play(string f, double from, string what)
    {
        using var r = new Mp3FileReader(f);
        r.CurrentTime = TimeSpan.FromSeconds(from);
        using var o = new WaveOutEvent();
        o.Init(r);
        o.Volume = 0.08f;
        var sw = Stopwatch.StartNew();
        o.Play();
        Thread.Sleep(2500);
        var pos = r.CurrentTime.TotalSeconds;
        o.Stop();
        Log.W($"played {what} ({Path.GetFileName(f)}) for {sw.ElapsedMilliseconds} ms at vol 0.08, state ok, stream pos {pos:0.00} s");
    }
}
