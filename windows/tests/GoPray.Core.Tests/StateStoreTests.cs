// StateStoreTests.cs — the state.json store on its own: strict decoding (the Mac's rules), atomic
// write, quarantine. The gate-level corrupt/future cases live in BlockGateTests (E.7).

using System;
using System.IO;
using System.Linq;
using GoPray.Core;
using Xunit;

namespace GoPray.Core.Tests;

public sealed class StateStoreTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "gopray-store-" + Guid.NewGuid().ToString("N"));
    public void Dispose() { try { Directory.Delete(dir, true); } catch { } }

    StateStore Store() => new(dir);
    void Write(string json) { Directory.CreateDirectory(dir); File.WriteAllText(Path.Combine(dir, "state.json"), json); }

    [Fact]
    public void missingFileIsMissing() => Assert.IsType<StateStore.LoadResult.Missing>(Store().Load());

    [Theory]
    [InlineData("{\"block\": null, \"launches\": []}")]                                   // no schemaVersion
    [InlineData("{\"schemaVersion\": \"1\", \"block\": null}")]                            // version is a string
    [InlineData("{\"schemaVersion\": 1, \"block\": {\"prayer\": \"asr\"}}")]               // block missing fields
    [InlineData("{\"schemaVersion\": 1, \"block\": {\"prayer\": \"asr\", \"athanAt\": \"yesterday\", \"blockStartedAt\": \"2026-10-22T15:30:00Z\", \"silenced\": false, \"athanPlayed\": true}}")]
    [InlineData("{\"schemaVersion\": 1, \"block\": {\"prayer\": \"asr\", \"athanAt\": \"2026-10-22T15:30:00Z\", \"blockStartedAt\": \"2026-10-22T15:30:00Z\", \"silenced\": 0, \"athanPlayed\": true}}")]
    [InlineData("{\"schemaVersion\": 1, \"block\": null, \"lastConfirmed\": {\"prayer\": \"sunrise\", \"athanAt\": \"2026-10-22T06:30:00Z\"}}")]
    [InlineData("[]")]
    [InlineData("")]
    public void strictDecodingQuarantines(string json)
    {
        Write(json);
        var r = Store().Load();
        var c = Assert.IsType<StateStore.LoadResult.Corrupt>(r);
        Assert.NotNull(c.MovedTo);
        Assert.False(File.Exists(Path.Combine(dir, "state.json")));
        Assert.Single(Directory.GetFiles(dir, "state.corrupt-*.json"));
    }

    [Fact]
    public void unknownKeysAreIgnoredLikeSwift()
    {
        Write("{\"schemaVersion\": 1, \"block\": null, \"launches\": [], \"futureField\": 42}");
        Assert.IsType<StateStore.LoadResult.Loaded>(Store().Load());
    }

    [Fact]
    public void datesWithOffsetsOrNoFractionDecode()
    {
        Write("{\"schemaVersion\": 1, \"block\": null, \"lastConfirmed\": {\"prayer\": \"asr\", \"athanAt\": \"2026-10-22T11:30:00-04:00\"}}");
        var s = Assert.IsType<StateStore.LoadResult.Loaded>(Store().Load()).State;
        Assert.Equal(new DateTime(2026, 10, 22, 15, 30, 0, DateTimeKind.Utc), s.LastConfirmed?.AthanAt);
    }

    [Fact]
    public void saveReplacesAtomicallyAndLeavesNoTemp()
    {
        var store = Store();
        for (int i = 0; i < 20; i++)
            store.Save(new BlockStateFile { Launches = Enumerable.Range(0, i % 5).Select(n => FakeSchedule.Day0.AddSeconds(n)).ToList() });
        Assert.Equal(["state.json"], Directory.GetFiles(dir).Select(f => Path.GetFileName(f)).ToArray());
        Assert.IsType<StateStore.LoadResult.Loaded>(store.Load());
    }

    [Fact]
    public void peekNeverQuarantines()
    {
        Write("not json");
        Assert.False(Store().PeekHasOpenBlock());
        Assert.True(File.Exists(Path.Combine(dir, "state.json")));
        Assert.Empty(Directory.GetFiles(dir, "state.corrupt-*"));
    }

    [Fact]
    public void peekSeesAnOpenBlock()
    {
        var asr = FakeSchedule.At(Prayer.Asr);
        Store().Save(new BlockStateFile { CurrentBlock = new BlockStateFile.Block { Prayer = Prayer.Asr, AthanAt = asr, BlockStartedAt = asr, AthanPlayed = true } });
        Assert.True(Store().PeekHasOpenBlock());
        Store().Save(new BlockStateFile());
        Assert.False(Store().PeekHasOpenBlock());
    }

    [Fact]
    public void twoQuarantinesInOneSecondGetDistinctNames()
    {
        Write("bad"); Store().Load();
        Write("bad"); Store().Load();
        Assert.Equal(2, Directory.GetFiles(dir, "state.corrupt-*.json").Length);
    }
}
