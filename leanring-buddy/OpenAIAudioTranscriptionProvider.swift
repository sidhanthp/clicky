//
//  OpenAIAudioTranscriptionProvider.swift
//  leanring-buddy
//
//  Streaming transcription provider backed by the OpenAI Realtime API.
//

import AVFoundation
import Foundation

enum OpenAIRealtimeTranscriptionModel: String, CaseIterable {
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"

    static let userDefaultsKey = "selectedOpenAIRealtimeTranscriptionModel"

    var shortDisplayName: String {
        switch self {
        case .gpt4oTranscribe:
            return "GPT-4o"
        case .gpt4oMiniTranscribe:
            return "Mini"
        }
    }

    static var currentSelection: OpenAIRealtimeTranscriptionModel {
        if let storedModelIdentifier = UserDefaults.standard.string(forKey: userDefaultsKey),
           let storedModel = OpenAIRealtimeTranscriptionModel(rawValue: storedModelIdentifier) {
            return storedModel
        }

        return .gpt4oTranscribe
    }

    static func persistSelection(_ model: OpenAIRealtimeTranscriptionModel) {
        UserDefaults.standard.set(model.rawValue, forKey: userDefaultsKey)
    }
}

struct OpenAIAudioTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class OpenAIAudioTranscriptionProvider: BuddyTranscriptionProvider {
    private static let realtimeInputSampleRate = 24_000

    let displayName = "OpenAI Realtime"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        ProxyConfiguration.shouldUseDirectOpenAI
            || ProxyConfiguration.workerBaseURLString != "https://your-worker-name.your-subdomain.workers.dev"
    }
    var unavailableExplanation: String? {
        if isConfigured {
            return nil
        }

        return "set OPENAI_API_KEY in your Xcode run environment or configure WorkerBaseURL."
    }

    /// Single long-lived URLSession shared across all streaming sessions.
    /// Creating and invalidating a URLSession per session corrupts the OS
    /// connection pool and causes avoidable websocket instability.
    private let sharedWebSocketURLSession = URLSession(configuration: .default)

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let realtimeSessionConfiguration = makeRealtimeSessionRequestBody(keyterms: keyterms)
        let selectedRealtimeTranscriptionModel = OpenAIRealtimeTranscriptionModel.currentSelection

        let authorizationBearerToken: String
        let initialSessionConfiguration: [String: Any]?

        if let directOpenAIAPIKey = ProxyConfiguration.openAIAPIKey {
            authorizationBearerToken = directOpenAIAPIKey
            initialSessionConfiguration = makeRealtimeSessionUpdateEvent(
                from: realtimeSessionConfiguration
            )
            print(
                "🎙️ OpenAI Realtime: using direct API key authentication for dev mode (\(selectedRealtimeTranscriptionModel.rawValue))"
            )
        } else {
            let clientSecret = try await fetchRealtimeClientSecret(keyterms: keyterms)
            authorizationBearerToken = clientSecret
            initialSessionConfiguration = nil
            print(
                "🎙️ OpenAI Realtime: fetched ephemeral client secret (\(clientSecret.prefix(20))...) for \(selectedRealtimeTranscriptionModel.rawValue)"
            )
        }

        let session = OpenAIRealtimeTranscriptionSession(
            authorizationBearerToken: authorizationBearerToken,
            initialSessionConfiguration: initialSessionConfiguration,
            urlSession: sharedWebSocketURLSession,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        try await session.open()
        return session
    }

    private func fetchRealtimeClientSecret(keyterms: [String]) async throws -> String {
        var request = URLRequest(url: URL(string: ProxyConfiguration.transcriptionSessionProxyURLString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorizationHeaderValue = ProxyConfiguration.authorizationHeaderValue {
            request.setValue(authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: makeRealtimeSessionRequestBody(keyterms: keyterms)
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw OpenAIAudioTranscriptionProviderError(
                message: "Failed to create OpenAI transcription session (HTTP \(statusCode)): \(body)"
            )
        }

        return try extractClientSecret(from: data)
    }

    private func makeRealtimeSessionRequestBody(keyterms: [String]) -> [String: Any] {
        let prompt = makeTranscriptionBiasPrompt(from: keyterms)
        let selectedRealtimeTranscriptionModel = OpenAIRealtimeTranscriptionModel.currentSelection

        return [
            "input_audio_format": "pcm16",
            "input_audio_transcription": [
                "model": selectedRealtimeTranscriptionModel.rawValue,
                "prompt": prompt,
                "language": "en"
            ],
            "turn_detection": [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 500
            ],
            "input_audio_noise_reduction": [
                "type": "near_field"
            ]
        ]
    }

    private func makeRealtimeSessionUpdateEvent(
        from transcriptionSessionConfiguration: [String: Any]
    ) -> [String: Any] {
        var realtimeAudioInputConfiguration: [String: Any] = [
            "format": [
                "type": "audio/pcm",
                "rate": Self.realtimeInputSampleRate
            ]
        ]

        if let inputAudioTranscription = transcriptionSessionConfiguration["input_audio_transcription"] {
            realtimeAudioInputConfiguration["transcription"] = inputAudioTranscription
        }
        if let turnDetection = transcriptionSessionConfiguration["turn_detection"] {
            realtimeAudioInputConfiguration["turn_detection"] = turnDetection
        }
        if let inputAudioNoiseReduction = transcriptionSessionConfiguration["input_audio_noise_reduction"] {
            realtimeAudioInputConfiguration["noise_reduction"] = inputAudioNoiseReduction
        }

        var realtimeSessionConfiguration: [String: Any] = [
            "type": "transcription",
            "audio": [
                "input": realtimeAudioInputConfiguration
            ]
        ]

        if let include = transcriptionSessionConfiguration["include"] {
            realtimeSessionConfiguration["include"] = include
        }

        return [
            "type": "session.update",
            "session": realtimeSessionConfiguration
        ]
    }

    private func makeTranscriptionBiasPrompt(from keyterms: [String]) -> String {
        let trimmedKeyterms = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !trimmedKeyterms.isEmpty else {
            return ""
        }

        return "Bias transcription toward these product and app terms when they are spoken: \(trimmedKeyterms.joined(separator: ", "))"
    }

    private func extractClientSecret(from responseData: Data) throws -> String {
        guard let responseJSONObject = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw OpenAIAudioTranscriptionProviderError(
                message: "Invalid transcription session response from proxy."
            )
        }

        if let clientSecretObject = responseJSONObject["client_secret"] as? [String: Any],
           let clientSecretValue = clientSecretObject["value"] as? String,
           !clientSecretValue.isEmpty {
            return clientSecretValue
        }

        if let clientSecretValue = responseJSONObject["client_secret"] as? String,
           !clientSecretValue.isEmpty {
            return clientSecretValue
        }

        throw OpenAIAudioTranscriptionProviderError(
            message: "Proxy response did not include a client secret."
        )
    }
}

private final class OpenAIRealtimeTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {
    private struct EventEnvelope: Decodable {
        let type: String
    }

    private struct InputAudioBufferCommittedEvent: Decodable {
        let type: String
        let item_id: String
        let previous_item_id: String?
    }

    private struct InputAudioTranscriptionDeltaEvent: Decodable {
        let type: String
        let item_id: String
        let delta: String
    }

    private struct InputAudioTranscriptionCompletedEvent: Decodable {
        let type: String
        let item_id: String
        let transcript: String
    }

    private struct ErrorEvent: Decodable {
        struct ErrorDetails: Decodable {
            let message: String?
        }

        let type: String
        let error: ErrorDetails?
        let message: String?
    }

    private static let websocketURLString = "wss://api.openai.com/v1/realtime?intent=transcription"
    private static let targetSampleRate = 24_000.0
    private static let explicitFinalTranscriptGracePeriodSeconds = 1.4

    let finalTranscriptFallbackDelaySeconds: TimeInterval = 2.8

    private let authorizationBearerToken: String
    private let initialSessionConfiguration: [String: Any]?
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.openai.realtime.state")
    private let sendQueue = DispatchQueue(label: "com.learningbuddy.openai.realtime.send")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: targetSampleRate)
    private let urlSession: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var hasDeliveredFinalTranscript = false
    private var isAwaitingExplicitFinalTranscript = false
    private var latestTranscriptText = ""
    private var committedItemOrder: [String] = []
    private var finalizedTranscriptByItemID: [String: String] = [:]
    private var inProgressTranscriptByItemID: [String: String] = [:]
    private var explicitFinalTranscriptDeadlineWorkItem: DispatchWorkItem?

    init(
        authorizationBearerToken: String,
        initialSessionConfiguration: [String: Any]?,
        urlSession: URLSession,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.authorizationBearerToken = authorizationBearerToken
        self.initialSessionConfiguration = initialSessionConfiguration
        self.urlSession = urlSession
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func open() async throws {
        guard let websocketURL = URL(string: Self.websocketURLString) else {
            throw OpenAIAudioTranscriptionProviderError(
                message: "OpenAI Realtime websocket URL is invalid."
            )
        }

        var websocketRequest = URLRequest(url: websocketURL)
        websocketRequest.setValue("Bearer \(authorizationBearerToken)", forHTTPHeaderField: "Authorization")

        let webSocketTask = urlSession.webSocketTask(with: websocketRequest)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()

        receiveNextMessage()

        if let initialSessionConfiguration {
            sendJSONMessage(initialSessionConfiguration)
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        let base64EncodedAudio = audioPCM16Data.base64EncodedString()

        sendJSONMessage([
            "type": "input_audio_buffer.append",
            "audio": base64EncodedAudio
        ])
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasDeliveredFinalTranscript else { return }
            self.isAwaitingExplicitFinalTranscript = true
            self.scheduleExplicitFinalTranscriptDeadline()
        }

        sendJSONMessage([
            "type": "input_audio_buffer.commit"
        ])
    }

    func cancel() {
        stateQueue.async {
            self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
            self.explicitFinalTranscriptDeadlineWorkItem = nil
        }

        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingTextMessage(text)
                    }
                @unknown default:
                    break
                }

                self.receiveNextMessage()
            case .failure(let error):
                self.failSession(with: error)
            }
        }
    }

    private func handleIncomingTextMessage(_ text: String) {
        guard let messageData = text.data(using: .utf8) else { return }

        do {
            let eventEnvelope = try JSONDecoder().decode(EventEnvelope.self, from: messageData)

            switch eventEnvelope.type {
            case "input_audio_buffer.committed":
                let committedEvent = try JSONDecoder().decode(
                    InputAudioBufferCommittedEvent.self,
                    from: messageData
                )
                handleCommittedEvent(committedEvent)
            case "conversation.item.input_audio_transcription.delta":
                let deltaEvent = try JSONDecoder().decode(
                    InputAudioTranscriptionDeltaEvent.self,
                    from: messageData
                )
                handleDeltaEvent(deltaEvent)
            case "conversation.item.input_audio_transcription.completed":
                let completedEvent = try JSONDecoder().decode(
                    InputAudioTranscriptionCompletedEvent.self,
                    from: messageData
                )
                handleCompletedEvent(completedEvent)
            case "error":
                let errorEvent = try JSONDecoder().decode(ErrorEvent.self, from: messageData)
                let errorMessage = errorEvent.error?.message ?? errorEvent.message ?? "OpenAI Realtime returned an error."
                failSession(with: OpenAIAudioTranscriptionProviderError(message: errorMessage))
            default:
                break
            }
        } catch {
            failSession(with: error)
        }
    }

    private func handleCommittedEvent(_ event: InputAudioBufferCommittedEvent) {
        stateQueue.async {
            self.insertCommittedItemID(event.item_id, after: event.previous_item_id)
        }
    }

    private func handleDeltaEvent(_ event: InputAudioTranscriptionDeltaEvent) {
        let deltaText = event.delta.trimmingCharacters(in: .newlines)

        stateQueue.async {
            let existingTranscriptText = self.inProgressTranscriptByItemID[event.item_id] ?? ""
            self.inProgressTranscriptByItemID[event.item_id] = existingTranscriptText + deltaText
            self.insertCommittedItemID(event.item_id, after: nil)
            self.publishLatestTranscriptIfNeeded()
        }
    }

    private func handleCompletedEvent(_ event: InputAudioTranscriptionCompletedEvent) {
        let transcriptText = event.transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        stateQueue.async {
            self.insertCommittedItemID(event.item_id, after: nil)
            self.finalizedTranscriptByItemID[event.item_id] = transcriptText
            self.inProgressTranscriptByItemID[event.item_id] = nil
            self.publishLatestTranscriptIfNeeded()

            guard self.isAwaitingExplicitFinalTranscript else { return }

            self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
            self.explicitFinalTranscriptDeadlineWorkItem = nil
            self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
        }
    }

    private func insertCommittedItemID(_ itemID: String, after previousItemID: String?) {
        guard !committedItemOrder.contains(itemID) else { return }

        if let previousItemID,
           let previousIndex = committedItemOrder.firstIndex(of: previousItemID) {
            committedItemOrder.insert(itemID, at: previousIndex + 1)
            return
        }

        committedItemOrder.append(itemID)
    }

    private func publishLatestTranscriptIfNeeded() {
        let fullTranscriptText = composeFullTranscript()
        latestTranscriptText = fullTranscriptText

        if !fullTranscriptText.isEmpty {
            onTranscriptUpdate(fullTranscriptText)
        }
    }

    private func composeFullTranscript() -> String {
        var transcriptSegments: [String] = []

        for itemID in committedItemOrder {
            let finalizedTranscriptText = finalizedTranscriptByItemID[itemID]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let inProgressTranscriptText = inProgressTranscriptByItemID[itemID]?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let finalizedTranscriptText, !finalizedTranscriptText.isEmpty {
                transcriptSegments.append(finalizedTranscriptText)
                continue
            }

            if let inProgressTranscriptText, !inProgressTranscriptText.isEmpty {
                transcriptSegments.append(inProgressTranscriptText)
            }
        }

        return transcriptSegments.joined(separator: " ")
    }

    private func scheduleExplicitFinalTranscriptDeadline() {
        explicitFinalTranscriptDeadlineWorkItem?.cancel()

        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            self?.stateQueue.async {
                guard let self else { return }
                self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
            }
        }

        explicitFinalTranscriptDeadlineWorkItem = deadlineWorkItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.explicitFinalTranscriptGracePeriodSeconds,
            execute: deadlineWorkItem
        )
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        explicitFinalTranscriptDeadlineWorkItem?.cancel()
        explicitFinalTranscriptDeadlineWorkItem = nil
        onFinalTranscriptReady(transcriptText)
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
    }

    private func sendJSONMessage(_ payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.string(jsonString)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    private func failSession(with error: Error) {
        stateQueue.async {
            let latestTranscriptText = self.bestAvailableTranscriptText()

            if self.isAwaitingExplicitFinalTranscript
                && !self.hasDeliveredFinalTranscript
                && !latestTranscriptText.isEmpty {
                print("[OpenAI Realtime] ⚠️ WebSocket error during active session, delivering partial transcript as fallback: \(error.localizedDescription)")
                self.deliverFinalTranscriptIfNeeded(latestTranscriptText)
                return
            }

            print("[OpenAI Realtime] ❌ Session failed with error: \(error.localizedDescription)")
            self.onError(error)
        }
    }

    private func bestAvailableTranscriptText() -> String {
        let composedTranscriptText = composeFullTranscript()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !composedTranscriptText.isEmpty {
            return composedTranscriptText
        }

        return latestTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
