import Foundation
import Observation
import VoiceInputCore

/// Runs the active formatting style against a sample sentence so the effect of a
/// prompt is visible without dictating.
///
/// Uses the very same `FormatAction` the pipeline uses, so what the user sees here
/// is what they will get.
@MainActor
@Observable
final class FormattingTrialModel {
    static let defaultSample =
        "えーっと、明日の打ち合わせなんですけど、じゅうじからに変更したいなと思っていて、"
        + "あの、資料は前日までに共有します"

    var sample: String = FormattingTrialModel.defaultSample
    private(set) var isRunning = false
    private(set) var output: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private let providers: LLMProviderRegistry
    @ObservationIgnored private let secrets: any SecretStore

    init(providers: LLMProviderRegistry, secrets: any SecretStore) {
        self.providers = providers
        self.secrets = secrets
    }

    func run(settings: AppSettings) async {
        let text = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isRunning = true
        output = nil
        errorMessage = nil
        defer { isRunning = false }

        let provider = providers.provider(for: settings.llmProvider)
        let apiKey = provider.flatMap { try? secrets.secret(for: .apiKey(for: $0.id)) } ?? nil
        let context = ActionContext(settings: settings, llm: provider, apiKey: apiKey)
        let transcript = Transcript(
            text: text,
            locale: settings.localeIdentifier,
            duration: 0,
            engine: settings.transcriptionEngine
        )

        do {
            let outcome = try await FormatAction().run(transcript: transcript, context: context)
            output = outcome.text
        } catch {
            let wrapped = VoiceInputError.wrapping(error)
            errorMessage = wrapped.errorDescription ?? "整形に失敗しました。"
        }
    }

    func reset() {
        output = nil
        errorMessage = nil
    }
}
