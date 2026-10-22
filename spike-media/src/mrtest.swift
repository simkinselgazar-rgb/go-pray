import Foundation
// Method 1: private MediaRemote via dlopen, called directly from our own process.
typealias SendCmd = @convention(c) (UInt32, CFDictionary?) -> Bool
typealias GetPlaying = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
typealias GetInfo = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void
guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else { print("dlopen failed"); exit(1) }
let send = unsafeBitCast(dlsym(h, "MRMediaRemoteSendCommand"), to: SendCmd.self)
let getPlaying = unsafeBitCast(dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying"), to: GetPlaying.self)
let getInfo = unsafeBitCast(dlsym(h, "MRMediaRemoteGetNowPlayingInfo"), to: GetInfo.self)
func query(_ label: String) {
    let s = DispatchSemaphore(value: 0)
    getPlaying(.main) { p in print("\(label): isPlaying=\(p)"); s.signal() }
    getInfo(.main) { d in print("\(label): info=\((d as? [String: Any])?.keys.sorted().prefix(3) ?? [])  title=\((d as? [String: Any])?["kMRMediaRemoteNowPlayingInfoTitle"] ?? "nil")"); s.signal() }
    for _ in 0..<2 { _ = s.wait(timeout: .now() + 2); }
}
DispatchQueue.global().async {
    // Pump main queue by running the loop; do the work on a background queue.
    query("before")
    let ok = send(1, nil)   // kMRPause = 1
    print("send(kMRPause) returned \(ok)")
    Thread.sleep(forTimeInterval: 1)
    query("after")
    exit(0)
}
RunLoop.main.run()
