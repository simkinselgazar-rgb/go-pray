// StateStore.swift — state.json on disk (§C.2). Owner: PM.
// Atomic write: a 0600 temp file in the same directory, fsync, rename(2).
// A half-written file is impossible. A bad file is moved aside and reads as
// idle (fail open).

import Foundation
import os

@MainActor final class StateStore {
    enum LoadResult: Equatable {
        case missing                 // first run: idle
        case loaded(BlockStateFile)
        case corrupt(movedTo: URL?)  // renamed to state.corrupt-<unix>.json: idle
    }

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("state.json") }
    private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "state")

    init(directory: URL) { self.directory = directory }

    /// `~/Library/Application Support/GoPray/`
    nonisolated static func defaultDirectory() -> URL {
        supportBase().appendingPathComponent("GoPray", isDirectory: true)
    }

    /// `~/Library/Application Support`. The one place the app picks it (state, settings,
    /// stills, the instance lock). In a DEBUG test run it is a per-process temp folder, so a
    /// hosted test run never touches the real files. Release has no such switch: no
    /// environment variable can move state.json.
    nonisolated static func supportBase() -> URL {
        #if DEBUG
        if TestHost.isActive {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("GoPray-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    func load() -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            log.error("state.json unreadable: \(error.localizedDescription, privacy: .public)")
            return .corrupt(movedTo: quarantine(reason: "unreadable"))
        }
        do {
            return .loaded(try BlockStateFile.makeDecoder().decode(BlockStateFile.self, from: data))
        } catch {
            log.error("state.json does not decode: \(String(describing: error), privacy: .public)")
            return .corrupt(movedTo: quarantine(reason: "decode"))
        }
    }

    func save(_ state: BlockStateFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try BlockStateFile.makeEncoder().encode(state)
        let tmp = directory.appendingPathComponent(".state.\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = false
        defer { if !ok { unlink(tmp.path) } }
        let written = data.withUnsafeBytes { buf in write(fd, buf.baseAddress, buf.count) }
        let synced = fsync(fd)
        close(fd)
        guard written == data.count, synced == 0 else { throw POSIXError(.EIO) }
        guard rename(tmp.path, fileURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        ok = true
    }

    /// Moves state.json aside as state.corrupt-<unix>.json. Returns the new URL,
    /// or nil if there was nothing to move (or the move failed; then the file is deleted).
    @discardableResult
    func quarantine(reason: String) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        var dest = directory.appendingPathComponent("state.corrupt-\(stamp).json")
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = directory.appendingPathComponent("state.corrupt-\(stamp)-\(n).json"); n += 1
        }
        do {
            try fm.moveItem(at: fileURL, to: dest)
            log.error("state.json quarantined (\(reason, privacy: .public)) → \(dest.lastPathComponent, privacy: .public)")
            return dest
        } catch {
            try? fm.removeItem(at: fileURL)
            log.error("state.json quarantine failed, deleted: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    #if DEBUG
    func wipe() { try? FileManager.default.removeItem(at: fileURL) }
    #endif
}

#if DEBUG
/// True when this process is an XCTest / Swift Testing host.
enum TestHost {
    static var isActive: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil
    }
}
#endif
