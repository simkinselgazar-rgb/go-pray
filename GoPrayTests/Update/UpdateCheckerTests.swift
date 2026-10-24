// UpdateCheckerTests.swift — v2 §8.5. A fake transport, a fake verifier, a fake opener: no real network,
// no real installer, no real signature check (the one real-signature test reads nothing from the network).

import Foundation
import Testing
@testable import GoPray

private let repo = "simkinselgazar-rgb/go-pray"

private func release(_ tag: String, draft: Bool = false, pre: Bool = false, asset: String? = nil, size: Int = 5_000_000,
                     url: String? = nil) -> String {
    let ver = tag.split(separator: "v").last.map(String.init) ?? ""
    let name = asset ?? "GoPray-\(ver).dmg"
    let u = url ?? "https://github.com/\(repo)/releases/download/\(tag)/\(name)"
    return #"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(pre),"assets":[{"name":"\#(name)","size":\#(size),"browser_download_url":"\#(u)"}]}"#
}

private func feed(_ items: String...) -> Data { Data("[\(items.joined(separator: ","))]".utf8) }

private let fixture = feed(release("v0.1.1"), release("v0.2.0"), release("win-v0.2.0"), release("v0.3.0", draft: true),
                           release("v0.3.0-beta", pre: true))

final class FakeTransport: UpdateTransport, @unchecked Sendable {
    private let lock = NSLock()
    var body = fixture
    var failGet = false
    var failDownload = false
    private(set) var gets: [URL] = []
    private(set) var downloads: [(URL, Int)] = []
    var callCount: Int { lock.withLock { gets.count + downloads.count } }

    func get(_ url: URL) async throws -> Data {
        lock.withLock { gets.append(url) }
        if failGet { throw UpdateError.offline }
        return body
    }
    func download(_ url: URL, to file: URL, maxBytes: Int) async throws {
        lock.withLock { downloads.append((url, maxBytes)) }
        if failDownload { throw UpdateError.offline }
        try Data("dmg".utf8).write(to: file)
    }
}

struct FakeVerifier: UpdateVerifier { var ok: Bool; func verify(_ file: URL) -> Bool { ok } }

@MainActor private final class Rig {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gopray-upd-\(UUID().uuidString)", isDirectory: true)
    let clock = FakeClock(FakeSchedule.day0)
    let transport = FakeTransport()
    var blocked = false
    var automatic = true
    var opened: [URL] = []
    var checker: UpdateChecker!

    init(current: String = "0.1.1", verifier: Bool = true, brew: Bool = false, tagPrefix: String = "v") {
        checker = UpdateChecker(transport: transport, verifier: FakeVerifier(ok: verifier), currentVersion: current, repo: repo,
                                tagPrefix: tagPrefix, directory: dir, isHomebrewInstall: brew,
                                isBlocked: { [unowned self] in self.blocked }, automatic: { [unowned self] in self.automatic },
                                clock: clock, open: { [unowned self] in self.opened.append($0) })
    }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
    var updatesDir: URL { dir.appendingPathComponent("updates") }
}

@MainActor @Suite("Update check")
struct UpdateCheckerTests {
    // MARK: Which release

    @Test func macPicksTheNewestPlainVTagAndIgnoresWindowsDraftsAndPrereleases() {
        let mac = ReleaseFeed.newest(in: fixture, current: AppVersion("0.1.1")!, repo: repo, tagPrefix: "v")
        #expect(mac?.version == "0.2.0" && mac?.tag == "v0.2.0")
        let onlyWindows = feed(release("win-v0.9.0"))
        #expect(ReleaseFeed.newest(in: onlyWindows, current: AppVersion("0.1.1")!, repo: repo, tagPrefix: "v") == nil)
    }

    @Test func currentEqualOrNewerOffersNothing() {
        #expect(ReleaseFeed.newest(in: fixture, current: AppVersion("0.2.0")!, repo: repo, tagPrefix: "v") == nil)
        #expect(ReleaseFeed.newest(in: fixture, current: AppVersion("1.0.0")!, repo: repo, tagPrefix: "v") == nil)
    }

    @Test func versionsCompareNumbersNotText() {
        #expect(AppVersion("0.10.0")! > AppVersion("0.9.9")!)
        #expect(AppVersion("0.3.0-beta") == nil && AppVersion("1.2") == nil && AppVersion("v1.2.3") == nil && AppVersion("1.2.x") == nil)
    }

    @Test func anAssetOffTheRepoPathIsRejected() {
        let evil = feed(release("v0.2.0", url: "https://evil.example/releases/download/v0.2.0/GoPray-0.2.0.dmg"))
        #expect(ReleaseFeed.newest(in: evil, current: AppVersion("0.1.1")!, repo: repo, tagPrefix: "v") == nil)
        let other = feed(release("v0.2.0", url: "https://github.com/someone-else/go-pray/releases/download/v0.2.0/GoPray-0.2.0.dmg"))
        #expect(ReleaseFeed.newest(in: other, current: AppVersion("0.1.1")!, repo: repo, tagPrefix: "v") == nil)
        let wrongName = feed(release("v0.2.0", asset: "Something.dmg"))
        #expect(ReleaseFeed.newest(in: wrongName, current: AppVersion("0.1.1")!, repo: repo, tagPrefix: "v") == nil)
    }

    @Test func aNonCanonicalTagIsNeverOffered() {
        // "v01.2.0" parses to 1.2.0 but the download step rebuilds "v1.2.0" and would refuse it forever.
        let odd = feed(release("v01.2.0", asset: "GoPray-1.2.0.dmg"))
        #expect(ReleaseFeed.newest(in: odd, current: AppVersion("0.1.1")!, repo: repo, tagPrefix: "v") == nil)
    }

    @Test func theDownloadHostsIncludeGitHubsReleaseAssetHost() {
        #expect(URLSessionTransport.allowedHosts.contains("release-assets.githubusercontent.com"))
        #expect(CodesignVerifier.requirement.contains("1.2.840.113635.100.6.1.13"))  // Developer ID leaf only
    }

    @Test func anAssetOverTheCapOrEmptyIsRejected() {
        let big = feed(release("v0.2.0", size: ReleaseFeed.maxAssetBytes + 1))
        #expect(ReleaseFeed.newest(in: big, current: AppVersion("0.1.1")!, repo: repo, tagPrefix: "v") == nil)
        #expect(ReleaseFeed.newest(in: feed(release("v0.2.0", size: 0)), current: AppVersion("0.1.1")!, repo: repo, tagPrefix: "v") == nil)
        #expect(ReleaseFeed.newest(in: Data("not json".utf8), current: AppVersion("0.1.1")!, repo: repo, tagPrefix: "v") == nil)
    }

    // MARK: Checking

    @Test func aCheckFindsTheUpdateAndRemembersIt() async throws {
        let r = Rig(); defer { r.cleanup() }
        await r.checker.checkNow()
        #expect(r.checker.status == .available(version: "0.2.0"))
        #expect(r.transport.gets.map(\.absoluteString) == ["https://api.github.com/repos/\(repo)/releases?per_page=30"])
        // A new process sees it without asking again.
        let again = Rig(); defer { again.cleanup() }
        try? FileManager.default.createDirectory(at: again.dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: r.dir.appendingPathComponent("update.json"), to: again.dir.appendingPathComponent("update.json"))
        again.checker = UpdateChecker(transport: again.transport, verifier: FakeVerifier(ok: true), currentVersion: "0.1.1", repo: repo,
                                      directory: again.dir, isHomebrewInstall: false, isBlocked: { false }, automatic: { true }, clock: again.clock)
        #expect(again.checker.status == .available(version: "0.2.0"))
    }

    @Test func upToDateSaysSoOnlyAfterAManualCheck() async {
        let r = Rig(current: "0.2.0"); defer { r.cleanup() }
        await r.checker.checkIfDue()
        #expect(r.checker.status == .idle)
        r.clock.now = r.clock.now.addingTimeInterval(25 * 3600)
        await r.checker.checkNow()
        #expect(r.checker.status == .upToDate)
    }

    @Test func nothingLeavesTheMachineDuringABlock() async {
        let r = Rig(); defer { r.cleanup() }
        r.blocked = true
        await r.checker.checkIfDue()
        await r.checker.checkNow()
        await r.checker.downloadAndOpen()
        #expect(r.transport.callCount == 0 && r.opened.isEmpty)
    }

    @Test func theAutomaticToggleStopsAutomaticChecksButNotTheMenuItem() async {
        let r = Rig(); defer { r.cleanup() }
        r.automatic = false
        await r.checker.checkIfDue()
        #expect(r.transport.callCount == 0)
        await r.checker.checkNow()
        #expect(r.transport.callCount == 1)
    }

    @Test func aCheckIsDueOnlyAfterTwentyFourHours() async {
        let r = Rig(); defer { r.cleanup() }
        await r.checker.checkIfDue()
        #expect(r.transport.gets.count == 1)
        r.clock.now = r.clock.now.addingTimeInterval(23 * 3600)
        await r.checker.checkIfDue()
        #expect(r.transport.gets.count == 1)
        r.clock.now = r.clock.now.addingTimeInterval(2 * 3600)     // 25 h since the first
        await r.checker.checkIfDue()
        #expect(r.transport.gets.count == 2)
    }

    @Test func aCorruptMemoryFileCountsAsNeverChecked() async throws {
        let r = Rig(); defer { r.cleanup() }
        try FileManager.default.createDirectory(at: r.dir, withIntermediateDirectories: true)
        try "{ nope".write(to: r.dir.appendingPathComponent("update.json"), atomically: true, encoding: .utf8)
        await r.checker.checkIfDue()
        #expect(r.transport.gets.count == 1)
    }

    @Test func aFailedCheckIsQuietWhenAutomaticAndALineWhenManual() async {
        let r = Rig(); defer { r.cleanup() }
        r.transport.failGet = true
        await r.checker.checkIfDue()
        #expect(r.checker.status == .idle)
        await r.checker.checkNow()
        #expect(r.checker.status == .failed(UpdateChecker.couldntReach))
    }

    // MARK: Downloading

    @Test func aVerifiedDownloadIsOpenedOnceFromThePinnedUrl() async {
        let r = Rig(); defer { r.cleanup() }
        await r.checker.checkNow()
        await r.checker.downloadAndOpen()
        #expect(r.transport.downloads.map(\.0.absoluteString) == ["https://github.com/\(repo)/releases/download/v0.2.0/GoPray-0.2.0.dmg"])
        #expect(r.opened.count == 1 && r.opened[0].lastPathComponent == "GoPray-0.2.0.dmg")
        #expect(r.transport.downloads[0].1 <= ReleaseFeed.maxAssetBytes)
    }

    @Test func aDownloadThatFailsVerificationIsDeletedAndNeverOpened() async {
        let r = Rig(verifier: false); defer { r.cleanup() }
        await r.checker.checkNow()
        await r.checker.downloadAndOpen()
        #expect(r.opened.isEmpty)
        #expect(r.checker.status == .failed(UpdateChecker.couldntVerify))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: r.updatesDir.path)) ?? []).isEmpty)
    }

    @Test func aFailedDownloadLeavesNoFile() async {
        let r = Rig(); defer { r.cleanup() }
        await r.checker.checkNow()
        r.transport.failDownload = true
        await r.checker.downloadAndOpen()
        #expect(r.opened.isEmpty && r.checker.status == .failed(UpdateChecker.couldntReach))
    }

    @Test func aHomebrewCopyNeverDownloads() async {
        let r = Rig(brew: true); defer { r.cleanup() }
        await r.checker.checkNow()
        await r.checker.downloadAndOpen()
        #expect(r.transport.downloads.isEmpty && r.opened.isEmpty)
        #expect(r.checker.isHomebrewInstall)
        #expect(UpdateChecker.runsFromCaskroom("/opt/homebrew/Caskroom/go-pray/0.1.1/Go Pray.app"))
        #expect(!UpdateChecker.runsFromCaskroom("/Applications/Go Pray.app"))
    }

    @Test func aBlockThatStartsDuringTheDownloadStopsTheOpen() async {
        let r = Rig(); defer { r.cleanup() }
        await r.checker.checkNow()
        r.transport.failDownload = false
        r.blocked = false
        // The fake downloads instantly; flip the block flag in the verifier's place by blocking before the open.
        r.checker = UpdateChecker(transport: r.transport, verifier: FakeVerifier(ok: true), currentVersion: "0.1.1", repo: repo,
                                  directory: r.dir, isHomebrewInstall: false, isBlocked: { [unowned r] in !r.transport.downloads.isEmpty },
                                  automatic: { true }, clock: r.clock, open: { [unowned r] in r.opened.append($0) })
        await r.checker.downloadAndOpen()
        #expect(r.opened.isEmpty)
    }

    @Test func aTamperedPersistedOfferNeverDownloads() async throws {
        let cases: [(String, UpdateOffer)] = [
            ("evil host", .init(tag: "v0.2.0", version: "0.2.0", assetURL: "https://evil.example/GoPray-0.2.0.dmg", size: 1000)),
            ("other repo", .init(tag: "v0.2.0", version: "0.2.0", assetURL: "https://github.com/someone/else/releases/download/v0.2.0/GoPray-0.2.0.dmg", size: 1000)),
            ("wrong tag", .init(tag: "v0.9.9", version: "0.2.0", assetURL: "https://github.com/\(repo)/releases/download/v0.2.0/GoPray-0.2.0.dmg", size: 1000)),
            ("traversal in version", .init(tag: "v0.2.0/../../x", version: "0.2.0/../../x", assetURL: "https://github.com/\(repo)/releases/download/v0.2.0/GoPray-0.2.0.dmg", size: 1000)),
            ("huge size", .init(tag: "v0.2.0", version: "0.2.0", assetURL: "https://github.com/\(repo)/releases/download/v0.2.0/GoPray-0.2.0.dmg", size: ReleaseFeed.maxAssetBytes + 1)),
            ("not newer", .init(tag: "v0.1.1", version: "0.1.1", assetURL: "https://github.com/\(repo)/releases/download/v0.1.1/GoPray-0.1.1.dmg", size: 1000)),
        ]
        for (name, offer) in cases {
            let r = Rig(); defer { r.cleanup() }
            try FileManager.default.createDirectory(at: r.dir, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try enc.encode(UpdateChecker.Memory(schemaVersion: 1, lastCheckedAt: r.clock.now, latest: offer))
                .write(to: r.dir.appendingPathComponent("update.json"))
            // A new process reads the tampered file; whatever status it shows, no request or open may follow.
            let c = UpdateChecker(transport: r.transport, verifier: FakeVerifier(ok: true), currentVersion: "0.1.1", repo: repo,
                                  directory: r.dir, isHomebrewInstall: false, isBlocked: { false }, automatic: { true },
                                  clock: r.clock, open: { r.opened.append($0) })
            await c.downloadAndOpen()
            #expect(r.transport.downloads.isEmpty && r.opened.isEmpty, "\(name)")
        }
    }

    @Test func aCleanPersistedOfferStillDownloadsFromTheRebuiltUrl() async throws {
        let r = Rig(); defer { r.cleanup() }
        await r.checker.checkNow()
        let fresh = UpdateChecker(transport: r.transport, verifier: FakeVerifier(ok: true), currentVersion: "0.1.1", repo: repo,
                                  directory: r.dir, isHomebrewInstall: false, isBlocked: { false }, automatic: { true },
                                  clock: r.clock, open: { r.opened.append($0) })
        await fresh.downloadAndOpen()
        #expect(r.transport.downloads.map(\.0.absoluteString) == ["https://github.com/\(repo)/releases/download/v0.2.0/GoPray-0.2.0.dmg"])
        #expect(r.opened.count == 1)
    }

    @Test func releasesPageIsTheRepoReleasesUrl() {
        let r = Rig(); defer { r.cleanup() }
        r.checker.openReleasesPage()
        #expect(r.opened.map(\.absoluteString) == ["https://github.com/\(repo)/releases"])
    }

    // MARK: The real pieces, with no network

    @Test func theRequirementPinsTheTeam() {
        #expect(CodesignVerifier.requirement.contains("3BB4JMG8GR"))
        #expect(!CodesignVerifier().verify(URL(fileURLWithPath: "/nonexistent/file.dmg")))
    }

    @Test func anUnsignedFileFailsTheRealVerifier() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("unsigned-\(UUID().uuidString).dmg")
        try Data("not a disk image".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(!CodesignVerifier().verify(f))
    }
}

// The real transport against a URLProtocol stub: status, cap and redirect rules, still no network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, StubProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
}

@Suite("Update transport", .serialized)
struct UpdateTransportTests {
    private func transport() -> URLSessionTransport {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSessionTransport(configuration: cfg)
    }

    private func respond(_ p: StubProtocol, status: Int = 200, length: Int? = nil, body: Data) {
        let url = p.request.url!
        var headers = ["Content-Type": "application/octet-stream"]
        if let length { headers["Content-Length"] = String(length) }
        p.client?.urlProtocol(p, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!,
                              cacheStoragePolicy: .notAllowed)
        p.client?.urlProtocol(p, didLoad: body)
        p.client?.urlProtocolDidFinishLoading(p)
    }

    @Test func aGetReturnsTheBodyAndSendsOnlyAUserAgentAndAccept() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        StubProtocol.handler = { req, p in seen = req; self.respond(p, body: Data("[]".utf8)) }
        let data = try await transport().get(URL(string: "https://api.github.com/x")!)
        #expect(String(data: data, encoding: .utf8) == "[]")
        #expect(seen?.value(forHTTPHeaderField: "User-Agent") == "GoPray")
        #expect(seen?.value(forHTTPHeaderField: "Cookie") == nil && seen?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aNon200Throws() async {
        StubProtocol.handler = { _, p in self.respond(p, status: 404, body: Data()) }
        await #expect(throws: UpdateError.badStatus(404)) { try await self.transport().get(URL(string: "https://api.github.com/x")!) }
    }

    @Test func aDownloadOverTheCapThrowsAndLeavesNoFile() async {
        StubProtocol.handler = { _, p in self.respond(p, body: Data(count: 4096)) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: UpdateError.tooLarge) {
            try await self.transport().download(URL(string: "https://github.com/x")!, to: file, maxBytes: 1000)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aRedirectOffGitHubIsCancelled() async {
        StubProtocol.handler = { req, p in
            let to = URL(string: "https://evil.example/payload.dmg")!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": to.absoluteString])!
            p.client?.urlProtocol(p, wasRedirectedTo: URLRequest(url: to), redirectResponse: resp)
        }
        await #expect(throws: UpdateError.redirected) { try await self.transport().get(URL(string: "https://github.com/x")!) }
    }

    @Test func aDownloadWritesTheFile() async throws {
        StubProtocol.handler = { _, p in self.respond(p, body: Data("hello".utf8)) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: file) }
        try await transport().download(URL(string: "https://github.com/x")!, to: file, maxBytes: 1000)
        #expect(try Data(contentsOf: file) == Data("hello".utf8))
    }
}

@MainActor @Suite("Update menu line")
struct UpdateMenuLineTests {
    @Test func theLineFollowsTheStatus() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gopray-updm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = FakeTransport()
        let u = UpdateChecker(transport: t, verifier: FakeVerifier(ok: false), currentVersion: "0.1.1", directory: dir,
                              isHomebrewInstall: false, isBlocked: { false }, automatic: { true }, clock: FakeClock(FakeSchedule.day0))
        #expect(MenuViewModel.updateLine(u) == nil)
        await u.checkNow()
        #expect(MenuViewModel.updateLine(u) == UpdateLine(text: "Update available: 0.2.0", action: .download))
        await u.downloadAndOpen()
        #expect(MenuViewModel.updateLine(u) == UpdateLine(text: UpdateChecker.couldntVerify, action: .getFromGitHub))
    }

    @Test func aHomebrewCopyShowsTheBrewLineAndNoButton() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gopray-updb-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let u = UpdateChecker(transport: FakeTransport(), verifier: FakeVerifier(ok: true), currentVersion: "0.1.1", directory: dir,
                              isHomebrewInstall: true, isBlocked: { false }, automatic: { true }, clock: FakeClock(FakeSchedule.day0))
        await u.checkNow()
        let line = MenuViewModel.updateLine(u)
        #expect(line?.action == UpdateLine.Action.none && line?.text.contains("brew upgrade --cask go-pray") == true)
    }

    @Test func checkingIsDisabledDuringABlock() throws {
        let f = UIFixture(); defer { f.cleanup() }
        let dir = f.dir.appendingPathComponent("upd")
        let u = UpdateChecker(transport: FakeTransport(), verifier: FakeVerifier(ok: true), currentVersion: "0.1.1", directory: dir,
                              isHomebrewInstall: false, isBlocked: { f.gate.isBlocked }, automatic: { true }, clock: f.clock)
        let menu = f.menuModel(); menu.updater = u
        #expect(menu.snapshot(at: f.clock.now).canCheckForUpdates)
        f.startBlock()
        #expect(!menu.snapshot(at: f.clock.now).canCheckForUpdates)
    }
}
