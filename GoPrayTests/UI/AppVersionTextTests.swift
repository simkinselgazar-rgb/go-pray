import Foundation
import Testing
@testable import GoPray

@Suite("App version text") struct AppVersionTextTests {
    @Test func labelReadsTheBundleVersion() {
        let v = Bundle(for: BlockGate.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #expect(v != nil)
        #expect(AppVersionText.label(bundle: Bundle(for: BlockGate.self)) == "Go Pray \(v ?? "")")
    }
}
