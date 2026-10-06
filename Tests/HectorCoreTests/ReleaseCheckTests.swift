import Foundation
import Testing
@testable import HectorCore

@Suite struct ReleaseCheckTests {
    private func answer(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test func comparesVersionsNumerically() {
        #expect(ReleaseCheck.isNewer("0.4.9", than: "0.4.8"))
        #expect(ReleaseCheck.isNewer("0.4.10", than: "0.4.9"))
        #expect(ReleaseCheck.isNewer("0.5", than: "0.4.12"))
        #expect(ReleaseCheck.isNewer("1.0.0", than: "0.9"))
        #expect(!ReleaseCheck.isNewer("0.4.8", than: "0.4.8"))
        #expect(!ReleaseCheck.isNewer("0.4", than: "0.4.0"))
        #expect(!ReleaseCheck.isNewer("0.4.7", than: "0.4.8"))
        // Anything but plain numbers is never newer.
        #expect(!ReleaseCheck.isNewer("0.5-beta", than: "0.4.8"))
        #expect(!ReleaseCheck.isNewer("", than: "0.4.8"))
        #expect(!ReleaseCheck.isNewer("0.4.9", than: "0.3 or older"))
    }

    @Test func parsesTheLatestRelease() throws {
        let release = try #require(ReleaseCheck.parse(answer([
            "tag_name": "v0.4.9", "html_url": "https://github.com/0xRD/hector/releases/tag/v0.4.9",
            "draft": false, "prerelease": false,
        ])))
        #expect(release.version == "0.4.9")
        #expect(release.page.absoluteString == "https://github.com/0xRD/hector/releases/tag/v0.4.9")
    }

    @Test func refusesDraftsPrereleasesAndOddTags() throws {
        #expect(ReleaseCheck.parse(try answer(["tag_name": "v0.5.0", "prerelease": true])) == nil)
        #expect(ReleaseCheck.parse(try answer(["tag_name": "v0.5.0", "draft": true])) == nil)
        #expect(ReleaseCheck.parse(try answer(["tag_name": "nightly"])) == nil)
        #expect(ReleaseCheck.parse(Data("not json".utf8)) == nil)
    }

    @Test func keepsTheReleasePageOnGitHub() throws {
        let elsewhere = try #require(ReleaseCheck.parse(answer(["tag_name": "0.4.9", "html_url": "https://example.com/hector.zip"])))
        #expect(elsewhere.page == ReleaseCheck.releasesPage)
        let otherRepository = try #require(ReleaseCheck.parse(answer([
            "tag_name": "0.4.9", "html_url": "https://github.com/someone/hector/releases/tag/0.4.9",
        ])))
        #expect(otherRepository.page == ReleaseCheck.releasesPage)
    }
}
