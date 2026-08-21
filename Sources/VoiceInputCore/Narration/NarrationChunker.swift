import Foundation

/// Cuts a long text into pieces small enough to rewrite and speak one at a time.
///
/// Chunking is what makes the feature feel instant: the first piece can be
/// rewritten and started while the rest is still being processed, so the wait is
/// one LLM call on a paragraph rather than one on the whole article.
///
/// Cuts are taken at the strongest boundary available — a blank line first, then a
/// sentence end, and only as a last resort mid-sentence — because the join is
/// audible. A cut inside a sentence is heard as a stumble.
public struct NarrationChunker: Sendable {
    /// Ceiling for one chunk, in characters.
    ///
    /// A compromise between latency and prosody: smaller chunks start sooner but
    /// give the rewrite less context, and a rewrite that cannot see the end of the
    /// sentence it is in produces a stilted reading.
    public var maxCharacters: Int

    /// Below this, a text is left whole even if the chunker could split it: two
    /// LLM calls for four sentences buys nothing and costs a seam.
    public var minCharacters: Int

    public init(maxCharacters: Int = 1200, minCharacters: Int = 400) {
        self.maxCharacters = max(1, maxCharacters)
        self.minCharacters = minCharacters
    }

    /// Sentence terminators, both scripts. Japanese text from a chat log or a
    /// terminal mixes them freely.
    private static let sentenceTerminators: Set<Character> = [
        "。", "！", "？", "．", ".", "!", "?", "\n",
    ]

    public func chunks(of text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > max(maxCharacters, minCharacters) else { return [trimmed] }

        var chunks: [String] = []
        var current = ""

        for paragraph in Self.paragraphs(of: trimmed) {
            for piece in split(paragraph) {
                if current.isEmpty {
                    current = piece
                } else if current.count + piece.count + 2 <= maxCharacters {
                    current += "\n\n" + piece
                } else {
                    chunks.append(current)
                    current = piece
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Paragraphs, in order, with blank-line runs collapsed away.
    private static func paragraphs(of text: String) -> [String] {
        text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// One paragraph, cut down to pieces of at most `maxCharacters`.
    private func split(_ paragraph: String) -> [String] {
        guard paragraph.count > maxCharacters else { return [paragraph] }

        var pieces: [String] = []
        var current = ""

        for sentence in Self.sentences(of: paragraph) {
            if current.isEmpty {
                current = sentence
            } else if current.count + sentence.count <= maxCharacters {
                current += sentence
            } else {
                pieces.append(current)
                current = sentence
            }
            // A single sentence longer than the ceiling — a wall of log output, a
            // minified line — has no boundary to respect, so it is cut by length.
            while current.count > maxCharacters {
                let cut = current.index(current.startIndex, offsetBy: maxCharacters)
                pieces.append(String(current[current.startIndex..<cut]))
                current = String(current[cut...])
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Sentences, terminator included, so reassembling them loses nothing.
    private static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if sentenceTerminators.contains(character) {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
