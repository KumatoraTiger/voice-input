import Foundation
import Testing

@testable import VoiceInputCore

@Suite("Anthropic provider")
struct AnthropicProviderTests {
    private func request(model: String = "claude-haiku-4-5") -> LLMRequest {
        LLMRequest(
            model: model,
            systemPrompt: "SYSTEM",
            messages: [.user("USER")],
            maxOutputTokens: 512,
            temperature: 0
        )
    }

    @Test("metadata matches the Settings UI contract")
    func metadata() {
        let provider = AnthropicProvider()
        #expect(provider.id == .anthropic)
        #expect(provider.defaultModel == "claude-haiku-4-5")
        #expect(provider.suggestedModels.first == "claude-haiku-4-5")
        #expect(
            provider.apiKeyURL.absoluteString == "https://console.anthropic.com/settings/keys"
        )
        #expect(
            AnthropicProvider.defaultEndpoint.absoluteString
                == "https://api.anthropic.com/v1/messages"
        )
        #expect(AnthropicProvider.apiVersion == "2023-06-01")
    }

    @Test("happy path concatenates text blocks and reads usage")
    func happyPath() async throws {
        let transport = StubTransport { _ in
            let body = """
                {"id":"msg_1","model":"claude-haiku-4-5","role":"assistant",
                 "content":[{"type":"text","text":"整形済み"},{"type":"text","text":"テキスト"}],
                 "usage":{"input_tokens":21,"output_tokens":9}}
                """
            return (200, Data(body.utf8))
        }
        let provider = AnthropicProvider(session: transport.session, endpoint: transport.endpoint)

        let response = try await provider.send(request(), apiKey: "sk-ant-test")

        #expect(response.text == "整形済みテキスト")
        #expect(response.inputTokens == 21)
        #expect(response.outputTokens == 9)

        let recorded = try #require(transport.recorded)
        #expect(recorded.request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(recorded.request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        // The key must never be sent as a bearer token to this endpoint.
        #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == nil)

        let body = try #require(recorded.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-haiku-4-5")
        #expect(json["max_tokens"] as? Int == 512)
        #expect(json["system"] as? String == "SYSTEM")
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "USER"]])
    }

    @Test("temperature is dropped on models that reject sampling parameters")
    func samplingParameterGate() async throws {
        let transport = StubTransport { _ in
            (200, Data("{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}".utf8))
        }
        let provider = AnthropicProvider(session: transport.session, endpoint: transport.endpoint)

        _ = try await provider.send(request(model: "claude-opus-5"), apiKey: "sk-ant-test")
        let body = try #require(transport.recorded?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["temperature"] == nil)

        #expect(AnthropicProvider.supportsSamplingParameters(model: "claude-haiku-4-5"))
        #expect(!AnthropicProvider.supportsSamplingParameters(model: "claude-sonnet-5"))
        #expect(!AnthropicProvider.supportsSamplingParameters(model: "claude-opus-4-8"))
    }

    @Test("temperature is sent for models that still accept it")
    func temperatureSent() async throws {
        let transport = StubTransport { _ in
            (200, Data("{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}".utf8))
        }
        let provider = AnthropicProvider(session: transport.session, endpoint: transport.endpoint)

        _ = try await provider.send(request(), apiKey: "sk-ant-test")
        let body = try #require(transport.recorded?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["temperature"] as? Double == 0)
    }

    @Test("non-2xx maps to providerHTTPError")
    func httpErrorMapping() async {
        let transport = StubTransport { _ in
            (401, Data("{\"error\":{\"message\":\"invalid x-api-key\"}}".utf8))
        }
        let provider = AnthropicProvider(session: transport.session, endpoint: transport.endpoint)

        await #expect {
            _ = try await provider.send(request(), apiKey: "sk-ant-test")
        } throws: { error in
            guard case let .providerHTTPError(name, status, body) = error as? VoiceInputError
            else { return false }
            return name == "Anthropic" && status == 401 && body.contains("invalid x-api-key")
        }
    }

    @Test("a response with no text block maps to providerDecodingFailed")
    func noTextBlock() async {
        let transport = StubTransport { _ in
            (200, Data("{\"content\":[{\"type\":\"thinking\"}]}".utf8))
        }
        let provider = AnthropicProvider(session: transport.session, endpoint: transport.endpoint)

        await #expect {
            _ = try await provider.send(request(), apiKey: "sk-ant-test")
        } throws: { error in
            guard case let .providerDecodingFailed(name, _) = error as? VoiceInputError
            else { return false }
            return name == "Anthropic"
        }
    }

    @Test("an empty key fails before any request is made")
    func emptyKey() async {
        let transport = StubTransport()
        let provider = AnthropicProvider(session: transport.session, endpoint: transport.endpoint)

        await #expect(throws: VoiceInputError.missingAPIKey(.anthropic)) {
            _ = try await provider.send(request(), apiKey: "")
        }
        #expect(transport.recorded == nil)
    }
}
