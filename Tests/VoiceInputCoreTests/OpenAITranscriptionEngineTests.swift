import Foundation
import Testing

@testable import VoiceInputCore

@Suite("OpenAI transcription engine")
struct OpenAITranscriptionEngineTests {
    private func makeEngine(
        secrets: any SecretStore,
        transport: StubTransport = StubTransport()
    ) -> OpenAITranscriptionEngine {
        OpenAITranscriptionEngine(
            secrets: secrets,
            session: transport.session,
            endpoint: transport.endpoint
        )
    }

    private func keyStore(
        _ key: SecretKey = .transcriptionAPIKey(for: .openAICloud)
    )
        -> InMemorySecretStore
    {
        InMemorySecretStore([key: "sk-asr"])
    }

    @Test("identity matches the contract")
    func identity() {
        let engine = makeEngine(secrets: InMemorySecretStore())
        #expect(engine.id == .openAICloud)
        #expect(engine.supportsStreamingPartials == false)
        #expect(
            OpenAITranscriptionEngine.defaultEndpoint.absoluteString
                == "https://api.openai.com/v1/audio/transcriptions"
        )
    }

    @Test("availability reports needsAPIKey when no key is stored")
    func availabilityWithoutKey() async {
        let engine = makeEngine(secrets: InMemorySecretStore())
        let availability = await engine.availability(locale: Locale(identifier: "ja-JP"))
        #expect(availability.status == .needsAPIKey)
        #expect(availability.isUsable == false)
    }

    @Test("either the transcription key or the chat key makes it available")
    func availabilityWithKey() async {
        let locale = Locale(identifier: "ja-JP")

        let dedicated = makeEngine(secrets: keyStore())
        let dedicatedAvailability = await dedicated.availability(locale: locale)
        #expect(dedicatedAvailability.isUsable)

        let shared = makeEngine(secrets: keyStore(.apiKey(for: .openAI)))
        let sharedAvailability = await shared.availability(locale: locale)
        #expect(sharedAvailability.isUsable)
    }

    @Test("finish uploads a WAV multipart body and decodes the transcript")
    func uploadAndDecode() async throws {
        let transport = StubTransport { _ in
            (200, Data("{\"text\":\"認識されたテキスト\"}".utf8))
        }
        let engine = makeEngine(secrets: keyStore(), transport: transport)

        let configuration = TranscriptionConfiguration(
            locale: Locale(identifier: "ja-JP"),
            format: .capture,
            contextualStrings: ["Shaperon", "  "],
            model: nil
        )
        let session = try await engine.makeSession(configuration: configuration)
        await session.append(
            AudioBuffer(samples: [Float](repeating: 0.2, count: 1_600), format: .capture)
        )

        let transcript = try await session.finish()
        #expect(transcript.text == "認識されたテキスト")
        #expect(transcript.engine == .openAICloud)
        #expect(transcript.locale == "ja-JP")
        #expect(abs(transcript.duration - 0.1) < 0.001)

        let recorded = try #require(transport.recorded)
        #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-asr")
        let contentType = try #require(recorded.request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))

        let body = try #require(recorded.body)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"file\"; filename=\"audio.wav\""))
        #expect(text.contains("RIFF"))
        #expect(text.contains("name=\"model\"\r\n\r\ngpt-4o-transcribe"))
        #expect(text.contains("name=\"language\"\r\n\r\nja"))
        #expect(text.contains("name=\"prompt\"\r\n\r\nShaperon"))
        #expect(text.contains("name=\"response_format\"\r\n\r\njson"))
    }

    @Test("a configured model overrides the default")
    func modelOverride() async throws {
        let transport = StubTransport { _ in (200, Data("{\"text\":\"ok\"}".utf8)) }
        let engine = makeEngine(secrets: keyStore(.apiKey(for: .openAI)), transport: transport)

        let session = try await engine.makeSession(
            configuration: TranscriptionConfiguration(
                locale: Locale(identifier: "en-US"),
                model: "whisper-1"
            )
        )
        await session.append(AudioBuffer(samples: [0.1, 0.2, 0.3], format: .capture))
        _ = try await session.finish()

        let text = String(decoding: try #require(transport.recorded?.body), as: UTF8.self)
        #expect(text.contains("name=\"model\"\r\n\r\nwhisper-1"))
        #expect(text.contains("name=\"language\"\r\n\r\nen"))
        #expect(!text.contains("name=\"prompt\""))
    }

    @Test("no audio is an empty transcript, not an upload")
    func emptyAudio() async throws {
        let transport = StubTransport()
        let engine = makeEngine(secrets: keyStore(), transport: transport)

        let session = try await engine.makeSession(
            configuration: TranscriptionConfiguration(locale: Locale(identifier: "ja-JP"))
        )
        await #expect(throws: VoiceInputError.emptyTranscript) {
            _ = try await session.finish()
        }
        #expect(transport.recorded == nil)
    }

    @Test("an absurdly long recording is refused before upload")
    func uploadSizeGuard() async throws {
        let transport = StubTransport()
        let engine = makeEngine(secrets: keyStore(), transport: transport)

        let session = try await engine.makeSession(
            configuration: TranscriptionConfiguration(locale: Locale(identifier: "ja-JP"))
        )
        // 13 million samples -> ~26 MB of 16-bit PCM, over the 24 MB ceiling.
        await session.append(
            AudioBuffer(samples: [Float](repeating: 0, count: 13_000_000), format: .capture)
        )

        await #expect {
            _ = try await session.finish()
        } throws: { error in
            guard case let .transcriptionFailed(detail) = error as? VoiceInputError else {
                return false
            }
            return detail.contains("長すぎます")
        }
        #expect(transport.recorded == nil)
    }

    @Test("cancel discards buffered audio")
    func cancelDiscards() async throws {
        let transport = StubTransport()
        let engine = makeEngine(secrets: keyStore(), transport: transport)

        let session = try await engine.makeSession(
            configuration: TranscriptionConfiguration(locale: Locale(identifier: "ja-JP"))
        )
        await session.append(AudioBuffer(samples: [0.1, 0.2], format: .capture))
        await session.cancel()

        await #expect(throws: VoiceInputError.cancelled) {
            _ = try await session.finish()
        }
        #expect(transport.recorded == nil)
    }

    @Test("makeSession fails clearly when the key is missing")
    func makeSessionWithoutKey() async {
        let engine = makeEngine(secrets: InMemorySecretStore())
        await #expect {
            _ = try await engine.makeSession(
                configuration: TranscriptionConfiguration(locale: Locale(identifier: "ja-JP"))
            )
        } throws: { error in
            guard case let .engineUnavailable(id, _) = error as? VoiceInputError else {
                return false
            }
            return id == .openAICloud
        }
    }

    @Test("partial transcripts finish immediately — no streaming support")
    func noPartials() async throws {
        let engine = makeEngine(secrets: keyStore())
        let session = try await engine.makeSession(
            configuration: TranscriptionConfiguration(locale: Locale(identifier: "ja-JP"))
        )
        var received: [String] = []
        for await partial in session.partialTranscripts { received.append(partial) }
        #expect(received.isEmpty)
    }
}
