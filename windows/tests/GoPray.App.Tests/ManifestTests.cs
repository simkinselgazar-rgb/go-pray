// ManifestTests.cs — the scene manifest catches drift, and the shipped page keeps its lockdown.
// Port of GoPrayTests/Shield/ManifestTests.swift, running windows\scripts\check-manifest.ps1.

using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using GoPray.App.Shield;
using Xunit;

namespace GoPray.App.Tests;

public class ManifestTests
{
    static string Scripts => Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "scripts"));

    static (int Code, string Out) Run(string script, string args)
    {
        var psi = new ProcessStartInfo("powershell", $"-NoProfile -ExecutionPolicy Bypass -File \"{Path.Combine(Scripts, script)}\" {args}")
        { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        using var p = Process.Start(psi)!;
        string o = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
        p.WaitForExit();
        return (p.ExitCode, o);
    }

    static string CopyOfScenes()
    {
        var dst = Path.Combine(Path.GetTempPath(), "gopray-manifest-" + Guid.NewGuid().ToString("N"));
        foreach (var f in Directory.GetFiles(SceneWebView.BundledScenesRoot, "*", SearchOption.AllDirectories))
        {
            var to = Path.Combine(dst, Path.GetRelativePath(SceneWebView.BundledScenesRoot, f));
            Directory.CreateDirectory(Path.GetDirectoryName(to)!);
            File.Copy(f, to);
        }
        return dst;
    }

    [Fact]
    public void shippedScenesMatchTheirManifest()
    {
        var r = Run("check-manifest.ps1", $"-Dir \"{SceneWebView.BundledScenesRoot}\"");
        Assert.True(r.Code == 0, r.Out);
    }

    [Fact]
    public void oneChangedByteInUIJsFailsTheCheck()
    {
        var dir = CopyOfScenes();
        try
        {
            Assert.Equal(0, Run("check-manifest.ps1", $"-Dir \"{dir}\"").Code);   // control: the copy is clean
            var ui = Path.Combine(dir, "ui.js");
            var data = File.ReadAllBytes(ui);
            data[data.Length / 2] ^= 0x01;                                          // flip one bit
            File.WriteAllBytes(ui, data);
            var r = Run("check-manifest.ps1", $"-Dir \"{dir}\"");
            Assert.NotEqual(0, r.Code);
            Assert.Contains("ui.js differs", r.Out);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void crlfLineEndingsFailTheCheck()
    {
        // What Git for Windows' autocrlf does to a checkout: the reason sync-assets reads git blobs.
        var dir = CopyOfScenes();
        try
        {
            var css = Path.Combine(dir, "styles.css");
            File.WriteAllText(css, File.ReadAllText(css).Replace("\r\n", "\n").Replace("\n", "\r\n"));
            var r = Run("check-manifest.ps1", $"-Dir \"{dir}\"");
            Assert.NotEqual(0, r.Code);
            Assert.Contains("styles.css differs", r.Out);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void aMissingOrExtraFileFailsTheCheck()
    {
        var dir = CopyOfScenes();
        try
        {
            File.WriteAllText(Path.Combine(dir, "extra.js"), "x");
            var extra = Run("check-manifest.ps1", $"-Dir \"{dir}\"");
            Assert.True(extra.Code != 0 && extra.Out.Contains("extra.js"), extra.Out);
            File.Delete(Path.Combine(dir, "extra.js"));
            File.Delete(Path.Combine(dir, "fonts", "Amiri-Regular.woff"));
            var missing = Run("check-manifest.ps1", $"-Dir \"{dir}\"");
            Assert.True(missing.Code != 0 && missing.Out.Contains("missing fonts/Amiri-Regular.woff"), missing.Out);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void aTamperedShieldHtmlFailsTheCheck()
    {
        var dir = CopyOfScenes();
        try
        {
            var html = Path.Combine(dir, "shield.html");
            File.WriteAllText(html, File.ReadAllText(html).Replace("connect-src 'none'", "connect-src *"));
            var r = Run("check-manifest.ps1", $"-Dir \"{dir}\"");
            Assert.True(r.Code != 0 && r.Out.Contains("shield.html differs"), r.Out);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void shippedFilesAreByteIdenticalToTheMacTreeInGit()
    {
        // sync-assets copied git HEAD's blobs; the shipped bytes hash to the Mac manifest (checked above) and
        // the text files carry LF only.
        foreach (var f in new[] { "ui.js", "bridge.js", "shield.html", "styles.css" })
            Assert.DoesNotContain((byte)'\r', File.ReadAllBytes(Path.Combine(SceneWebView.BundledScenesRoot, f)));
    }

    [Fact]
    public void shieldHtmlCarriesTheLockdownAndNoKeyHandlers()
    {
        var root = SceneWebView.BundledScenesRoot;
        var html = File.ReadAllText(Path.Combine(root, "shield.html"));
        foreach (var d in new[] { "default-src 'none'", "script-src 'self'", "connect-src 'none'", "object-src 'none'", "base-uri 'none'", "form-action 'none'", "font-src 'self'", "img-src 'self' data:" })
            Assert.Contains(d, html);
        Assert.DoesNotContain("<script>", html);
        var bridge = File.ReadAllText(Path.Combine(root, "bridge.js"));
        Assert.True(!bridge.Contains("keydown") && !bridge.Contains("keyup") && !bridge.Contains("keypress") && !bridge.Contains("innerHTML"));
    }
}
