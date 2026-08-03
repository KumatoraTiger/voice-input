import Foundation

/// Shared HTTP plumbing for the cloud providers.
///
/// Kept internal so each provider stays a thin description of its own wire
/// format. Never logs the request body or the API key.
enum ProviderHTTP {
    /// Providers echo request text back in error bodies, so responses are
    /// truncated before they can reach the UI or a log.
    static let maxErrorBodyLength = 500

    static func send(
        _ request: URLRequest,
        session: URLSession,
        provider: String
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw VoiceInputError.networkFailure(error.localizedDescription)
        } catch is CancellationError {
            throw VoiceInputError.cancelled
        } catch {
            throw VoiceInputError.networkFailure(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw VoiceInputError.networkFailure("HTTP レスポンスを取得できませんでした。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VoiceInputError.providerHTTPError(
                provider: provider,
                status: http.statusCode,
                body: truncate(data)
            )
        }
        return data
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        provider: String
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw VoiceInputError.providerDecodingFailed(
                provider: provider,
                detail: error.localizedDescription
            )
        }
    }

    static func truncate(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"
        let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= maxErrorBodyLength { return collapsed }
        return String(collapsed.prefix(maxErrorBodyLength)) + "…"
    }
}
