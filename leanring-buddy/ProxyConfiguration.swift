//
//  ProxyConfiguration.swift
//  leanring-buddy
//
//  Shared configuration for proxy-backed API routes.
//

import Foundation

enum ProxyConfiguration {
    private static let defaultWorkerBaseURLString = "https://your-worker-name.your-subdomain.workers.dev"

    static let workerBaseURLString: String = {
        AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL") ?? defaultWorkerBaseURLString
    }()

    static let responsesProxyURLString = "\(workerBaseURLString)/responses"
    static let speechProxyURLString = "\(workerBaseURLString)/speech"
    static let transcriptionSessionProxyURLString = "\(workerBaseURLString)/transcription-session"
}
