// SceneStillTests.swift — lane B: the popover/setup still is painted once, cached, and not blank.

import Testing
import AppKit
@testable import GoPray

@MainActor @Suite("Scene still", .serialized)
struct SceneStillTests {
    /// Share of pixels that differ clearly from the ground colour.
    private func paintedShare(_ img: NSImage, ground: NSColor) -> Double {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        let g = ground.usingColorSpace(.sRGB)!
        var differing = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                let d = abs(c.redComponent - g.redComponent) + abs(c.greenComponent - g.greenComponent) + abs(c.blueComponent - g.blueComponent)
                if d > 0.12 { differing += 1 }
            }
        }
        return total == 0 ? 0 : Double(differing) / Double(total)
    }

    @Test(arguments: [Prayer.fajr, .isha])
    func paintsOnceThenServesFromTheCache(prayer: Prayer) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gopray-stills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = SceneStillRenderer(cacheDirectory: dir)
        let size = CGSize(width: 320, height: 96)
        let url = r.cacheURL(prayer, size: size, scale: 2)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let t0 = ContinuousClock.now
        let img = try #require(await r.image(for: prayer, size: size, scale: 2))
        let first = (ContinuousClock.now - t0) / .milliseconds(1)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let share = paintedShare(img, ground: ShieldPalette.of(prayer).ground)
        print("INFO still \(prayer.rawValue): first paint \(Int(first)) ms, pixels differing from ground \(Int(share * 100))%")
        #expect(share > 0.05, "the still looks blank")

        let t1 = ContinuousClock.now
        _ = try #require(await r.image(for: prayer, size: size, scale: 2))
        let second = (ContinuousClock.now - t1) / .milliseconds(1)
        print("INFO still \(prayer.rawValue): cached read \(Int(second)) ms")
        #expect(second < first / 2 || second < 100)
    }

    /// Share of 8 x 8 pixel blocks that are pale, colourless and near-uniform (a bare wall or a lifted-paint cloud).
    private func paleBlankShare(_ img: NSImage) -> Double {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return 1 }
        var pale = 0, total = 0
        for by in stride(from: 0, to: rep.pixelsHigh - 7, by: 8) {
            for bx in stride(from: 0, to: rep.pixelsWide - 7, by: 8) {
                var vals: [Double] = [], sats: [Double] = []
                for y in stride(from: by, to: by + 8, by: 2) {
                    for x in stride(from: bx, to: bx + 8, by: 2) {
                        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        vals.append(0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
                        sats.append(max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent))
                    }
                }
                let mean = vals.reduce(0, +) / Double(max(vals.count, 1))
                let sd = (vals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(vals.count, 1))).squareRoot()
                total += 1
                if mean > 0.8 && sd < 0.02 && sats.reduce(0, +) / Double(max(sats.count, 1)) < 0.06 { pale += 1 }
            }
        }
        return total == 0 ? 1 : Double(pale) / Double(total)
    }

    @Test(arguments: Prayer.allCases, [CGSize(width: 320, height: 96), CGSize(width: 520, height: 96)])
    func bandShowsTheArtNotABlankWall(prayer: Prayer, size: CGSize) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gopray-stills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = SceneStillRenderer(cacheDirectory: dir)
        let img = try #require(await r.image(for: prayer, size: size, scale: 2))
        if let out = ProcessInfo.processInfo.environment["STILL_SHOTS_DIR"] {
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            if let t = img.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(prayer.rawValue)-\(Int(size.width))x\(Int(size.height)).png"))
            }
        }
        let pale = paleBlankShare(img)
        print("INFO still \(prayer.rawValue) \(Int(size.width)): pale-blank \(Int(pale * 100))%")
        // Asr is a white marble hall, so up to half of it is honestly pale haze; the old
        // Dhuhr strip (a lifted-paint cloud over half the band) is the case this must catch.
        let limit = prayer == .asr ? 0.5 : 0.35
        #expect(pale <= limit, "the band is mostly a pale blank")
    }
}
