// Clock.cs — the wall clock behind every timer rule. Port of Core/Clock.swift.

using System;
using System.Threading;

namespace GoPray.Core;

public sealed class SystemClock : IClock
{
    public DateTime Now => DateTime.UtcNow;
}

/// <summary>Settable clock for tests and the debug menu. Thread-safe.</summary>
public sealed class FakeClock(DateTime start) : IClock
{
    readonly Lock _lock = new();
    DateTime _current = start;

    public DateTime Now
    {
        get { lock (_lock) return _current; }
        set { lock (_lock) _current = value; }
    }

    public void Advance(double seconds)
    {
        lock (_lock) _current = _current.AddSeconds(seconds);
    }
}
