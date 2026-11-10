//
//  RCStreamRouting.swift
//  MediaStream
//
//  Optional host hook that lets one logical stream be served by more than
//  one physical location ("mirrors") and fail over between them mid-play.
//
//  The host app installs `candidates`: given the real `https://` loopback URL
//  AVPlayer is asking for, return every equivalent URL in preference order
//  (fastest reachable mirror first). `RCStreamingResourceLoader` then reads
//  from the first candidate and, when that connection fails — transport
//  error, stall past `failoverRequestTimeout`, or an HTTP error status —
//  continues from the same byte on the next candidate. AVPlayer never sees
//  the hiccup: its pending ranges simply complete from a different backend.
//
//  The candidates must be byte-identical copies. The host is responsible for
//  only offering locations whose size matches.
//
//  Without a hook installed every URL has exactly one candidate (itself) and
//  the loader behaves exactly as before.
//

import Foundation

public enum RCStreamRouting {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _candidates: (@Sendable (URL) -> [URL])?
    nonisolated(unsafe) private static var _reportFailure: (@Sendable (URL) -> Void)?
    nonisolated(unsafe) private static var _reportSuccess: (@Sendable (URL, TimeInterval) -> Void)?
    nonisolated(unsafe) private static var _failoverRequestTimeout: TimeInterval = 15
    nonisolated(unsafe) private static var _connectionLimit: (@Sendable (URL) -> Int?)?

    /// Ordered equivalent URLs for a real (`https://`) loopback URL. The first
    /// is tried first. Returning an empty list is treated as `[url]`.
    public static var candidates: (@Sendable (URL) -> [URL])? {
        get { lock.lock(); defer { lock.unlock() }; return _candidates }
        set { lock.lock(); _candidates = newValue; lock.unlock() }
    }

    /// Called when a candidate failed (error, stall, or HTTP error status), so
    /// the host can demote that backend for every other request too.
    public static var reportFailure: (@Sendable (URL) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _reportFailure }
        set { lock.lock(); _reportFailure = newValue; lock.unlock() }
    }

    /// Called with the time-to-first-response of a successful fetch — a free
    /// latency sample the host can feed into its ranking.
    public static var reportSuccess: (@Sendable (URL, TimeInterval) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _reportSuccess }
        set { lock.lock(); _reportSuccess = newValue; lock.unlock() }
    }

    /// Idle timeout per range request when an alternative exists. A dropped
    /// LAN usually doesn't error — the socket just goes quiet — so without a
    /// short timeout a failover would wait out the 60s default. Requests with
    /// no alternative keep the 60s default (slow clouds legitimately pause).
    public static var failoverRequestTimeout: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _failoverRequestTimeout }
        set { lock.lock(); _failoverRequestTimeout = max(2, newValue); lock.unlock() }
    }

    /// The most connections worth opening at once to read one place in a
    /// file at `url` (a candidate URL), or nil for the default. Cloud
    /// backends answer each request slowly but serve many in parallel, so
    /// parallel fetches help; a LAN file share (SFTP, SMB) answers fast and
    /// pays for every extra connection with a new session or file handle on
    /// the server, so a couple of long-lived reads beat many short ones.
    public static var connectionLimit: (@Sendable (URL) -> Int?)? {
        get { lock.lock(); defer { lock.unlock() }; return _connectionLimit }
        set { lock.lock(); _connectionLimit = newValue; lock.unlock() }
    }

    /// Resolve the candidate list for `url`, always non-empty and always
    /// containing at least `url` itself when the hook returns nothing.
    public static func resolve(_ url: URL) -> [URL] {
        guard let hook = candidates else { return [url] }
        let list = hook(url)
        return list.isEmpty ? [url] : list
    }

    /// Fetch `request` from the first candidate that answers, failing over on
    /// transport errors and HTTP >= 400. For one-shot (non-AVPlayer) fetches —
    /// images, metadata prefixes. Returns the last error when every
    /// candidate fails.
    public static func data(
        for request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        guard let url = request.url else { return try await session.data(for: request) }
        let urls = resolve(url)
        var lastError: Error = URLError(.cannotConnectToHost)
        for (index, candidate) in urls.enumerated() {
            var attempt = request
            attempt.url = candidate
            if urls.count > 1, index < urls.count - 1 {
                attempt.timeoutInterval = min(request.timeoutInterval, failoverRequestTimeout)
            }
            let started = Date()
            do {
                let (data, response) = try await session.data(for: attempt)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400,
                   index < urls.count - 1 {
                    reportFailure?(candidate)
                    lastError = URLError(.badServerResponse)
                    continue
                }
                reportSuccess?(candidate, Date().timeIntervalSince(started))
                return (data, response)
            } catch {
                if (error as? URLError)?.code == .cancelled || Task.isCancelled { throw error }
                reportFailure?(candidate)
                lastError = error
            }
        }
        throw lastError
    }
}
