import Foundation
import Testing
@testable import HectorCore

@Suite struct DisplayTests {
    @Test func wordsAreEnglishWhateverTheRegion() {
        #expect(Display.locale.language.languageCode == .english)
        let hourAgo = Date().addingTimeInterval(-3_600)
        #expect(Display.relative(hourAgo).contains("hour"))
        let day = Date(timeIntervalSince1970: 1_791_100_000) // early October 2026
        #expect(Display.day(day).contains("Oct"))
    }

    @Test func countsAreGrouped() {
        let text = Display.count(113_627)
        #expect(text.hasPrefix("113"))
        #expect(text.hasSuffix("627"))
        #expect(text.count == 7)
    }

    @Test func listsJoinInEnglish() {
        #expect(Display.list([]) == "")
        #expect(Display.list(["Zoom"]) == "Zoom")
        #expect(Display.list(["Zoom", "FaceTime"]) == "Zoom and FaceTime")
        #expect(Display.list(["a", "b", "c"]) == "a, b and c")
    }
}
