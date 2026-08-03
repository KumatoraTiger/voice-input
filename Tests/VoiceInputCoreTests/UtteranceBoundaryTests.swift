import Foundation
import Testing

@testable import VoiceInputCore

@Suite("Utterance boundary")
struct UtteranceBoundaryTests {
    // The numbers here are the ones actually observed on macOS 15.5: the running
    // transcript went from 26 characters to 1 and the window start rewound from
    // 0.93s to 0.00s, with no isFinal and no error to mark it.
    @Test("The observed mid-task restart is detected")
    func detectsTheObservedRestart() {
        #expect(
            UtteranceBoundary.restarted(
                previous: "今日の打ち合わせの件なんですけど、資料を共有します",
                next: "そ",
                previousStart: 0.93,
                nextStart: 0.00
            )
        )
    }

    @Test("Growing text is a continuation, never a restart")
    func growingTextIsNotARestart() {
        #expect(
            !UtteranceBoundary.restarted(
                previous: "今日の打ち合わせ",
                next: "今日の打ち合わせの件なんですけど",
                previousStart: 0.10,
                nextStart: 0.10
            )
        )
    }

    @Test("A revision that trims the tail keeps the head, so it is not a restart")
    func tailRevisionIsNotARestart() {
        #expect(
            !UtteranceBoundary.restarted(
                previous: "今日の打ち合わせの件なんですけどね",
                next: "今日の打ち合わせの件なんです",
                previousStart: 0.10,
                nextStart: 0.10
            )
        )
    }

    @Test("A rewound window is a restart even when the text is only a little shorter")
    func rewoundWindowIsARestart() {
        #expect(
            UtteranceBoundary.restarted(
                previous: "資料は前日までに共有してください",
                next: "資料は前日までに共有して",
                previousStart: 2.40,
                nextStart: 0.00
            )
        )
    }

    @Test("A window that only moves forward is a revision, not a restart")
    func forwardWindowIsNotARestart() {
        // Observed too: leading silence gets revised away, so the start slides
        // forward while the text is unchanged in length.
        #expect(
            !UtteranceBoundary.restarted(
                previous: "今日の打ち合わせの件なんですけど",
                next: "今日の打ち合わせの件なんですけ",
                previousStart: 0.00,
                nextStart: 0.93
            )
        )
    }

    @Test("Divergent shorter text at the same offset is a restart")
    func divergentTextAtSameOffsetIsARestart() {
        #expect(
            UtteranceBoundary.restarted(
                previous: "今日の打ち合わせの件なんですけど",
                next: "それでは",
                previousStart: 0.00,
                nextStart: 0.00
            )
        )
    }

    @Test("An empty previous transcript can never be a restart")
    func emptyPreviousIsNeverARestart() {
        #expect(!UtteranceBoundary.restarted(previous: "", next: "そ"))
        #expect(!UtteranceBoundary.restarted(previous: "", next: ""))
    }

    @Test("Identical text is not a restart")
    func identicalTextIsNotARestart() {
        #expect(!UtteranceBoundary.restarted(previous: "同じです", next: "同じです"))
    }

    @Test("commonPrefixCount counts characters, not bytes")
    func commonPrefixCountsCharacters() {
        #expect(UtteranceBoundary.commonPrefixCount("今日は晴れ", "今日は雨") == 3)
        #expect(UtteranceBoundary.commonPrefixCount("abc", "abd") == 2)
        #expect(UtteranceBoundary.commonPrefixCount("", "abc") == 0)
        #expect(UtteranceBoundary.commonPrefixCount("abc", "abc") == 3)
    }
}
