import AppKit
import AVFoundation
import MediaPlayer

// Test-only "media app": plays a quiet tone and registers as Now Playing.
// Logs every remote command it receives to fakeplayer.log.
let logPath = CommandLine.arguments[1]
func log(_ s: String) {
    let line = "\(Date().timeIntervalSince1970) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(toFile: logPath, atomically: true, encoding: .utf8) }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let url = URL(fileURLWithPath: CommandLine.arguments[2])
let player = try! AVAudioPlayer(contentsOf: url)
player.numberOfLoops = -1
player.volume = 0.5
player.play()
let info = MPNowPlayingInfoCenter.default()
info.nowPlayingInfo = [MPMediaItemPropertyTitle: "SpikeTone", MPMediaItemPropertyPlaybackDuration: 18.0, MPNowPlayingInfoPropertyPlaybackRate: 1.0]
info.playbackState = .playing
let rc = MPRemoteCommandCenter.shared()
rc.pauseCommand.isEnabled = true; rc.playCommand.isEnabled = true; rc.togglePlayPauseCommand.isEnabled = true
rc.pauseCommand.addTarget { _ in player.pause(); info.playbackState = .paused; log("PAUSE cmd"); return .success }
rc.playCommand.addTarget { _ in player.play(); info.playbackState = .playing; log("PLAY cmd"); return .success }
rc.togglePlayPauseCommand.addTarget { _ in
    if player.isPlaying { player.pause(); info.playbackState = .paused } else { player.play(); info.playbackState = .playing }
    log("TOGGLE cmd -> playing=\(player.isPlaying)"); return .success }
log("started playing=\(player.isPlaying)")
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    try? "\(player.isPlaying)".write(toFile: logPath + ".state", atomically: true, encoding: .utf8)
}
Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in exit(0) }
app.run()
