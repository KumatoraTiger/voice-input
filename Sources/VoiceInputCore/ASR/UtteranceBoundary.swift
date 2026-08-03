import Foundation

/// Spots the moment a streaming recognizer throws away what it had and starts over.
///
/// Apple's on-device recognizer does this part-way through a recognition task: the
/// running transcript reverts to the newest utterance alone and the segment
/// timestamps go back to the beginning. Nothing announces it — no `isFinal`, no
/// error, no callback — so the only way to keep the earlier speech is to notice
/// that the text moved *backwards* and bank what was there before.
///
/// Getting this wrong in either direction is costly, so both signals must agree:
/// a missed restart silently drops the first half of a dictation, and a false one
/// duplicates it.
public enum UtteranceBoundary {
    /// How much of the old transcript must survive as a prefix for the new one to
    /// count as a revision of it rather than a fresh start.
    private static let revisionPrefixRatio = 0.5
    /// Timestamps are seconds; anything smaller is float noise, not a rewind.
    private static let timestampEpsilon: TimeInterval = 0.001

    /// Whether `next` starts a new transcription instead of continuing `previous`.
    ///
    /// - Parameters:
    ///   - previousStart: timestamp of the first segment of the previous result.
    ///   - nextStart: the same for the new result. A recognizer that is still
    ///     refining one utterance only ever moves this forward, as leading silence
    ///     is revised away; a restart takes it back towards zero.
    public static func restarted(
        previous: String,
        next: String,
        previousStart: TimeInterval = 0,
        nextStart: TimeInterval = 0
    ) -> Bool {
        // A restart always makes the transcript shorter — it begins again from the
        // first word or two. Requiring that on its own rules out the common case of
        // the recognizer simply appending more speech.
        guard !previous.isEmpty, next.count < previous.count else { return false }

        if nextStart < previousStart - timestampEpsilon { return true }

        // Same start time, shorter text: either a revision of the tail (which keeps
        // the head intact) or a restart that happens to begin at the same offset.
        // What separates them is how much of the old text still leads the new one.
        let shared = commonPrefixCount(previous, next)
        return Double(shared) < Double(previous.count) * revisionPrefixRatio
    }

    static func commonPrefixCount(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var left = lhs.makeIterator()
        var right = rhs.makeIterator()
        while let l = left.next(), let r = right.next(), l == r {
            count += 1
        }
        return count
    }
}
