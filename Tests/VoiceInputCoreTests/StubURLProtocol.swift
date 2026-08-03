import Foundation

/// `URLProtocol` stub so provider tests never touch the network.
///
/// Stubs are keyed by endpoint URL rather than a single global slot, so suites
/// can keep running in parallel.
final class StubURLProtocol: URLProtocol {
    typealias Responder = (URLRequest) -> (status: Int, body: Data)

    struct Recorded {
        var request: URLRequest
        var body: Data?
    }

    private struct Entry {
        var responder: Responder
        var recorded: Recorded?
    }

    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]

    static func register(url: URL, responder: @escaping Responder) {
        lock.lock()
        defer { lock.unlock() }
        entries[url.absoluteString] = Entry(responder: responder)
    }

    static func unregister(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: url.absoluteString)
    }

    static func recorded(for url: URL) -> Recorded? {
        lock.lock()
        defer { lock.unlock() }
        return entries[url.absoluteString]?.recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        Self.lock.lock()
        var entry = Self.entries[key]
        entry?.recorded = Recorded(request: request, body: request.bodyData)
        Self.entries[key] = entry
        Self.lock.unlock()

        guard let responder = entry?.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let (status, body) = responder(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://stub.invalid")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// One stubbed endpoint plus the `URLSession` that reaches it.
final class StubTransport {
    /// What a provider is handed as its base/endpoint URL.
    let baseURL: URL
    /// The URL actually stubbed — `baseURL` plus `path`.
    let endpoint: URL
    let session: URLSession

    /// `path` is for providers that build the URL themselves (Gemini puts the model
    /// in the path), so the test asserts on the URL the provider constructed rather
    /// than one it was handed.
    init(path: String = "", respond: @escaping StubURLProtocol.Responder = { _ in (200, Data()) }) {
        baseURL = URL(string: "https://stub.invalid/\(UUID().uuidString)")!
        endpoint = path.isEmpty ? baseURL : URL(string: baseURL.absoluteString + path)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.register(url: endpoint, responder: respond)
    }

    var recorded: StubURLProtocol.Recorded? { StubURLProtocol.recorded(for: endpoint) }

    deinit { StubURLProtocol.unregister(url: endpoint) }
}

extension URLRequest {
    /// `URLSession` converts `httpBody` into a stream before it reaches a
    /// `URLProtocol`, so both shapes have to be handled.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
