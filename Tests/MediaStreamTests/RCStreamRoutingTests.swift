import XCTest
@testable import MediaStream

/// Stub transport: hosts listed in `failingHosts` fail at the transport
/// layer; `notFoundHosts` answer 404; everything else answers 200 with the
/// host name as the body.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var failingHosts: Set<String> = []
    nonisolated(unsafe) static var notFoundHosts: Set<String> = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        if Self.failingHosts.contains(host) {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let status = Self.notFoundHosts.contains(host) ? 404 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(host.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RCStreamRoutingTests: XCTestCase {

    private var session: URLSession!
    private var failures: [String] = []
    private let lock = NSLock()

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: config)
        StubProtocol.failingHosts = []
        StubProtocol.notFoundHosts = []
        failures = []
        RCStreamRouting.candidates = { url in
            ["lan", "cloud"].map { host in
                var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                c.host = host
                return c.url!
            }
        }
        RCStreamRouting.reportFailure = { [weak self] url in
            guard let self else { return }
            self.lock.lock(); self.failures.append(url.host ?? ""); self.lock.unlock()
        }
    }

    override func tearDown() {
        RCStreamRouting.candidates = nil
        RCStreamRouting.reportFailure = nil
        RCStreamRouting.reportSuccess = nil
        super.tearDown()
    }

    func testResolveWithoutHookIsIdentity() {
        RCStreamRouting.candidates = nil
        let url = URL(string: "https://127.0.0.1:1/x")!
        XCTAssertEqual(RCStreamRouting.resolve(url), [url])
    }

    func testEmptyHookResultFallsBackToOriginal() {
        RCStreamRouting.candidates = { _ in [] }
        let url = URL(string: "https://127.0.0.1:1/x")!
        XCTAssertEqual(RCStreamRouting.resolve(url), [url])
    }

    func testFirstCandidateServesWhenHealthy() async throws {
        let (data, _) = try await RCStreamRouting.data(
            for: URLRequest(url: URL(string: "https://origin/file")!), session: session)
        XCTAssertEqual(String(data: data, encoding: .utf8), "lan")
        XCTAssertTrue(failures.isEmpty)
    }

    func testTransportFailureFailsOverAndReports() async throws {
        StubProtocol.failingHosts = ["lan"]
        let (data, _) = try await RCStreamRouting.data(
            for: URLRequest(url: URL(string: "https://origin/file")!), session: session)
        XCTAssertEqual(String(data: data, encoding: .utf8), "cloud")
        XCTAssertEqual(failures, ["lan"])
    }

    func testHTTPErrorFailsOver() async throws {
        // A partial mirror answers 404 for a file it doesn't hold.
        StubProtocol.notFoundHosts = ["lan"]
        let (data, _) = try await RCStreamRouting.data(
            for: URLRequest(url: URL(string: "https://origin/file")!), session: session)
        XCTAssertEqual(String(data: data, encoding: .utf8), "cloud")
        XCTAssertEqual(failures, ["lan"])
    }

    func testAllCandidatesFailingThrows() async {
        StubProtocol.failingHosts = ["lan", "cloud"]
        do {
            _ = try await RCStreamRouting.data(
                for: URLRequest(url: URL(string: "https://origin/file")!), session: session)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(failures, ["lan", "cloud"])
        }
    }
}
