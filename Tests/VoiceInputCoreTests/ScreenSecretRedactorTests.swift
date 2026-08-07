import Foundation
import Testing

@testable import VoiceInputCore

@Suite("Screen secret redaction")
struct ScreenSecretRedactorTests {
    private let redactor = ScreenSecretRedactor()

    /// Shapes, not real prefixes: the filter keys on a long run mixing letters and
    /// digits, so the fixtures avoid looking like live keys in a public repository.
    @Test("key-shaped runs are blanked out")
    func redactsKeyShapes() {
        // The token shapes are assembled from pieces so the fixture cannot read as a
        // live credential — `Scripts/check_secrets.sh` rejects the literal forms, and
        // it is right to.
        let jwtLike = "notAReal" + "1234" + "PayloadNotAReal5678"
        let text = """
            export TOKEN=NotARealKey1234NotAReal5678
            header \(jwtLike)
            card 4242424242424242
            """
        let redacted = redactor.redact(text)

        #expect(!redacted.contains("NotARealKey1234NotAReal5678"))
        #expect(!redacted.contains("4242424242424242"))
        #expect(!redacted.contains(jwtLike))
        #expect(redacted.contains(ScreenSecretRedactor.placeholder))
    }

    /// A real key comes apart at its punctuation, and the high-entropy piece is what
    /// gets tested. The readable prefix surviving is fine — and useful, because the
    /// user can see from the prompt shape that something was blanked.
    @Test("a punctuated key loses its secret half")
    func redactsAcrossPunctuation() {
        let secret = "Ab3Cd4Ef5Gh6Ij7Kl8Mn9Op0"
        let redacted = redactor.redact("token-part-\(secret)")

        #expect(!redacted.contains(secret))
        #expect(redacted.contains("token-part-"))
    }

    /// The strings that actually turned up in this project's own screen reads.
    /// Redacting any of them would remove the corrections the feature exists for.
    @Test("the identifiers on a working screen survive")
    func keepsOrdinaryIdentifiers() {
        let kept = [
            "DATABASE_CONNECTION_TIMEOUT", "ScreenCaptureKit", "SCContentFilter",
            "user_id", "created_at", "is_active", "retry_count", "max_length",
            "ProjectAurora", "VoiceInput", "Kubernetes", "PostgreSQL", "SQL", "URL",
            "gpt-4o-transcribe", "claude-sonnet-5", "v1", "v2", "2534",
            "Terraform", "SwiftPM",
        ]

        for term in kept {
            #expect(redactor.redact(term) == term, "\(term) should survive")
        }
    }

    @Test("Japanese text is untouched")
    func keepsJapanese() {
        let text = "管理画面の判定は、データベースが記録します。"
        #expect(redactor.redact(text) == text)
    }

    @Test("dates, prices and version numbers are not account numbers")
    func keepsShortDigitRuns() {
        for term in ["20260807", "1234567890", "4096", "3600"] {
            #expect(redactor.redact(term) == term, "\(term) should survive")
        }
    }

    /// Stated so the limit is visible in the suite rather than only in prose: this
    /// narrows one class of exposure and leaves the larger one alone.
    @Test("prose is not redacted — the exposure this does not address")
    func doesNotRedactProse() {
        let text = "管理者パスワードは共有ドライブに置いてあります"
        #expect(redactor.redact(text) == text)
    }
}
