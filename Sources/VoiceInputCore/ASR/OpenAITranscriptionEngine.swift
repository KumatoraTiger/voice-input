import Foundation

/// Cloud speech-to-text over `POST /v1/audio/transcriptions`.
///
/// The whole recording is buffered in memory, encoded as 16-bit PCM WAV and
/// uploaded on `finish()`; there are no partial results.
public struct OpenAITranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    public static let defaultEndpoint =
        URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    public static let defaultModel = "gpt-4o-transcribe"

    /// Refuse absurd uploads rather than letting the request fail opaquely
    /// after a long wait. 24 MB of 16 kHz mono PCM is ~13 minutes of speech.
    public static let maxUploadBytes = 24 * 1024 * 1024

    public let id: TranscriptionEngineID = .openAICloud
    public let displayName = "OpenAI (クラウド)"
    public let supportsStreamingPartials = false

    private let session: URLSession
    private let endpoint: URL
    private let secrets: any SecretStore

    public init(
        secrets: any SecretStore,
        session: URLSession = .shared,
        endpoint: URL = OpenAITranscriptionEngine.defaultEndpoint
    ) {
        self.secrets = secrets
        self.session = session
        self.endpoint = endpoint
    }

    public func availability(locale: Locale) async -> EngineAvailability {
        guard apiKey() != nil else {
            return EngineAvailability(
                status: .needsAPIKey,
                detail: "OpenAI の API キーが必要です。"
            )
        }
        return .available
    }

    public func makeSession(
        configuration: TranscriptionConfiguration
    ) async throws -> any TranscriptionSession {
        guard let key = apiKey() else {
            throw VoiceInputError.engineUnavailable(id, "OpenAI の API キーが設定されていません。")
        }
        return Session(
            configuration: configuration,
            apiKey: key,
            session: session,
            endpoint: endpoint
        )
    }

    /// The transcription key is stored separately so a user can use Anthropic
    /// for formatting and OpenAI only for speech; fall back to the chat key.
    private func apiKey() -> String? {
        let candidates: [SecretKey] = [
            .transcriptionAPIKey(for: .openAICloud),
            .apiKey(for: .openAI),
        ]
        for candidate in candidates {
            guard let value = try? secrets.secret(for: candidate) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - Session

    actor Session: TranscriptionSession {
        nonisolated let partialTranscripts: AsyncStream<String>

        private let configuration: TranscriptionConfiguration
        private let apiKey: String
        private let session: URLSession
        private let endpoint: URL

        private var samples: [Float] = []
        private var isCancelled = false

        init(
            configuration: TranscriptionConfiguration,
            apiKey: String,
            session: URLSession,
            endpoint: URL
        ) {
            self.configuration = configuration
            self.apiKey = apiKey
            self.session = session
            self.endpoint = endpoint
            // Cloud transcription has no partials; finish the stream immediately
            // so any UI consumer terminates rather than hanging.
            self.partialTranscripts = AsyncStream { $0.finish() }
        }

        func append(_ buffer: AudioBuffer) async {
            guard !isCancelled else { return }
            samples.append(contentsOf: buffer.samples)
        }

        func cancel() async {
            isCancelled = true
            samples.removeAll()
        }

        func finish() async throws -> Transcript {
            if isCancelled { throw VoiceInputError.cancelled }

            let format = configuration.format
            let duration =
                format.sampleRate > 0 && format.channelCount > 0
                ? Double(samples.count) / (format.sampleRate * Double(format.channelCount))
                : 0
            guard !samples.isEmpty else { throw VoiceInputError.emptyTranscript }

            let wav = WAVEncoder.encode(samples: samples, format: format)
            guard wav.count <= OpenAITranscriptionEngine.maxUploadBytes else {
                let mb = Double(wav.count) / 1_048_576
                throw VoiceInputError.transcriptionFailed(
                    String(
                        format: "録音が長すぎます (%.1f MB)。%d MB 以下に分けて録音してください。",
                        mb,
                        OpenAITranscriptionEngine.maxUploadBytes / 1_048_576
                    )
                )
            }

            let boundary = "voiceinput-\(UUID().uuidString)"
            var body = MultipartBody(boundary: boundary)
            body.appendFile(
                name: "file",
                filename: "audio.wav",
                contentType: "audio/wav",
                data: wav
            )
            body.appendField(
                name: "model", value: configuration.model ?? OpenAITranscriptionEngine.defaultModel)
            if let language = configuration.locale.language.languageCode?.identifier {
                body.appendField(name: "language", value: language)
            }
            let context = configuration.contextualStrings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !context.isEmpty {
                body.appendField(name: "prompt", value: context.joined(separator: ", "))
            }
            body.appendField(name: "response_format", value: "json")

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(
                "multipart/form-data; boundary=\(boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = body.finalized()

            let data = try await ProviderHTTP.send(
                request,
                session: session,
                provider: "OpenAI"
            )
            let decoded = try ProviderHTTP.decode(
                TranscriptionResponse.self,
                from: data,
                provider: "OpenAI"
            )

            let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw VoiceInputError.emptyTranscript }

            return Transcript(
                text: text,
                locale: configuration.locale.identifier,
                duration: duration,
                engine: .openAICloud
            )
        }

        private struct TranscriptionResponse: Decodable {
            let text: String
        }
    }
}

/// Minimal `multipart/form-data` writer.
struct MultipartBody {
    private let boundary: String
    private var data = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    mutating func appendField(name: String, value: String) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        data.append(Data("\(value)\r\n".utf8))
    }

    mutating func appendFile(
        name: String, filename: String, contentType: String, data fileData: Data
    ) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(
            Data(
                "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                    .utf8
            )
        )
        data.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))
    }

    func finalized() -> Data {
        var copy = data
        copy.append(Data("--\(boundary)--\r\n".utf8))
        return copy
    }
}
