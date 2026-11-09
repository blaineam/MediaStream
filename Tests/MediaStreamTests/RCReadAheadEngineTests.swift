import XCTest
@testable import MediaStream

/// Serves a deterministic file over byte ranges. Hosts in `failingHosts`
/// refuse to connect; hosts in `dieAfter` drop the connection after that many
/// bytes of a response. Records every request.
private final class RangeStubProtocol: URLProtocol {
    static let fileSize = 1 << 20
    static let file = Data((0..<fileSize).map { UInt8($0 % 251) })

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _failingHosts: Set<String> = []
    nonisolated(unsafe) private static var _dieAfter: [String: Int] = [:]
    nonisolated(unsafe) private static var _requests: [(host: String, range: String, path: String)] = []
    nonisolated(unsafe) private static var _chunkDelay: TimeInterval = 0

    /// `chunkDelay` paces each 64 KB chunk, like a real link.
    static func reset(failing: Set<String> = [], dieAfter: [String: Int] = [:], chunkDelay: TimeInterval = 0) {
        lock.withLock { _failingHosts = failing; _dieAfter = dieAfter; _requests = []; _chunkDelay = chunkDelay }
    }
    /// Requests for `path` (each test uses its own file name, so a previous
    /// test's still-running read-ahead never shows up here).
    static func requests(for path: String) -> [(host: String, range: String)] {
        lock.withLock { _requests.filter { $0.path == path }.map { ($0.host, $0.range) } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let range = request.value(forHTTPHeaderField: "Range") ?? ""
        let (failing, dieAfter, delay) = Self.lock.withLock { () -> (Bool, Int?, TimeInterval) in
            Self._requests.append((host, range, self.request.url?.path ?? ""))
            return (Self._failingHosts.contains(host), Self._dieAfter[host], Self._chunkDelay)
        }
        if failing {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var lower = 0
        if range.hasPrefix("bytes="), let dash = range.firstIndex(of: "-") {
            lower = Int(range[range.index(range.startIndex, offsetBy: 6)..<dash]) ?? 0
        }
        let size = Self.fileSize
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes \(lower)-\(size - 1)/\(size)",
                           "Content-Length": "\(size - lower)",
                           "Content-Type": "video/mp4"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = lower
        let stop = dieAfter.map { min(size, lower + $0) } ?? size
        while offset < stop {
            let end = min(stop, offset + 64 * 1024)
            client?.urlProtocol(self, didLoad: Self.file.subdata(in: offset..<end))
            offset = end
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
        if dieAfter != nil && stop < size {
            // Let the delivered bytes reach the session before the drop, as
            // they would on a real connection.
            Thread.sleep(forTimeInterval: 0.05)
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Records what the engine hands one request.
private final class FakeSink: RCRangeSink, @unchecked Sendable {
    let wantsContentInfo: Bool
    let hasDataRequest = true
    var data = Data()
    var length: Int64?
    var contentType: String?
    var finished = false
    var error: Error?
    var onFinish: (() -> Void)?
    var onData: ((Int) -> Void)?

    init(wantsContentInfo: Bool = false) { self.wantsContentInfo = wantsContentInfo }

    func fillContentInfo(contentType: String?, length: Int64?) {
        self.contentType = contentType
        self.length = length
    }
    func respond(with data: Data) {
        self.data.append(data)
        onData?(self.data.count)
    }
    func finish(error: Error?) {
        finished = true
        self.error = error
        onFinish?()
    }
}

final class RCReadAheadEngineTests: XCTestCase {

    private var queue: DispatchQueue!
    private var engine: RCReadAheadEngine!
    private var failures: [String] = []
    private let lock = NSLock()
    private let url = URL(string: "https://lan/%5Bremote:%5D/\(UUID().uuidString).mp4")!
    private var requests: [(host: String, range: String)] { RangeStubProtocol.requests(for: url.path) }

    override func setUp() {
        super.setUp()
        RangeStubProtocol.reset()
        queue = DispatchQueue(label: "engine-test")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RangeStubProtocol.self]
        engine = RCReadAheadEngine(queue: queue, configuration: config)
        failures = []
        RCStreamRouting.reportFailure = { [weak self] url in
            guard let self else { return }
            self.lock.withLock { self.failures.append(url.host ?? "") }
        }
    }

    override func tearDown() {
        engine.invalidate()
        RCStreamRouting.candidates = nil
        RCStreamRouting.reportFailure = nil
        RCStreamRouting.reportSuccess = nil
        super.tearDown()
    }

    private func expected(_ range: Range<Int>) -> Data { RangeStubProtocol.file.subdata(in: range) }

    /// Load `lower...upper` and wait until the engine finishes the request.
    private func load(_ sink: FakeSink, lower: Int64, upper: Int64?) {
        let done = expectation(description: "finished \(lower)")
        sink.onFinish = { done.fulfill() }
        queue.async { self.engine.load(sink: sink, url: self.url, lower: lower, upper: upper, headers: [:]) }
        wait(for: [done], timeout: 10)
    }

    private func useMirrors(_ hosts: [String]) {
        RCStreamRouting.candidates = { url in
            hosts.map { host in
                var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                c.host = host
                return c.url!
            }
        }
    }

    func testServesRangeAndContentInfo() {
        let sink = FakeSink(wantsContentInfo: true)
        load(sink, lower: 10, upper: 19)
        XCTAssertNil(sink.error)
        XCTAssertEqual(sink.data, expected(10..<20))
        XCTAssertEqual(sink.length, Int64(RangeStubProtocol.fileSize))
        XCTAssertEqual(sink.contentType, "video/mp4")
    }

    /// AV's pattern: take some bytes, cancel, ask again from further on. The
    /// follow-up is answered from the same connection's bytes.
    func testFollowUpRequestReusesTheConnection() {
        let first = FakeSink()
        let got = expectation(description: "first bytes")
        first.onData = { count in if count >= 200_000 { first.onData = nil; got.fulfill() } }
        queue.async { self.engine.load(sink: first, url: self.url, lower: 0, upper: nil, headers: [:]) }
        wait(for: [got], timeout: 10)
        queue.sync { self.engine.cancel(sink: first) }

        let second = FakeSink()
        load(second, lower: 150_000, upper: 249_999)
        XCTAssertEqual(second.data, expected(150_000..<250_000))
        XCTAssertEqual(requests.count, 1, "\(requests)")
    }

    func testRequestFarAheadOpensItsOwnConnection() {
        engine.invalidate()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RangeStubProtocol.self]
        var tuning = RCReadAheadEngine.Tuning()
        tuning.joinGap = 64 * 1024
        engine = RCReadAheadEngine(queue: queue, configuration: config, tuning: tuning)
        RangeStubProtocol.reset(chunkDelay: 0.05)

        let first = FakeSink()
        load(first, lower: 0, upper: 999)
        let far = FakeSink()
        load(far, lower: 900_000, upper: 900_999)
        XCTAssertEqual(far.data, expected(900_000..<901_000))
        XCTAssertTrue(requests.contains { $0.range == "bytes=900000-" },
                      "\(requests)")
    }

    func testRequestPastTheEndFinishesEmpty() {
        let info = FakeSink(wantsContentInfo: true)
        load(info, lower: 0, upper: 1)
        let past = FakeSink()
        load(past, lower: Int64(RangeStubProtocol.fileSize), upper: nil)
        XCTAssertNil(past.error)
        XCTAssertTrue(past.data.isEmpty)
    }

    /// The LAN copy drops mid-range; the rest of the SAME request comes from
    /// the cloud copy, resumed where the LAN stopped.
    func testMidStreamDropFailsOverToNextMirror() {
        useMirrors(["lan", "cloud"])
        RangeStubProtocol.reset(dieAfter: ["lan": 3_000])
        let sink = FakeSink()
        load(sink, lower: 1_000, upper: 9_999)
        XCTAssertNil(sink.error)
        XCTAssertEqual(sink.data, expected(1_000..<10_000))
        XCTAssertEqual(lock.withLock { failures }, ["lan"])
        XCTAssertTrue(requests.contains { $0.host == "cloud" && $0.range == "bytes=4000-" },
                      "\(requests)")
    }

    func testUnreachableFirstMirrorFallsThrough() {
        useMirrors(["lan", "cloud"])
        RangeStubProtocol.reset(failing: ["lan"])
        let sink = FakeSink()
        load(sink, lower: 0, upper: 4_095)
        XCTAssertNil(sink.error)
        XCTAssertEqual(sink.data, expected(0..<4_096))
    }

    func testEveryMirrorFailingFailsTheRequest() {
        useMirrors(["lan", "cloud"])
        RangeStubProtocol.reset(failing: ["lan", "cloud"])
        let sink = FakeSink()
        load(sink, lower: 0, upper: 4_095)
        XCTAssertNotNil(sink.error)
        XCTAssertTrue(sink.data.isEmpty)

        // A later request starts clean and succeeds once a copy is back.
        RangeStubProtocol.reset()
        let retry = FakeSink()
        load(retry, lower: 0, upper: 4_095)
        XCTAssertNil(retry.error)
        XCTAssertEqual(retry.data, expected(0..<4_096))
    }
}
