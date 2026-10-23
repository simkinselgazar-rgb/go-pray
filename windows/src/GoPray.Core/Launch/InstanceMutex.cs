// InstanceMutex.cs — the single-instance choke point: the named mutex Local\GoPray.Instance.
// The process holds it for its whole life; Windows releases it when the process exits or is killed
// (an abandoned mutex), so the next tick or hand launch takes over and resumes from state.json.

using System;
using System.IO;
using System.Threading;

namespace GoPray.Core;

public sealed class InstanceMutex : IDisposable
{
    Mutex? _mutex;

    /// <summary>true = we own it, false = another copy does, null = it could not be created.</summary>
    public bool? Owned { get; }

    public InstanceMutex(string name = LaunchDecision.MutexName)
    {
        try
        {
            _mutex = new Mutex(initiallyOwned: true, name, out bool createdNew);
            if (createdNew) { Owned = true; return; }
            // It exists. If its owner died without releasing it, WaitOne(0) throws Abandoned and we own it.
            try { Owned = _mutex.WaitOne(0); }
            catch (AbandonedMutexException) { Owned = true; }
            if (Owned != true) { _mutex.Dispose(); _mutex = null; }
        }
        catch (Exception e) when (e is UnauthorizedAccessException or WaitHandleCannotBeOpenedException or IOException)
        {
            _mutex = null;
            Owned = null;
        }
    }

    public void Dispose()
    {
        if (_mutex is null) return;
        try { if (Owned == true) _mutex.ReleaseMutex(); } catch (ApplicationException) { /* not owned on this thread */ }
        _mutex.Dispose();
        _mutex = null;
    }
}
