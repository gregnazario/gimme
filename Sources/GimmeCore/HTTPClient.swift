import Foundation

/// Minimal HTTP client protocol so adapters can be tested with stubs (spec §6.6).
public protocol HTTPClient: Sendable {
    func data(for url: URL) async throws -> Data
}

public extension HTTPClient {
    /// Fetch a URL and return raw bytes.
    func get(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw GimmeError.network("invalid URL: \(urlString)") }
        return try await data(for: url)
    }

    /// Fetch and decode JSON.
    func getJSON<T: Decodable>(_ urlString: String, as type: T.Type) async throws -> T {
        let data = try await get(urlString)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GimmeError.network("failed to decode JSON from \(urlString): \(error)")
        }
    }
}

/// Production client backed by URLSession.
/// `@unchecked`: NSObject subclasses cannot synthesize Sendable; the
/// session reference is an immutable let (URLSession is Sendable).
public final class URLSessionHTTPClient: NSObject, HTTPClient, @unchecked Sendable {
    private let session: URLSession

    /// Outdated checks fan out one registry request per installed package
    /// (100+ for gem-heavy machines); `URLSession.shared` caps ~6 connections
    /// per host and serializes the fan-out in waves. Registries are CDNs —
    /// raise the cap so a cold pass runs at network latency, not queue latency.
    public static let registrySession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: config)
    }()

    public init(session: URLSession = URLSessionHTTPClient.registrySession) {
        self.session = session
    }

    public func data(for url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw GimmeError.network("HTTP \(http.statusCode) for \(url.absoluteString)")
            }
            return data
        } catch let e as GimmeError {
            throw e
        } catch {
            throw GimmeError.network("request failed for \(url.absoluteString): \(error)")
        }
    }
}
