// MediaPauser.swift — pauses whatever macOS says is Now Playing, right before the Athan sounds. Owner: lane C.
// Private MediaRemote framework, loaded by hand (dlopen/dlsym) once. Method 1a of spike-media/ANSWERS.md:
// the send call works from our own process with no prompt and no entitlement; the read calls are blocked.
// Fire-and-forget: never throws, never resumes, never sends anything but pause (command 1).
// guard.sh rule 11 pins the private API to this file. Not App Store safe (see README).

import Foundation
import os

private let mediaLog = Logger(subsystem: "com.ahmedelgazar.gopray", category: "audio")

@MainActor protocol MediaPausing: AnyObject {
    func pauseOthers()
}

@MainActor final class MediaRemotePauser: MediaPausing {
    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    /// kMRPause. The ONLY command this file may send.
    private static let pauseCommand: UInt32 = 1
    private static let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    /// dlopen + dlsym once, lazily. nil = this macOS no longer has it, so every call is a no-op.
    private static let send: SendCommand? = {
        guard let handle = dlopen(path, RTLD_NOW), let sym = dlsym(handle, "MRMediaRemoteSendCommand") else {
            mediaLog.notice("media pause unavailable")
            return nil
        }
        return unsafeBitCast(sym, to: SendCommand.self)
    }()

    /// True when the symbol loaded on this macOS. Loads only; sends nothing.
    static var isAvailable: Bool { send != nil }

    func pauseOthers() {
        guard let send = Self.send else { return }
        _ = send(Self.pauseCommand, nil)
    }
}
