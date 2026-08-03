import Foundation
import Testing

@testable import VoiceInputCore

@Suite("Gemini provider")
struct GeminiProviderTests {
    private static let defaultModel = "gemini-3.5-flash-lite"

    private func request(model: String = GeminiProviderTests.defaultModel) -> LLMRequest {
        LLMRequest(
            model: model,
            systemPrompt: "SYSTEM",
            messages: [.user("USER")],
            maxOutputTokens: 512,
            temperature: 0
        )
    }

    private func path(for model: String) -> String {
        "/models/\(model):generateContent"
    }

    @Test("metadata matches the Settings UI contract")
    func metadata() {
        let provider = GeminiProvider()
        #expect(provider.id == .gemini)
        #expect(provider.displayName == "Google Gemini")
        #expect(provider.defaultModel == Self.defaultModel)
        #expect(provider.suggestedModels.first == Self.defaultModel)
        #expect(provider.apiKeyURL.absoluteString == "https://aistudio.google.com/apikey")
        #expect(
            GeminiProvider.defaultBaseURL.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta"
        )
    }

    @Test("the model goes in the URL path, and the key in the x-goog-api-key header")
    func requestShape() async throws {
        let transport = StubTransport(path: path(for: Self.defaultModel)) { _ in
            let body = """
                {"candidates":[{"content":{"role":"model","parts":[{"text":"整形済み"},
                 {"text":"テキスト"}]},"finishReason":"STOP"}],
                 "usageMetadata":{"promptTokenCount":21,"candidatesTokenCount":9},
                 "modelVersion":"gemini-3.5-flash-lite"}
                """
            return (200, Data(body.utf8))
        }
        let provider = GeminiProvider(session: transport.session, baseURL: transport.baseURL)

        let response = try await provider.send(request(), apiKey: "test-key")

        #expect(response.text == "整形済みテキスト")
        #expect(response.inputTokens == 21)
        #expect(response.outputTokens == 9)
        #expect(response.model == "gemini-3.5-flash-lite")

        let recorded = try #require(transport.recorded)
        #expect(recorded.request.url?.absoluteString == transport.endpoint.absoluteString)
        #expect(recorded.request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        // The key must never be sent as a bearer token, and never in the query
        // string — a secret in a URL ends up in logs.
        #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(recorded.request.url?.query == nil)
    }

    @Test("the system prompt stays in systemInstruction, the transcript in a user turn")
    func systemUserSeparation() async throws {
        let transport = StubTransport(path: path(for: Self.defaultModel)) { _ in
            (200, Data("{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]}}]}".utf8))
        }
        let provider = GeminiProvider(session: transport.session, baseURL: transport.baseURL)

        _ = try await provider.send(request(), apiKey: "test-key")

        let body = try #require(transport.recorded?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        let system = try #require(json["systemInstruction"] as? [String: Any])
        let systemParts = try #require(system["parts"] as? [[String: String]])
        #expect(systemParts == [["text": "SYSTEM"]])
        // systemInstruction has no turn, so it must not carry a role.
        #expect(system["role"] == nil)

        let contents = try #require(json["contents"] as? [[String: Any]])
        #expect(contents.count == 1)
        #expect(contents[0]["role"] as? String == "user")
        let parts = try #require(contents[0]["parts"] as? [[String: String]])
        #expect(parts == [["text": "USER"]])

        // The model belongs in the path, not the body.
        #expect(json["model"] == nil)

        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["maxOutputTokens"] as? Int == 512)
    }

    @Test("an assistant message is sent as the model role")
    func assistantRole() async throws {
        let transport = StubTransport(path: path(for: Self.defaultModel)) { _ in
            (200, Data("{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]}}]}".utf8))
        }
        let provider = GeminiProvider(session: transport.session, baseURL: transport.baseURL)

        _ = try await provider.send(
            LLMRequest(
                model: Self.defaultModel,
                messages: [.user("A"), .init(role: .assistant, content: "B")]
            ),
            apiKey: "test-key"
        )

        let body = try #require(transport.recorded?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try #require(json["contents"] as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["user", "model"])
        #expect(GeminiProvider.role(for: .assistant) == "model")
        #expect(GeminiProvider.role(for: .user) == "user")
    }

    @Test("Gemini 3 drops temperature and asks for minimal thinking")
    func geminiThreeGates() async throws {
        let transport = StubTransport(path: path(for: "gemini-3.6-flash")) { _ in
            (200, Data("{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]}}]}".utf8))
        }
        let provider = GeminiProvider(session: transport.session, baseURL: transport.baseURL)

        _ = try await provider.send(request(model: "gemini-3.6-flash"), apiKey: "test-key")

        let body = try #require(transport.recorded?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["temperature"] == nil)
        let thinking = try #require(config["thinkingConfig"] as? [String: Any])
        #expect(thinking["thinkingLevel"] as? String == "minimal")

        #expect(!GeminiProvider.supportsSamplingParameters(model: "gemini-3.5-flash-lite"))
        #expect(GeminiProvider.supportsThinkingLevel(model: "gemini-3.5-flash"))
    }

    @Test("older models keep temperature and are sent no thinkingConfig")
    func legacyModelGates() async throws {
        let transport = StubTransport(path: path(for: "gemini-2.5-flash")) { _ in
            (200, Data("{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]}}]}".utf8))
        }
        let provider = GeminiProvider(session: transport.session, baseURL: transport.baseURL)

        _ = try await provider.send(request(model: "gemini-2.5-flash"), apiKey: "test-key")

        let body = try #require(transport.recorded?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["temperature"] as? Double == 0)
        // `thinkingLevel` does not exist on 2.x, which would reject the request.
        #expect(config["thinkingConfig"] == nil)

        #expect(GeminiProvider.supportsSamplingParameters(model: "gemini-2.5-flash"))
        #expect(!GeminiProvider.supportsThinkingLevel(model: "gemini-2.5-flash"))
    }

    @Test("a fully qualified models/ name is not doubled in the path")
    func qualifiedModelName() {
        let base = URL(string: "https://example.invalid/v1beta")!
        let expected = "https://example.invalid/v1beta/models/gemini-3.5-flash:generateContent"
        #expect(GeminiProvider.endpoint(base: base, model: "gemini-3.5-flash")?.absoluteString
            == expected)
        #expect(
            GeminiProvider.endpoint(base: base, model: "models/gemini-3.5-flash")?.absoluteString
                == expected)
        #expect(
            GeminiProvider.endpoint(base: base, model: " gemini-3.5-flash ")?.absoluteString
                == expected)
        // A trailing slash on the base must not produce a doubled separator.
        #expect(
            GeminiProvider.endpoint(
                base: URL(string: "https://example.invalid/v1beta/")!,
                model: "gemini-3.5-flash"
            )?.absoluteString == expected)
        #expect(GeminiProvider.endpoint(base: base, model: "   ") == nil)
    }

    @Test("a blank model falls back to the default rather than building a bad URL")
    func blankModelFallsBack() async throws {
        let transport = StubTransport(path: path(for: Self.defaultModel)) { _ in
            (200, Data("{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]}}]}".utf8))
        }
        let provider = GeminiProvider(session: transport.session, baseURL: transport.baseURL)

        let response = try await provider.send(
            LLMRequest(model: "  ", messages: [.user("USER")]),
            apiKey: "test-key"
        )
        #expect(response.text == "ok")
    }

    @Test("non-2xx maps to providerHTTPError")
    func httpErrorMapping() async {
        let transport = StubTransport(path: path(for: Self.defaultModel)) { _ in
            (400, Data("{\"error\":{\"message\":\"API key not valid\"}}".utf8))
        }
        let provider = GeminiProvider(session: transport.session, baseURL: transport.baseURL)

        await #expect {
            _ = try await provider.send(request(), apiKey: "test-key")
        } throws: { error in
            guard case let .providerHTTPError(name, status, body) = error as? VoiceInputError
            else { return false }
            return name == "Google Gemini" && status == 400 && body.contains("API key not valid")
        }
    }

    @Test("a thinking-only candidate reports its finishReason")
    func noTextPart() async {
        let transport = StubTransport(path: path(for: Self.defaultModel)) { _ in
            (200, Data("{\"candidates\":[{\"content\":{},\"finishReason\":\"MAX_TOKENS\"}]}".utf8))
        }
        let provider = GeminiProvider(session: transport.session, baseURL: transport.baseURL)

        await #expect {
            _ = try await provider.send(request(), apiKey: "test-key")
        } throws: { error in
            guard case let .providerDecodingFailed(name, detail) = error as? VoiceInputError
            else { return false }
            return name == "Google Gemini" && detail.contains("MAX_TOKENS")
        }
    }

    @Test("an empty candidate list maps to providerDecodingFailed")
    func noCandidates() async {
        let transport = StubTransport(path: path(for: Self.defaultModel)) { _ in
            (200, Data("{\"candidates\":[]}".utf8))
        }
        let provider = GeminiProvider(session: transport.session, baseURL: transport.baseURL)

        await #expect {
            _ = try await provider.send(request(), apiKey: "test-key")
        } throws: { error in
            guard case let .providerDecodingFailed(name, _) = error as? VoiceInputError
            else { return false }
            return name == "Google Gemini"
        }
    }

    @Test("malformed JSON maps to providerDecodingFailed")
    func malformedJSON() async {
        let transport = StubTransport(path: path(for: Self.defaultModel)) { _ in
            (200, Data("not json".utf8))
        }
        let provider = GeminiProvider(session: transport.session, baseURL: transport.baseURL)

        await #expect {
            _ = try await provider.send(request(), apiKey: "test-key")
        } throws: { error in
            guard case let .providerDecodingFailed(name, _) = error as? VoiceInputError
            else { return false }
            return name == "Google Gemini"
        }
    }

    @Test("an empty key fails before any request is made")
    func emptyKey() async {
        let transport = StubTransport(path: path(for: Self.defaultModel))
        let provider = GeminiProvider(session: transport.session, baseURL: transport.baseURL)

        await #expect(throws: VoiceInputError.missingAPIKey(.gemini)) {
            _ = try await provider.send(request(), apiKey: "")
        }
        #expect(transport.recorded == nil)
    }
}
