import Foundation

/// Reduces raw OCR output to a short list of candidate spellings.
///
/// Two jobs, and the second one is a security control:
///
/// 1. Keep the words a speech recogniser is likely to get wrong — product names,
///    identifiers, proper nouns — and drop ordinary vocabulary, which only makes
///    the prompt longer and the model more suggestible.
/// 2. Guarantee every surviving term is an **isolated token**: no whitespace,
///    bounded length, no URL or path shape. An instruction needs a sentence to
///    exist; this filter makes sentences unrepresentable in its output. That is
///    the reason the rest of the pipeline can treat screen terms as comparatively
///    safe — see `ScreenContext` for the whole argument.
public struct ScreenTermExtractor: Sendable {
    /// Upper bound on the pool, and **only** a bound on memory and comparison
    /// cost — not a relevance filter.
    ///
    /// It cannot be one: extraction runs when recording starts, so there is no
    /// transcript yet and nothing to judge relevance against. Ranking is by
    /// frequency, which is close to the opposite of what matters — a real window
    /// is mostly chrome, repeated, while the proper noun being dictated appears
    /// once. A tight cap therefore drops exactly the words the feature exists
    /// for, before `ScreenTermMatcher` — the one stage that knows what was said
    /// — can see them. So the pool stays wide and the narrowing happens there;
    /// what reaches the prompt is capped by the matcher, not here.
    public var limit: Int
    /// Longer than this and it is not a word anyone dictated.
    public var maximumLength: Int

    public init(limit: Int = 400, maximumLength: Int = 30) {
        self.limit = limit
        self.maximumLength = maximumLength
    }

    public func terms(from lines: [String]) -> [String] {
        var order: [String: Int] = [:]
        var counts: [String: Int] = [:]
        var next = 0

        for run in lines.flatMap({ ScreenTextScanner.runs(in: $0) }) {
            guard accepts(run) else { continue }
            let term = run.text
            if order[term] == nil {
                order[term] = next
                next += 1
            }
            counts[term, default: 0] += 1
        }

        return
            order.keys
            .sorted {
                let left = counts[$0] ?? 0
                let right = counts[$1] ?? 0
                if left != right { return left > right }
                return (order[$0] ?? 0) < (order[$1] ?? 0)
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - The filter

    private func accepts(_ run: ScreenTextScanner.Run) -> Bool {
        let text = run.text
        let length = text.count
        guard length >= 2, length <= maximumLength else { return false }

        switch run.script {
        case .hiragana:
            // Grammar, not vocabulary. Recognisers already handle it.
            return false
        case .katakana:
            // Loanwords and product names — the single most useful class here.
            return length >= 3
        case .han:
            // Two to six characters covers names and compounds; longer runs are
            // usually a whole clause the segmenter failed to split.
            return length <= 6
        case .latin:
            return acceptsLatin(text)
        case .separator:
            return false
        }
    }

    private func acceptsLatin(_ text: String) -> Bool {
        let characters = Array(text)
        guard characters.contains(where: { $0.isLetter }) else { return false }
        guard !Self.stopWords.contains(text.lowercased()) else { return false }

        let digits = characters.filter(\.isNumber).count

        // The shape of an API key, a hash or a UUID fragment. Never a dictated
        // word, and exactly the sort of thing that must not reach a provider.
        if characters.count >= 16, digits > 0 { return false }

        let hasInnerUppercase = characters.dropFirst().contains(where: \.isUppercase)
        let isAllCaps = characters.allSatisfy { !$0.isLetter || $0.isUppercase }
        let startsUppercase = characters.first?.isUppercase == true

        // camelCase / PascalCase, SCREAMING_CASE, snake_case, name2 — the shapes a
        // recogniser has no chance with. A capitalised word is worth keeping too;
        // an all-lowercase ordinary word is not.
        return hasInnerUppercase
            || isAllCaps
            || text.contains("_")
            || digits > 0
            || startsUppercase
    }

    /// Small on purpose. Its job is to stop sentence-initial words such as "The"
    /// from passing the capitalised-word rule, not to be a real stop list.
    static let stopWords: Set<String> = [
        "the", "this", "that", "these", "those", "and", "but", "for", "with",
        "from", "into", "over", "under", "when", "what", "where", "which", "who",
        "you", "your", "our", "their", "they", "there", "here", "then", "than",
        "some", "more", "most", "only", "also", "are", "was", "were", "not",
        "can", "will", "have", "has", "its", "all", "any", "new", "open", "save",
        "close", "edit", "view", "help", "file", "home", "page", "done", "cancel",
        "search", "settings", "about", "yes", "add", "get", "set", "see",
    ]
}
