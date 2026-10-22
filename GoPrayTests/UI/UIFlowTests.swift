// UIFlowTests.swift — lane A. First-run flow, Settings actions, the popover's snapshot
// and the copy rules. The views are thin; the rules live in the view models, so the
// rules are what is tested here. Pictures are in SnapshotTests.

import Adhan
import Foundation
import Testing
@testable import GoPray

@MainActor @Suite("Setup flow")
struct SetupFlowTests {
    @Test func walksThreeStepsAndSavesOnce() async throws {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        var saves = 0
        f.store.onChange = { _ in saves += 1 }
        let m = f.setupModel()

        #expect(m.step == .city)
        #expect(!m.canGoNext)                                   // Next stays off until a city is picked
        m.pickedCity = .toronto
        #expect(m.canGoNext)
        m.next(); #expect(m.step == .method)
        #expect(m.method == .northAmerica)                      // suggested for Canada
        m.madhab = .hanafi
        m.next(); #expect(m.step == .mode)
        m.mode = .codingApps
        m.volume = 0.5
        #expect(saves == 0, "nothing is saved before the last step")
        #expect(f.store.settings.setupComplete == false)
        m.next()

        #expect(m.step == .done)
        #expect(saves == 1)
        let s = f.store.settings
        #expect(s.setupComplete && s.city == "Toronto, Ontario")
        #expect(s.latitude == 43.6532 && s.longitude == -79.3832)
        #expect(s.method == "northAmerica" && s.madhab == Madhab.hanafi.rawValue)
        #expect(s.mode == .codingApps && s.athanVolume == 0.5 && s.launchAtLogin)
        #expect(f.login.registerCalls == 1)
        #expect(m.nextLine?.hasPrefix("Next: ") == true)
        #expect(m.loginNote == nil)
    }

    @Test func backGoesBackAndKeepsChoices() {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        let m = f.setupModel()
        m.pickedCity = .cairo
        m.next(); m.method = .karachi
        m.next(); m.back(); m.back()
        #expect(m.step == .city)
        #expect(m.pickedCity == .cairo && m.method == .karachi)
        m.back()
        #expect(m.step == .city)
    }

    @Test func suggestionFollowsTheCityUntilThePersonChoosesAMethod() {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        let m = f.setupModel()
        m.pickedCity = .toronto
        #expect(m.method == .northAmerica)
        m.pickedCity = .cairo
        #expect(m.method == .egyptian)                          // still following the country
        m.method = .turkey                                      // their own choice
        m.pickedCity = .toronto
        #expect(m.method == .turkey)                            // never overridden again
    }

    @Test func launchAtLoginFailureStillFinishesSetup() {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        f.login.failure = FakeNetworkError()
        let m = f.setupModel()
        m.pickedCity = .toronto
        m.next(); m.next(); m.next()
        #expect(m.step == .done)
        #expect(f.store.settings.setupComplete)
        #expect(f.store.settings.launchAtLogin == false)        // the stored value matches reality
        #expect(m.loginNote?.contains("Settings") == true)
    }

    @Test func launchAtLoginOffNeverTouchesTheAgent() {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        let m = f.setupModel()
        m.launchAtLogin = false
        m.pickedCity = .toronto
        m.next(); m.next(); m.next()
        #expect(f.login.registerCalls == 0)
        #expect(f.store.settings.launchAtLogin == false)
    }

    @Test func finishIsRefusedByTheGateAndNothingIsSaved() {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        f.startBlock()
        let m = f.setupModel()
        m.pickedCity = .toronto
        m.next(); m.next(); m.next()
        #expect(m.step == .mode)
        #expect(m.notice == GPCopy.blockedLine)
        #expect(f.store.settings.setupComplete == false)
        #expect(f.login.registerCalls == 0, "no side effect before the gate says yes")
    }

    @Test func coordinatesWorkWithoutAnyLookup() {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        let m = f.setupModel()
        m.search.coordinateMode = true
        m.search.coordinateText = "43.65, -79.38"
        m.pickedCity = m.search.coordinateMatch
        m.next(); m.next(); m.next()
        #expect(m.step == .done)
        #expect(f.store.settings.latitude == 43.65)
        #expect(f.geocoder.calls.isEmpty)
    }
}

@MainActor @Suite("City search")
struct CitySearchTests {
    @Test func theGeocoderIsNeverCalledWithoutAUserAction() async {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        // Build everything the app builds at launch and use it, without typing.
        _ = f.setupModel(); _ = f.settingsModel(); let menu = f.menuModel()
        _ = menu.snapshot(at: f.clock.now)
        _ = f.schedule.nextAthan(after: f.clock.now)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(f.geocoder.calls.isEmpty)
    }

    @Test func typingIsTheUserActionAndOneCharIsNotEnough() async {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        f.geocoder.results = [.toronto, .torontoOhio]
        let m = CitySearchModel(geocoder: f.geocoder, debounce: .zero)
        m.queryChanged("T")
        #expect(m.state == .idle)
        m.queryChanged("To")
        #expect(m.state == .searching)                           // the skeleton rows show here
        await m.settle()
        #expect(m.state == .results([.toronto, .torontoOhio]))
        #expect(f.geocoder.calls == ["To"])
    }

    @Test func fastTypingSearchesOnlyTheLastText() async {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        f.geocoder.results = [.cairo]
        let m = CitySearchModel(geocoder: f.geocoder, debounce: .milliseconds(50))
        m.queryChanged("Ca"); m.queryChanged("Cai"); m.queryChanged("Cair")
        await m.settle()
        #expect(f.geocoder.calls == ["Cair"])
    }

    @Test func noMatchAndOfflineHaveTheirOwnStates() async {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        let m = CitySearchModel(geocoder: f.geocoder, debounce: .zero)
        m.queryChanged("zzzz"); await m.settle()
        #expect(m.state == .noMatch)
        f.geocoder.failure = GeocodeFailure.offline
        m.queryChanged("Toronto"); await m.settle()
        #expect(m.state == .offline)
    }

    @Test func clearingTheFieldDropsTheSkeleton() {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        f.geocoder.hang = true
        let m = CitySearchModel(geocoder: f.geocoder, debounce: .zero)
        m.queryChanged("Toronto")
        #expect(m.state == .searching)
        m.queryChanged("")
        #expect(m.state == .idle)
    }
}

@MainActor @Suite("Settings actions")
struct SettingsActionTests {
    @Test func duringABlockEveryActionIsRefusedWithOneLine() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        let before = f.store.settings
        f.startBlock()
        #expect(m.isBlocked)
        #expect(m.apply { $0.mode = .codingApps } == false)
        #expect(m.notice == GPCopy.blockedLine)
        m.setCity(.cairo)
        m.setLaunchAtLogin(true)
        m.pause(.oneWeek)
        m.resume()
        m.set(\.lockMinutes, to: 30)
        #expect(f.store.settings == before)
        #expect(f.login.registerCalls == 0 && f.login.unregisterCalls == 0, "the agent is a side effect: not touched")
        #expect(m.notice == GPCopy.blockedLine)
    }

    @Test func changesApplyWhenIdleAndTheNoticeClears() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        m.set(\.lockMinutes, to: 20)
        #expect(f.store.settings.lockMinutes == 20)
        m.set(\.lockMinutes, to: 99)
        #expect(f.store.settings.lockMinutes == 30)             // clamped
        m.set(\.mode, to: .codingApps)
        #expect(f.store.settings.mode == .codingApps && m.notice == nil)
        m.setCity(.cairo)
        #expect(f.store.settings.city == "Cairo, Cairo Governorate")
        #expect(f.store.settings.latitude == 30.0444)
    }

    @Test func invalidValueShowsAShortLineAndChangesNothing() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        let before = f.store.settings
        #expect(m.apply { $0.latitude = 500 } == false)
        #expect(m.notice == GPCopy.invalidLine)
        #expect(f.store.settings == before)
    }

    @Test func launchAtLoginRegistersThenSaves() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        m.setLaunchAtLogin(true)
        #expect(f.login.registerCalls == 1 && f.store.settings.launchAtLogin)
        m.setLaunchAtLogin(false)
        #expect(f.login.unregisterCalls == 1 && !f.store.settings.launchAtLogin)
    }

    @Test func launchAtLoginFailureLeavesTheSettingAlone() {
        let f = UIFixture(); defer { f.cleanup() }
        try? f.store.mutate { $0.launchAtLogin = false }
        f.login.failure = FakeNetworkError()
        let m = f.settingsModel()
        m.setLaunchAtLogin(true)
        #expect(f.login.registerCalls == 1)
        #expect(f.store.settings.launchAtLogin == false)
        #expect(m.notice?.contains("launch at login") == true)
    }

    @Test func pauseAndResume() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        #expect(m.pauseState == .active && m.pauseSummary == nil)
        m.pause(.untilResumed)
        #expect(m.pauseState == .untilResumed)
        #expect(m.pauseSummary == "Paused until you resume")
        m.pause(.threeDays)
        if case .until(let d) = m.pauseState { #expect(d > f.clock.now.addingTimeInterval(2.9 * 86_400)) }
        else { Issue.record("not paused: \(m.pauseState)") }
        m.resume()
        #expect(m.pauseState == .active)
    }

    @Test func athanPreviewPlaysAThrowawayDhuhrInTheChosenVoice() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        m.set(\.voice, to: .shia("Salimi"))
        m.preview.toggle(voice: m.settings.voice, volume: 0.6)
        #expect(f.audio.plays.count == 1)
        #expect(f.audio.plays[0].0 == .dhuhr && f.audio.plays[0].1 == .shia("Salimi") && f.audio.plays[0].2 == 0.6)
        #expect(m.preview.isPlaying)
        m.preview.toggle(voice: m.settings.voice, volume: 0.6)
        #expect(f.audio.stopCount == 1 && !m.preview.isPlaying)
    }

    @Test func previewDuringABlockDoesNothing() {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        f.startBlock()
        let playsBefore = f.audio.plays.count               // the block's own Athan
        m.preview.toggle(voice: m.settings.voice, volume: 1)
        #expect(f.audio.plays.count == playsBefore && !m.preview.isPlaying)
    }

    @Test func aBlockThatStartsDuringAPreviewKeepsItsAudio() async throws {
        let f = UIFixture(); defer { f.cleanup() }
        let m = f.settingsModel()
        m.preview.toggle(voice: m.settings.voice, volume: 1)
        #expect(m.preview.isPlaying)
        f.startBlock()                                         // Athan: the gate plays its own
        let stopsBefore = f.audio.stopCount
        try await Task.sleep(for: .milliseconds(900))          // the preview poll notices the block
        #expect(!m.preview.isPlaying)
        #expect(f.audio.stopCount == stopsBefore, "the preview must not stop a block's Athan")
        m.preview.stop()
        #expect(f.audio.stopCount == stopsBefore)
    }

    @Test func previewFailureIsReportedNotThrown() {
        let f = UIFixture(); defer { f.cleanup() }
        f.audio.throwOnPlay = true
        let m = f.settingsModel()
        m.preview.toggle(voice: m.settings.voice, volume: 1)
        #expect(m.preview.failed && !m.preview.isPlaying)
    }

    @Test func previewNeverTouchesTheGatesOnFinished() {
        let f = UIFixture(); defer { f.cleanup() }
        let sentinel: () -> Void = {}
        f.audio.onFinished = sentinel
        let m = f.settingsModel()
        m.preview.toggle(voice: m.settings.voice, volume: 1)
        #expect(f.audio.onFinished != nil)
    }
}

@MainActor @Suite("Popover")
struct MenuSnapshotTests {
    @Test func showsFiveTimesAndTheNextPrayer() {
        let f = UIFixture(); defer { f.cleanup() }
        let snap = f.menuModel().snapshot(at: f.clock.now)             // 14:10, after Dhuhr
        #expect(snap.status == .ready)
        #expect(snap.rows.map(\.prayer) == Prayer.allCases)
        #expect(snap.nextPrayer == .asr)
        #expect(snap.rows.filter(\.isNext).map(\.prayer) == [.asr])
        #expect(snap.rows.filter(\.isPast).map(\.prayer) == [.fajr, .dhuhr])
        #expect((snap.untilNext ?? 0) > 60 * 60 && (snap.untilNext ?? 0) < 2 * 60 * 60)
        #expect(snap.footer == "Toronto · ISNA · Standard")
        #expect(snap.mode == .wholeScreen && snap.pausedLine == nil && snap.blockLine == nil)
    }

    @Test func afterIshaTheListIsTomorrowsAndFajrIsNext() {
        let f = UIFixture(at: UIFixture.calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 22, minute: 30))!)
        defer { f.cleanup() }
        let snap = f.menuModel().snapshot(at: f.clock.now)
        #expect(snap.nextPrayer == .fajr)
        #expect(snap.rows.allSatisfy { !$0.isPast })
        let tomorrowFajr = f.schedule.times(on: f.clock.now.addingTimeInterval(86_400))!.fajr
        #expect(snap.rows.first?.time == tomorrowFajr && snap.rows.first?.isNext == true)
    }

    @Test func beforeSetupItAsksForACity() {
        let f = UIFixture(configured: false); defer { f.cleanup() }
        let snap = f.menuModel().snapshot(at: f.clock.now)
        #expect(snap.status == .needsSetup && snap.rows.isEmpty)
    }

    @Test func aPlaceWithNoScheduleSaysSoInsteadOfGuessing() {
        let f = UIFixture(); defer { f.cleanup() }
        // Polar night: Utqiagvik, 2018-01-01. Saved through the store (valid coordinates).
        try? f.store.mutate { $0.latitude = 71.275009; $0.longitude = -156.761368; $0.method = "muslimWorldLeague" }
        let snap = f.menuModel().snapshot(at: UIFixture.calendar.date(from: DateComponents(year: 2018, month: 1, day: 1, hour: 12))!)
        #expect(snap.status == .noSchedule && snap.rows.isEmpty)
    }

    @Test func pausedShowsAUntilLine() {
        let f = UIFixture(); defer { f.cleanup() }
        try? f.store.pause(.untilResumed, now: f.clock.now)
        #expect(f.menuModel().snapshot(at: f.clock.now).pausedLine == "Paused until you resume")
        try? f.store.pause(.oneDay, now: f.clock.now)
        #expect(f.menuModel().snapshot(at: f.clock.now).pausedLine?.hasPrefix("Paused until ") == true)
        try? f.store.resume(now: f.clock.now)
        #expect(f.menuModel().snapshot(at: f.clock.now.addingTimeInterval(1)).pausedLine == nil)
    }

    @Test func duringABlockTheHeaderCountsTheLockDown() {
        let f = UIFixture(); defer { f.cleanup() }
        f.startBlock()
        var snap = f.menuModel().snapshot(at: f.clock.now)
        #expect(snap.isBlocked && snap.blockPrayer == .asr)
        #expect(snap.blockLine == "10:00 left")
        f.clock.advance(372)
        snap = f.menuModel().snapshot(at: f.clock.now)
        #expect(snap.blockLine == "3:48 left")
        f.clock.advance(300)
        snap = f.menuModel().snapshot(at: f.clock.now)
        #expect(snap.blockLine == "Ready when you are")
    }
}

@MainActor @Suite("Copy rules")
struct CopyRuleTests {
    /// Spec §11: no guilt copy, no exclamation marks, no emoji, nothing that scores.
    @Test func noGuiltNoExclamationNoScoring() {
        var all: [String] = [GPCopy.blockedLine, GPCopy.invalidLine, VoiceChoices.fajrNote]
        all += CalculationMethod.choices.flatMap { [$0.displayName, $0.detail, $0.shortName] }
        all += Madhab.allCases.flatMap { [$0.displayName, $0.help] }
        all += HighLatitudeRule.allCases.flatMap { [$0.displayName, $0.help] }
        all += [BlockMode.wholeScreen, .codingApps].flatMap { [$0.displayName, $0.chipName, $0.help] }
        all += PauseOption.allCases.map(\.displayName)
        all += Prayer.allCases.map(\.displayName)
        let banned = ["!", "missed", "streak", "don't break", "you missed", "score", "points", "badge"]
        for text in all {
            for word in banned { #expect(!text.lowercased().contains(word), "\"\(text)\" contains \"\(word)\"") }
            #expect(text.unicodeScalars.allSatisfy { !$0.properties.isEmoji || $0.isASCII }, "emoji in \"\(text)\"")
        }
    }

    @Test func durationText() {
        #expect(TimeText.duration(30) == "less than a minute")
        #expect(TimeText.duration(61) == "2 min")
        #expect(TimeText.duration(49 * 60) == "49 min")
        #expect(TimeText.duration(109 * 60) == "1 h 49 min")
        #expect(TimeText.duration(3 * 3600) == "3 h")
        #expect(TimeText.countdown(372) == "6:12")
        #expect(TimeText.countdown(0) == "0:00")
    }
}
