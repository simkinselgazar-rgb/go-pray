// BridgeMessageTests.cs — the pure part of GoPrayTests/Shield/BridgeMessageTests.swift (validation and
// payload), plus ShieldContextTests' gate and payload cases. The page parts live in GoPray.App.Tests.

using System;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

public class BridgeMessageTests
{
    static ShieldContext Ctx(int remainingMs = 600_000, int athanMs = 0, bool reduce = false, string? app = null, BlockMode mode = BlockMode.WholeScreen) =>
        new() { Prayer = Prayer.Dhuhr, Mode = mode, RemainingMs = remainingMs, AthanRemainingMs = athanMs, ReduceMotion = reduce, HiddenAppName = app };

    [Fact]
    public void parsesTheFourNames()
    {
        Assert.Equal(BridgeMessage.Ready, BridgeMessages.Parse("{\"type\":\"ready\"}"));
        Assert.Equal(BridgeMessage.Prayed, BridgeMessages.Parse("{\"type\":\"prayed\"}"));
        Assert.Equal(BridgeMessage.Silence, BridgeMessages.Parse("{\"type\":\"silence\"}"));
        Assert.Equal(BridgeMessage.Gone, BridgeMessages.Parse("{\"type\":\"gone\"}"));
    }

    [Theory]
    [InlineData("{\"type\":\"end\"}")]
    [InlineData("{\"type\":\"PRAYED\"}")]
    [InlineData("{\"type\":\"prayed\",\"force\":true}")]    // extra key
    [InlineData("{\"kind\":\"prayed\"}")]
    [InlineData("{\"type\":1}")]
    [InlineData("{\"type\":[\"prayed\"]}")]
    [InlineData("\"prayed\"")]
    [InlineData("\"{\\\"type\\\":\\\"prayed\\\"}\"")]        // a JSON string that contains the right JSON
    [InlineData("[\"prayed\"]")]
    [InlineData("42")]
    [InlineData("null")]
    [InlineData("{}")]
    [InlineData("")]
    [InlineData("{not json")]
    public void dropsEverythingElse(string json) => Assert.Null(BridgeMessages.Parse(json));

    [Fact]
    public void payloadCarriesReduceMotionAndClampsNumbers()
    {
        var p = BridgePayload.From(Ctx(remainingMs: 99_999_999, athanMs: -5, reduce: true), ShieldLayout.Full);
        Assert.True(p.ReduceMotion);
        Assert.Equal(1_800_000, p.RemainingMs);
        Assert.Equal(0, p.AthanRemainingMs);
        var script = p.ShowScript();
        Assert.StartsWith("GoPrayBridge.show({", script);
        Assert.Contains("\"reduceMotion\":true", script);
        Assert.Contains("\"layout\":\"full\"", script);
        Assert.Contains("\"prayer\":\"dhuhr\"", script);
    }

    [Fact]
    public void appNameIsEscapedByTheEncoderAndCapped()
    {
        var evil = "\"});alert(1);//</script>\n" + (char)0x2028 + new string('x', 200);
        var p = BridgePayload.From(Ctx(mode: BlockMode.CodingApps, app: evil), ShieldLayout.Notice);
        Assert.Equal(BridgePayload.MaxAppNameLength, p.HiddenAppName!.Length);
        var script = p.ShowScript();
        Assert.DoesNotContain("\n", script);                     // control characters are escaped
        Assert.DoesNotContain(((char)0x2028).ToString(), script);
        Assert.DoesNotContain("</script>", script);              // < is escaped
        Assert.Contains("\\u0022});alert(1)", script);           // the quote is escaped, it cannot close the string
    }

    [Fact]
    public void payloadCarriesTheLockLength()
    {
        Assert.Equal(600_000, BridgePayload.From(Ctx(300_000) with { LockSeconds = 600 }, ShieldLayout.Full).LockMs);
        Assert.Equal(1_800_000, BridgePayload.From(Ctx(300_000) with { LockSeconds = 99_999 }, ShieldLayout.Full).LockMs);
        Assert.Equal(0, BridgePayload.From(Ctx(), ShieldLayout.Full).LockMs);   // unknown
    }

    [Fact]
    public void gateFillsStartAndLockLengthAndKeepsThemAcrossARelaunch()
    {
        var asr = FakeSchedule.At(Prayer.Asr);
        using var h = new Harness(asr, TestSettings.Test(lockMinutes: 15));
        h.Gate.AthanFired(Prayer.Asr, asr);
        var first = h.Shield.Shows[0];
        Assert.Equal(900, first.LockSeconds);
        Assert.Equal(asr, first.BlockStartedAt);
        Assert.Equal(900_000, first.RemainingMs);
        h.Clock.Now = asr.AddSeconds(300);
        h.Relaunch();
        var again = h.Shield.Shows[0];
        Assert.Equal(900, again.LockSeconds);
        Assert.Equal(asr, again.BlockStartedAt);
        Assert.Equal(600_000, again.RemainingMs);
    }
}
