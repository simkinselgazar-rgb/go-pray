// CastVideo.swift — the Athan video for Google TV (Google TV Plan §5, lane B). The ONE file that writes video.
//
// A `CastMediaSource`: for one (prayer, voice) it renders the prayer's painting (1920x1080, a small label
// "Athan · <voice>" baked in, 1 fps) plus the voice's Athan (AAC) plus a 30 s silent tail, as an H.264 + AAC mp4
// with the moov atom first (the shape that played on the real TV). Rendered once, cached in
// Caches/tv-cast/v1/, and reused. No network, no AI. Fajr ignores the voice and starts 9.0 s in, like the Mac.
// The label carries no prayer time, so a cached file never goes stale.

import AVFoundation
import CoreText
import Foundation

enum CastVideoError: Error, Equatable {
    case missingStill, unreadableAudio, renderFailed
}

final class CastVideo: CastMediaSource, @unchecked Sendable {
    static let tailSeconds = 30.0
    static let cacheLimitBytes = 25 * 1_000_000
    private static let width = 1920, height = 1080
    private static let sampleRate = 11025.0

    private let bundle: Bundle
    private let directory: URL
    private let renders = RenderQueue()

    /// `directory` is for tests; production uses Caches/tv-cast/v1.
    init(bundle: Bundle = .main, directory: URL? = nil) {
        self.bundle = bundle
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tv-cast", isDirectory: true).appendingPathComponent("v1", isDirectory: true)
    }

    // MARK: - Contract

    func prepare(prayer: Prayer, voice: Voice) async throws -> URL {
        let entry = try Self.audioEntry(prayer: prayer, voice: voice, bundle: bundle)
        let file = directory.appendingPathComponent(Self.fileName(prayer: prayer, voice: voice))
        return try await renders.run(key: file.lastPathComponent) { [self] in
            if await isUsable(file) { return file }
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let tmp = directory.appendingPathComponent(".\(UUID().uuidString).tmp.mp4")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await render(prayer: prayer, entry: entry, to: tmp)
            guard await isUsable(tmp) else { throw CastVideoError.renderFailed }
            _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
            return file
        }
    }

    /// Render all five for `voice` ahead of time (called when a Google TV is added or the voice changes), then tidy.
    func warm(voice: Voice) async {
        for prayer in Prayer.allCases { _ = try? await prepare(prayer: prayer, voice: voice) }
        cleanup(keeping: voice)
    }

    /// Drop other voices' files, half-written temp files, and the oldest files beyond 25 MB.
    func cleanup(keeping voice: Voice) {
        let fm = FileManager.default
        let keep = Set(Prayer.allCases.map { Self.fileName(prayer: $0, voice: voice) })
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                      options: []) else { return }
        var live: [(url: URL, size: Int, date: Date)] = []
        for f in files {
            let name = f.lastPathComponent
            if !keep.contains(name) { try? fm.removeItem(at: f); continue }
            let v = try? f.resourceValues(forKeys: Set(keys))
            live.append((f, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast))
        }
        var total = live.reduce(0) { $0 + $1.size }
        for f in live.sorted(by: { $0.date < $1.date }) where total > Self.cacheLimitBytes {
            try? fm.removeItem(at: f.url); total -= f.size
        }
    }

    // MARK: - Names

    static func fileName(prayer: Prayer, voice: Voice) -> String {
        if prayer == .fajr { return "fajr.mp4" }
        switch voice {
        case .sunni(let s): return "\(prayer.rawValue)-sunni.\(s).mp4"
        case .shia(let s): return "\(prayer.rawValue)-shia.\(s).mp4"
        }
    }

    private struct AudioEntry { let url: URL; let label: String; let offset: Double }

    /// Validates the voice against the catalogue (so a file name can only be an enum-named one).
    private static func audioEntry(prayer: Prayer, voice: Voice, bundle: Bundle) throws -> AudioEntry {
        if prayer != .fajr, VoiceCatalog.entry(for: voice) == nil { throw AthanError.unknownVoice }
        let label = prayer == .fajr ? "Athan  \u{00B7}  Sheikh Hamed"
            : "Athan  \u{00B7}  \(VoiceCatalog.entry(for: voice)?.displayName ?? "")"
        let url = try VoiceCatalog.url(prayer: prayer, voice: voice, bundle: bundle)
        return AudioEntry(url: url, label: label, offset: prayer == .fajr ? VoiceCatalog.fajrStartOffset : 0)
    }

    // MARK: - Cache validity

    /// A cached file is reused only if it opens, has a video and an audio track, and runs longer than the tail.
    private func isUsable(_ file: URL) async -> Bool {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else { return false }
        let asset = AVURLAsset(url: file)
        guard let playable = try? await asset.load(.isPlayable), playable,
              let duration = try? await asset.load(.duration),
              duration.seconds > Self.tailSeconds + 1,
              let video = try? await asset.loadTracks(withMediaType: .video), !video.isEmpty,
              let audio = try? await asset.loadTracks(withMediaType: .audio), !audio.isEmpty
        else { return false }
        return true
    }

    // MARK: - Render

    private func render(prayer: Prayer, entry: AudioEntry, to out: URL) async throws {
        guard let stillURL = bundle.url(forResource: "still-\(prayer.rawValue)", withExtension: "jpg",
                                        subdirectory: "tv-stills") else { throw CastVideoError.missingStill }
        let frame = try Self.paintedFrame(still: stillURL, label: entry.label, prayer: prayer)

        let asset = AVURLAsset(url: entry.url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CastVideoError.unreadableAudio
        }
        let audioLength = try await asset.load(.duration).seconds - entry.offset
        guard audioLength > 1 else { throw CastVideoError.unreadableAudio }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: entry.offset, preferredTimescale: 600),
                                       duration: .positiveInfinity)
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOut = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        reader.add(readerOut)
        guard reader.startReading() else { throw CastVideoError.unreadableAudio }

        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true   // moov before mdat
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Self.width, AVVideoHeightKey: Self.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000, AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoExpectedSourceFrameRateKey: 1, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.width, kCVPixelBufferHeightKey as String: Self.height,
        ])
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ])
        videoIn.expectsMediaDataInRealTime = false
        audioIn.expectsMediaDataInRealTime = false
        writer.add(videoIn); writer.add(audioIn)
        guard writer.startWriting() else { throw writer.error ?? CastVideoError.renderFailed }
        writer.startSession(atSourceTime: .zero)

        let expectedEnd = audioLength + Self.tailSeconds
        var nextFrame = 0
        let lastFrame = Int(expectedEnd.rounded(.down))
        var audioDone = false
        var silenceOffset = 0                       // samples of silence written so far
        var audioEnd = CMTime.zero                  // where the voice ended
        var reading = true
        let silenceTotal = Int(Self.tailSeconds * Self.sampleRate)
        let chunk = Int(Self.sampleRate)            // one second of silence per buffer
        let format = try Self.pcmFormat()

        while !(nextFrame > lastFrame && audioDone) {
            if writer.status == .failed { throw writer.error ?? CastVideoError.renderFailed }
            var progressed = false
            while nextFrame <= lastFrame, videoIn.isReadyForMoreMediaData {
                guard adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(nextFrame), timescale: 1))
                else { throw writer.error ?? CastVideoError.renderFailed }
                nextFrame += 1; progressed = true
            }
            while !audioDone, audioIn.isReadyForMoreMediaData {
                if reading {
                    if let buf = readerOut.copyNextSampleBuffer() {
                        let shifted = try Self.shifted(buf, by: entry.offset)
                        audioEnd = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(shifted),
                                             CMSampleBufferGetDuration(shifted))
                        guard audioIn.append(shifted) else { throw writer.error ?? CastVideoError.renderFailed }
                    } else {
                        if reader.status == .failed { throw reader.error ?? CastVideoError.unreadableAudio }
                        reading = false
                    }
                } else if silenceOffset < silenceTotal {
                    let n = min(chunk, silenceTotal - silenceOffset)
                    let start = CMTimeAdd(audioEnd, CMTime(value: CMTimeValue(silenceOffset),
                                                           timescale: CMTimeScale(Self.sampleRate)))
                    guard audioIn.append(try Self.silence(samples: n, at: start, format: format))
                    else { throw writer.error ?? CastVideoError.renderFailed }
                    silenceOffset += n
                } else {
                    audioDone = true
                }
                progressed = true
            }
            if !progressed { try await Task.sleep(for: .milliseconds(4)) }
        }
        videoIn.markAsFinished(); audioIn.markAsFinished()
        writer.endSession(atSourceTime: CMTimeAdd(audioEnd, CMTime(seconds: Self.tailSeconds, preferredTimescale: 600)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CastVideoError.renderFailed }
    }

    // MARK: - Audio buffers

    private static func pcmFormat() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var fd: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &fd) == noErr,
              let fd else { throw CastVideoError.renderFailed }
        return fd
    }

    private static func silence(samples: Int, at pts: CMTime, format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        let bytes = samples * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                         dataLength: bytes) == noErr
        else { throw CastVideoError.renderFailed }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb) == noErr, let sb
        else { throw CastVideoError.renderFailed }
        return sb
    }

    /// The same samples, moved earlier by `seconds` (so a Fajr file read from 9 s in starts at 0).
    private static func shifted(_ buf: CMSampleBuffer, by seconds: Double) throws -> CMSampleBuffer {
        var info = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(buf, at: 0, timingInfoOut: &info) == noErr else {
            throw CastVideoError.renderFailed
        }
        info.presentationTimeStamp = CMTimeSubtract(info.presentationTimeStamp, CMTime(seconds: seconds, preferredTimescale: 600))
        info.decodeTimeStamp = .invalid
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buf, sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &info, sampleBufferOut: &out) == noErr,
              let out else { throw CastVideoError.renderFailed }
        return out
    }

    // MARK: - The painting + label

    /// Roku's label colours (tv/roku/components/AthanScene.brs `Palette`), so both TVs read the same.
    private static func labelColor(_ prayer: Prayer) -> CGColor {
        let hex: UInt32
        switch prayer {
        case .fajr: hex = 0xF2E4CC
        case .isha: hex = 0xEDE9E1
        case .dhuhr: hex = 0x34444B
        case .asr: hex = 0x5C4835
        case .maghrib: hex = 0x4B3719
        }
        return CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                       blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    private static func paintedFrame(still: URL, label: String, prayer: Prayer) throws -> CVPixelBuffer {
        guard let src = CGImageSourceCreateWithURL(still as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CastVideoError.missingStill }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        guard let pb else { throw CastVideoError.renderFailed }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw CastVideoError.renderFailed }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Roku: a 770-wide label at (18, 640) of 1280x720, centred. Scaled 1.5x to 1080p; bottom-left origin here.
        let font = CTFontCreateUIFontForLanguage(.system, 42, nil)!
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): labelColor(prayer),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs))
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (18 + 770 / 2) * 1.5 - textWidth / 2, y: CGFloat(height) - 998)
        CTLineDraw(line, ctx)
        return pb
    }
}

/// One render per file at a time: a second `prepare` for the same file waits for the first, then finds it cached.
private actor RenderQueue {
    private var inFlight: [String: Task<URL, Error>] = [:]

    func run(key: String, _ work: @escaping @Sendable () async throws -> URL) async throws -> URL {
        if let running = inFlight[key] { return try await running.value }
        let task = Task { try await work() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}
