// CreditsDataTests.swift — lane C.

import Testing
@testable import GoPray

struct CreditsDataTests {
    @Test func creditsListEveryVoiceAndTheRequiredLines() {
        #expect(CreditsData.sunniNames.count == 16)
        #expect(CreditsData.shiaNames.count == 12)
        #expect(CreditsData.praytimesLine.contains("PrayTimes.org"))
        #expect(CreditsData.fajrLine.contains("University of Cambridge"))
        #expect(CreditsData.fajrLine.contains("CC BY-NC-ND 3.0"))
        #expect(CreditsData.takedownText.hasPrefix("If you own one of these recordings and want it removed, email us and we'll take it out."))
    }
}
