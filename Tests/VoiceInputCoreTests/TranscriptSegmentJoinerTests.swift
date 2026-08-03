import Foundation
import Testing

@testable import VoiceInputCore

@Suite("TranscriptSegmentJoiner")
struct TranscriptSegmentJoinerTests {
    @Test("Japanese segments join with no separator")
    func joinsJapaneseWithoutSpaces() {
        let joined = TranscriptSegmentJoiner.join([
            "今日は打ち合わせがあります。",
            "資料は前日までに共有してください。",
        ])
        #expect(joined == "今日は打ち合わせがあります。資料は前日までに共有してください。")
    }

    @Test("English segments join with a space")
    func joinsEnglishWithSpaces() {
        let joined = TranscriptSegmentJoiner.join(["Hello there.", "How are you?"])
        #expect(joined == "Hello there. How are you?")
    }

    @Test("A seam touching Japanese on either side takes no space")
    func mixedSeamsFollowTheJapaneseSide() {
        #expect(TranscriptSegmentJoiner.join(["導入は Swift", "で書きました。"]) == "導入は Swiftで書きました。")
        #expect(TranscriptSegmentJoiner.join(["これは Swift。", "Fine."]) == "これは Swift。Fine.")
    }

    @Test("Segments are trimmed and empty ones dropped")
    func trimsAndDropsEmptySegments() {
        let joined = TranscriptSegmentJoiner.join(["  Hello. ", "", "   ", "\nWorld."])
        #expect(joined == "Hello. World.")
    }

    @Test("No segments and only-empty segments produce an empty transcript")
    func emptyInputProducesEmptyOutput() {
        #expect(TranscriptSegmentJoiner.join([]).isEmpty)
        #expect(TranscriptSegmentJoiner.join(["", "  "]).isEmpty)
    }

    @Test("A single segment is returned trimmed and unchanged otherwise")
    func singleSegmentIsUnchanged() {
        #expect(TranscriptSegmentJoiner.join([" 一文だけ。 "]) == "一文だけ。")
    }

    @Test("Order is preserved across many segments")
    func preservesOrder() {
        let joined = TranscriptSegmentJoiner.join(["一。", "二。", "三。", "四。"])
        #expect(joined == "一。二。三。四。")
    }

    @Test("Full-width punctuation counts as continuous script")
    func fullWidthPunctuationNeedsNoSeparator() {
        #expect(!TranscriptSegmentJoiner.needsSeparator(after: "終わり」", before: "next"))
        #expect(!TranscriptSegmentJoiner.needsSeparator(after: "done", before: "「はじめ"))
        #expect(TranscriptSegmentJoiner.needsSeparator(after: "done.", before: "next"))
    }
}
