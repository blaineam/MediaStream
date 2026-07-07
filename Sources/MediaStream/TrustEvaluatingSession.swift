//
//  TrustEvaluatingSession.swift
//  MediaStream
//
//  Shared URLSession whose delegate consults the host app's server-trust
//  evaluator (MediaStreamConfiguration.serverTrustEvaluator). Plain
//  URLSession.shared rejects self-signed certificates, and host apps like
//  Enter Space serve media from a local HTTPS endpoint with exactly such a
//  certificate — any in-library fetch that skips this session dies in the
//  TLS handshake before a single byte arrives.
//

import Foundation

private final class TrustEvaluatingSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if MediaStreamConfiguration.evaluateServerTrust(serverTrust, host: challenge.protectionSpace.host) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

extension MediaStreamConfiguration {
    /// Session for one-shot in-library fetches (animated images, network
    /// images). Falls back to default certificate handling when the app has
    /// not installed a trust evaluator, so behavior is unchanged for normal
    /// hosts.
    public static let trustEvaluatingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: TrustEvaluatingSessionDelegate(), delegateQueue: nil)
    }()
}
