//
//  ProxyConfiguration.swift
//  leanring-buddy
//
//  Shared configuration for proxy-backed API routes.
//

import Foundation

enum ProxyConfiguration {
    private static let openAIAPIBaseURLString = "https://api.openai.com/v1"
    private static let defaultWorkerBaseURLString = "https://your-worker-name.your-subdomain.workers.dev"
    private static let defaultTTSModel = "gpt-4o-mini-tts"
    private static let defaultTTSVoice = "cedar"

    private static let configuredWorkerBaseURLString: String = {
        AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL") ?? defaultWorkerBaseURLString
    }()

    static let openAIAPIKey: String? = AppBundleConfiguration.stringValue(forKey: "OPENAI_API_KEY")
    static let shouldUseDirectOpenAI: Bool = openAIAPIKey != nil
    static let authorizationHeaderValue: String? = openAIAPIKey.map { "Bearer \($0)" }
    static let textToSpeechModel: String = AppBundleConfiguration.stringValue(forKey: "OPENAI_TTS_MODEL")
        ?? defaultTTSModel
    static let textToSpeechVoice: String = AppBundleConfiguration.stringValue(forKey: "OPENAI_TTS_VOICE")
        ?? defaultTTSVoice

    static let workerBaseURLString: String = configuredWorkerBaseURLString

    static let responsesProxyURLString: String = {
        if shouldUseDirectOpenAI {
            return "\(openAIAPIBaseURLString)/responses"
        }

        return "\(workerBaseURLString)/responses"
    }()

    static let speechProxyURLString: String = {
        if shouldUseDirectOpenAI {
            return "\(openAIAPIBaseURLString)/audio/speech"
        }

        return "\(workerBaseURLString)/speech"
    }()

    static let transcriptionSessionProxyURLString: String = {
        if shouldUseDirectOpenAI {
            return "\(openAIAPIBaseURLString)/realtime/transcription_sessions"
        }

        return "\(workerBaseURLString)/transcription-session"
    }()
}
