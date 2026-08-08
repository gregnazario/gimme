import XCTest
@testable import GimmeCore

final class HTTPClientTests: XCTestCase {
    /// A test double that returns canned bytes for a given URL.
    final class StubHTTPClient: HTTPClient {
        var responses: [String: Data] = [:]
        func data(for url: URL) async throws -> Data {
            responses[url.absoluteString] ?? Data()
        }
    }

    func testGetReturnsStubbedData() async throws {
        let stub = StubHTTPClient()
        stub.responses["https://example.com/x"] = Data("[1,2,3]".utf8)
        let data = try await stub.get("https://example.com/x")
        XCTAssertEqual(String(data: data, encoding: .utf8), "[1,2,3]")
    }

    func testGetJSONDecodes() async throws {
        struct Body: Decodable, Equatable { let name: String }
        let stub = StubHTTPClient()
        stub.responses["https://example.com/p"] = Data(#"{"name":"ripgrep"}"#.utf8)
        let body: Body = try await stub.getJSON("https://example.com/p", as: Body.self)
        XCTAssertEqual(body, Body(name: "ripgrep"))
    }

    func testRealClientIsHTTPClient() {
        let _: HTTPClient = URLSessionHTTPClient()
    }
}
