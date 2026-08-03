import Foundation

extension FormattingStyle {
    // Fixed UUIDs: built-in styles must keep the same identity across launches so a
    // user's `activeStyleID` still resolves after an app update.
    public static let standardID = UUID(uuidString: "1B2E1B2E-0000-4000-8000-000000000001")!
    public static let messageID = UUID(uuidString: "1B2E1B2E-0000-4000-8000-000000000002")!
    public static let verbatimID = UUID(uuidString: "1B2E1B2E-0000-4000-8000-000000000003")!

    public static let builtIns: [FormattingStyle] = [
        FormattingStyle(
            id: standardID,
            name: "標準",
            instructions: """
                読みやすい書き言葉に整える。話し言葉特有の冗長さ（「〜という感じで」
                「〜みたいな」「〜のほう」など）は削る。
                文体は文章全体で統一する。大半が「です・ます」なら「です・ます」に、
                「だ・である」なら「だ・である」に揃える。
                段落は内容の切れ目で分ける。箇条書きが自然な内容であれば箇条書きにしてよい。
                """,
            isBuiltIn: true
        ),
        FormattingStyle(
            id: messageID,
            name: "チャット向け",
            instructions: """
                Slack や短いメッセージ向けに、簡潔で丁寧な口調に整える。
                挨拶や前置きは話者が言っていない限り追加しない。1〜3 段落程度に収める。
                """,
            isBuiltIn: true
        ),
        FormattingStyle(
            id: verbatimID,
            name: "最小限",
            instructions: """
                言い回しは変えない。フィラー（えー、あの、など）の除去、句読点、改行、
                明らかな認識ミスの修正、言い直しの反映、表記の口頭説明の反映のみ行う。
                文体は話者が話したまま（です・ます／だ・である）を保つ。
                """,
            isBuiltIn: true
        ),
    ]
}
