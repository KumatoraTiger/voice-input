import Foundation
import Testing

@testable import VoiceInputCore

@Suite("OpenAI provider")
struct OpenAIProviderTests {
    private let request = LLMRequest(
        model: "gpt-4.1-mini",
        systemPrompt: "SYSTEM",
        messages: [.user("USER")],
        maxOutputTokens: 512,
        temperature: 0
    )

    @Test("metadata matches the Settings UI contract")
    func metadata() {
        let provider = OpenAIProvider()
        #expect(provider.id == .openAI)
        #expect(provider.defaultModel == "gpt-4.1-mini")
        #expect(provider.suggestedModels == ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini", "gpt-4o"])
        #expect(provider.apiKeyURL.absoluteString == "https://platform.openai.com/api-keys")
        #expect(
            OpenAIProvider.defaultEndpoint.absoluteString
                == "https://api.openai.com/v1/chat/completions"
        )
    }

    @Test("happy path decodes the first choice and the usage")
    func happyPath() async throws {
        let transport = StubTransport { _ in
            let body = """
                {"id":"cmpl","model":"gpt-4.1-mini",
                 "choices":[{"message":{"role":"assistant","content":"整形済みテキスト"}}],
                 "usage":{"prompt_tokens":11,"completion_tokens":7}}
                """
            return (200, Data(body.utf8))
        }
        let provider = OpenAIProvider(session: transport.session, endpoint: transport.endpoint)

        let response = try await provider.send(request, apiKey: "sk-test")

        #expect(response.text == "整形済みテキスト")
        #expect(response.inputTokens == 11)
        #expect(response.outputTokens == 7)
        #expect(response.model == "gpt-4.1-mini")

        let recorded = try #require(transport.recorded)
        #expect(recorded.request.httpMethod == "POST")
        #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(recorded.request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(recorded.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-4.1-mini")
        #expect(json["max_completion_tokens"] as? Int == 512)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"] == "SYSTEM")
        #expect(messages[1]["role"] == "user")
        #expect(messages[1]["content"] == "USER")
    }

    @Test("non-2xx maps to providerHTTPError with a truncated body")
    func httpErrorMapping() async {
        let long = String(repeating: "e", count: 5_000)
        let transport = StubTransport { _ in (429, Data(long.utf8)) }
        let provider = OpenAIProvider(session: transport.session, endpoint: transport.endpoint)

        await #expect {
            _ = try await provider.send(request, apiKey: "sk-test")
        } throws: { error in
            guard case let .providerHTTPError(name, status, body) = error as? VoiceInputError
            else { return false }
            return name == "OpenAI"
                && status == 429
                && body.count <= ProviderHTTP.maxErrorBodyLength + 1
                && body.hasSuffix("…")
        }
    }

    @Test("undecodable success body maps to providerDecodingFailed")
    func decodingFailure() async {
        let transport = StubTransport { _ in (200, Data("{\"unexpected\":true}".utf8)) }
        let provider = OpenAIProvider(session: transport.session, endpoint: transport.endpoint)

        await #expect {
            _ = try await provider.send(request, apiKey: "sk-test")
        } throws: { error in
            guard case let .providerDecodingFailed(name, _) = error as? VoiceInputError
            else { return false }
            return name == "OpenAI"
        }
    }

    @Test("an empty key fails before any request is made")
    func emptyKey() async {
        let transport = StubTransport()
        let provider = OpenAIProvider(session: transport.session, endpoint: transport.endpoint)

        await #expect(throws: VoiceInputError.missingAPIKey(.openAI)) {
            _ = try await provider.send(request, apiKey: "   ")
        }
        #expect(transport.recorded == nil)
    }
}
