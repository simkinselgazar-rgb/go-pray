// UpdateChecker.swift — "is there a newer Go Pray?" (v2 §8, CONTRACT-NOTES #55). The ONE new network file.
//
// Minimal on purpose, not Sparkle: one anonymous GET to GitHub Releases (no id, no version, no cookies),
// a verified download, then the person opens the DMG and drags the app. Rules:
//   - Never while the gate is blocked: no request, no download, no open (the timer just tries later).
//   - Only a STRICTLY newer version, from a published (not draft, not pre-release) `v<semver>` release.
//   - The asset URL must be exactly https://github.com/<repo>/releases/download/<tag>/GoPray-<ver>.dmg.
//   - The download is signature-checked (Developer ID, team 3BB4JMG8GR) before it is opened. Any failure
//     deletes the file. Gatekeeper still assesses the notarization when the DMG mounts.
// guard.sh rule 4 pins URLSession, the GitHub hosts, the team-id requirement and the opener to this file.

import AppKit
import Foundation
import Security
import os

// MARK: - Seams (tests use fakes: no real network, no real installer, no real signature)

protocol UpdateTransport: Sendable {
    /// The body of a 200 response, or throws.
    func get(_ url: URL) async throws -> Data
    /// Streams to `file`; throws (and leaves no file) on a non-200, a redirect off GitHub, or more than `maxBytes`.
    func download(_ url: URL, to file: URL, maxBytes: Int) async throws
}

protocol UpdateVerifier: Sendable {
    func verify(_ file: URL) -> Bool
}

enum UpdateError: Error, Equatable { case badStatus(Int), tooLarge, redirected, malformed, offline }

// MARK: - Versions and releases (pure, tested on their own)

struct AppVersion: Comparable, Equatable, Sendable {
    let parts: [Int]

    /// "0.2.0" only: three plain numbers. "0.3.0-beta", "1.2", "v1.2.3" are not versions.
    init?(_ text: String) {
        let bits = text.split(separator: ".", omittingEmptySubsequences: false)
        guard bits.count == 3 else { return nil }
        var out: [Int] = []
        for b in bits {
            guard !b.isEmpty, b.count <= 6, b.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(b) else { return nil }
            out.append(n)
        }
        parts = out
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    var text: String { parts.map(String.init).joined(separator: ".") }
}

struct UpdateOffer: Codable, Equatable, Sendable {
    var tag: String
    var version: String
    var assetURL: String
    var size: Int
}

enum ReleaseFeed {
    static let maxAssetBytes = 300 * 1024 * 1024

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let size: Int; let browser_download_url: String }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    /// The highest published release of this platform that is strictly newer than `current`, with a
    /// well-formed asset on the pinned URL path. nil = nothing to offer.
    static func newest(in data: Data, current: AppVersion, repo: String, tagPrefix: String) -> UpdateOffer? {
        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { return nil }
        var best: (AppVersion, UpdateOffer)?
        for r in releases where !r.draft && !r.prerelease {
            guard r.tag_name.hasPrefix(tagPrefix), let v = AppVersion(String(r.tag_name.dropFirst(tagPrefix.count))), v > current,
                  r.tag_name == tagPrefix + v.text else { continue }  // non-canonical tags (v01.2.0) are never offered
            if let b = best, b.0 >= v { continue }
            let name = "GoPray-\(v.text).dmg"
            let want = "https://github.com/\(repo)/releases/download/\(r.tag_name)/\(name)"
            guard let a = r.assets.first(where: { $0.name == name }), a.browser_download_url == want,
                  a.size > 0, a.size <= maxAssetBytes else { continue }
            best = (v, UpdateOffer(tag: r.tag_name, version: v.text, assetURL: want, size: a.size))
        }
        return best?.1
    }
}

// MARK: - The checker

@MainActor @Observable final class UpdateChecker {
    enum Status: Equatable { case idle, checking, upToDate, available(version: String), downloading, failed(String) }

    static let checkInterval: TimeInterval = 24 * 3600
    static let firstCheckDelay: Duration = .seconds(30)
    static let couldntVerify = "Couldn't verify the download. Get it from GitHub."
    static let couldntReach = "Couldn't reach GitHub. Try later."
    static let brewLine = "Installed with Homebrew: run `brew upgrade --cask go-pray`"

    private(set) var status: Status = .idle
    /// True when this copy lives in a Homebrew Caskroom: no download, the menu shows `brewLine`.
    let isHomebrewInstall: Bool

    @ObservationIgnored private let transport: UpdateTransport
    @ObservationIgnored private let verifier: UpdateVerifier
    @ObservationIgnored private let currentVersion: AppVersion
    @ObservationIgnored private let repo: String
    @ObservationIgnored private let tagPrefix: String
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let isBlocked: @MainActor () -> Bool
    @ObservationIgnored private let automatic: @MainActor () -> Bool
    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private let open: @MainActor (URL) -> Void
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "update")

    private var updatesDirectory: URL { directory.appendingPathComponent("updates", isDirectory: true) }
    private var memoryURL: URL { directory.appendingPathComponent("update.json") }

    init(transport: UpdateTransport = URLSessionTransport(), verifier: UpdateVerifier = CodesignVerifier(),
         currentVersion: String, repo: String = "simkinselgazar-rgb/go-pray", tagPrefix: String = "v",
         directory: URL = StateStore.defaultDirectory(), isHomebrewInstall: Bool = UpdateChecker.runsFromCaskroom(),
         isBlocked: @escaping @MainActor () -> Bool, automatic: @escaping @MainActor () -> Bool, clock: Clock,
         open: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.transport = transport
        self.verifier = verifier
        self.currentVersion = AppVersion(currentVersion) ?? AppVersion("0.0.0")!
        self.repo = repo
        self.tagPrefix = tagPrefix
        self.directory = directory
        self.isHomebrewInstall = isHomebrewInstall
        self.isBlocked = isBlocked
        self.automatic = automatic
        self.clock = clock
        self.open = open
        if let offer = memory()?.latest, let v = AppVersion(offer.version), v > self.currentVersion {
            status = .available(version: offer.version)
        }
    }

    nonisolated static func runsFromCaskroom(_ path: String = Bundle.main.bundlePath) -> Bool { path.contains("/Caskroom/") }

    /// The page the "Get it from GitHub" link opens.
    var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }
    func openReleasesPage() { open(releasesPage) }

    // MARK: Schedule

    /// 30 s after launch, then once a day; also when the Mac wakes. Clears old downloads.
    func start() {
        guard loop == nil else { return }
        clearUpdates()
        loop = Task { [weak self] in
            try? await Task.sleep(for: Self.firstCheckDelay)
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(3600))   // looks hourly; a request needs 24 h since the last
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// An automatic check: only if the setting is on, nothing is blocked, and the last check is 24 h old.
    func checkIfDue() async {
        guard automatic(), !isBlocked() else { return }
        if let last = memory()?.lastCheckedAt, clock.now.timeIntervalSince(last) >= 0,
           clock.now.timeIntervalSince(last) < Self.checkInterval { return }
        await check(manual: false)
    }

    /// The menu item. Works even when the automatic toggle is off, never during a block.
    func checkNow() async { await check(manual: true) }

    private func check(manual: Bool) async {
        guard !isBlocked(), !busy else { return }
        busy = true; defer { busy = false }
        let was = status
        status = .checking
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30")!
        do {
            let data = try await transport.get(url)
            guard !isBlocked() else { status = was; return }       // a block started while we waited: say nothing
            let offer = ReleaseFeed.newest(in: data, current: currentVersion, repo: repo, tagPrefix: tagPrefix)
            save(Memory(schemaVersion: 1, lastCheckedAt: clock.now, latest: offer))
            if let offer { status = .available(version: offer.version) }
            else { status = manual ? .upToDate : .idle }
        } catch {
            log.error("update check failed")
            status = manual ? .failed(Self.couldntReach) : (was == .checking ? .idle : was)
        }
    }

    // MARK: Download, verify, open

    /// The "Update available" click. Verify or delete; never during a block; never for a Homebrew copy.
    func downloadAndOpen() async {
        guard case .available = status, !isHomebrewInstall, !isBlocked(), !busy, let offer = memory()?.latest,
              let version = AppVersion(offer.version), version > currentVersion,
              offer.size > 0, offer.size <= ReleaseFeed.maxAssetBytes else { return }
        // update.json is persisted state, so nothing in it is trusted: rebuild the one URL we would ever
        // fetch from the pinned repo, the tag and the asset name, and refuse unless the stored offer is exactly it.
        let tag = tagPrefix + version.text
        let expected = "https://github.com/\(repo)/releases/download/\(tag)/GoPray-\(version.text).dmg"
        guard offer.tag == tag, offer.assetURL == expected, let url = URL(string: expected) else {
            log.error("stored update offer does not match the pinned URL, ignored")
            return
        }
        busy = true; defer { busy = false }
        status = .downloading
        clearUpdates()
        let file = updatesDirectory.appendingPathComponent("GoPray-\(version.text).dmg")
        do {
            try FileManager.default.createDirectory(at: updatesDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try await transport.download(url, to: file, maxBytes: min(offer.size + 1024, ReleaseFeed.maxAssetBytes))
        } catch {
            try? FileManager.default.removeItem(at: file)
            status = .failed(Self.couldntReach)
            return
        }
        guard !isBlocked() else { try? FileManager.default.removeItem(at: file); status = .available(version: version.text); return }
        guard verifier.verify(file) else {
            try? FileManager.default.removeItem(at: file)
            log.error("download failed verification, deleted")
            status = .failed(Self.couldntVerify)
            return
        }
        open(file)
        status = .available(version: offer.version)
    }

    /// Old downloads go at launch and before the next one (not right after an open: the DMG is still mounting).
    private func clearUpdates() { try? FileManager.default.removeItem(at: updatesDirectory) }

    // MARK: update.json (owned by this file; corrupt → treated as never checked)

    struct Memory: Codable, Equatable {
        var schemaVersion: Int
        var lastCheckedAt: Date
        var latest: UpdateOffer?
    }

    private func memory() -> Memory? {
        guard let data = try? Data(contentsOf: memoryURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let m = try? dec.decode(Memory.self, from: data), m.schemaVersion == 1 else { return nil }
        return m
    }

    private func save(_ m: Memory) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try enc.encode(m).write(to: memoryURL, options: .atomic)
        } catch { log.error("update.json write failed") }
    }
}

// MARK: - Real signature check (Developer ID, team 3BB4JMG8GR)

struct CodesignVerifier: UpdateVerifier {
    static let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"3BB4JMG8GR\" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"  // Developer ID only

    func verify(_ file: URL) -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
    }
}

// MARK: - Real transport (ephemeral session, 10 s connect, 10 min download, GitHub-only redirects)

final class URLSessionTransport: NSObject, UpdateTransport, @unchecked Sendable {
    static let allowedHosts: Set<String> = ["github.com", "api.github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    private var session: URLSession!
    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]

    fileprivate final class Job: @unchecked Sendable {
        let file: URL?; let maxBytes: Int
        var buffer = Data(); var handle: FileHandle?; var written = 0
        var failure: UpdateError?
        let done: CheckedContinuation<Data, Error>
        init(file: URL?, maxBytes: Int, done: CheckedContinuation<Data, Error>) { self.file = file; self.maxBytes = maxBytes; self.done = done }
    }

    /// `configuration` is for tests (a URLProtocol stub); the default is the real ephemeral one.
    init(configuration: URLSessionConfiguration? = nil) {
        super.init()
        let cfg = configuration ?? URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 600
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: Handler(owner: self), delegateQueue: q)
    }

    func get(_ url: URL) async throws -> Data { try await run(url, file: nil, maxBytes: 5 * 1024 * 1024) }

    func download(_ url: URL, to file: URL, maxBytes: Int) async throws { _ = try await run(url, file: file, maxBytes: maxBytes) }

    private func run(_ url: URL, file: URL?, maxBytes: Int) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("GoPray", forHTTPHeaderField: "User-Agent")     // GitHub requires one; nothing else is sent
        req.httpShouldHandleCookies = false
        return try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: req)
            lock.lock(); jobs[task.taskIdentifier] = Job(file: file, maxBytes: maxBytes, done: cont); lock.unlock()
            task.resume()
        }
    }

    fileprivate func job(_ task: URLSessionTask) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[task.taskIdentifier] }

    fileprivate func finish(_ task: URLSessionTask, error: Error?) {
        lock.lock(); let j = jobs.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let j else { return }
        try? j.handle?.close()
        if let f = j.failure ?? (error == nil ? nil : UpdateError.offline) {
            if let file = j.file { try? FileManager.default.removeItem(at: file) }
            j.done.resume(throwing: f)
        } else {
            j.done.resume(returning: j.buffer)
        }
    }

    /// Cancels with a reason the caller can see.
    fileprivate func fail(_ task: URLSessionTask, _ reason: UpdateError) { job(task)?.failure = reason; task.cancel() }

    private final class Handler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: URLSessionTransport?
        init(owner: URLSessionTransport) { self.owner = owner }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let owner, let host = request.url?.host?.lowercased(), request.url?.scheme == "https",
                  URLSessionTransport.allowedHosts.contains(host) else {
                owner?.fail(task, .redirected); completionHandler(nil); return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let owner, let j = owner.job(dataTask), let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
            guard http.statusCode == 200 else { owner.fail(dataTask, .badStatus(http.statusCode)); completionHandler(.cancel); return }
            if response.expectedContentLength > Int64(j.maxBytes) { owner.fail(dataTask, .tooLarge); completionHandler(.cancel); return }
            if let file = j.file {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                j.handle = try? FileHandle(forWritingTo: file)
                if j.handle == nil { owner.fail(dataTask, .malformed); completionHandler(.cancel); return }
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let owner, let j = owner.job(dataTask) else { return }
            j.written += data.count
            if j.written > j.maxBytes { owner.fail(dataTask, .tooLarge); return }
            if let h = j.handle { try? h.write(contentsOf: data) } else { j.buffer.append(data) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            owner?.finish(task, error: error)
        }
    }
}
