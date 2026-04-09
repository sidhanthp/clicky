//
//  OpenAIAPI.swift
//  OpenAI Responses API implementation with streaming support.
//

import Foundation

/// OpenAI Responses API helper for screenshot-aware voice interactions.
final class OpenAIResponsesAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let proxyURL: URL
    var model: String
    private let session: URLSession

    init(proxyURL: String, model: String = "gpt-5.4") {
        self.proxyURL = URL(string: proxyURL)!
        self.model = model

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)

        warmUpTLSConnectionIfNeeded()
    }

    private func makeRequest(acceptHeaderValue: String) -> URLRequest {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(acceptHeaderValue, forHTTPHeaderField: "Accept")
        return request
    }

    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false) else {
            return
        }

        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response does not matter. The handshake is the goal.
        }.resume()
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        var request = makeRequest(acceptHeaderValue: "text/event-stream")

        let body = makeRequestBody(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            shouldStream: true
        )

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 OpenAI Responses streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OpenAIResponsesAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }

            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "OpenAIResponsesAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))

            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            if eventType == "response.output_text.delta",
               let textDelta = eventPayload["delta"] as? String {
                accumulatedResponseText += textDelta
                let currentAccumulatedResponseText = accumulatedResponseText
                await onTextChunk(currentAccumulatedResponseText)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        var request = makeRequest(acceptHeaderValue: "application/json")

        let body = makeRequestBody(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            shouldStream: false
        )

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "OpenAIResponsesAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let responseText = Self.extractOutputText(from: json)

        let duration = Date().timeIntervalSince(startTime)
        return (text: responseText, duration: duration)
    }

    private func makeRequestBody(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        shouldStream: Bool
    ) -> [String: Any] {
        var inputItems: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            inputItems.append([
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": userPlaceholder
                    ]
                ]
            ])

            inputItems.append([
                "role": "assistant",
                "content": [
                    [
                        "type": "output_text",
                        "text": assistantResponse
                    ]
                ]
            ])
        }

        var currentContentItems: [[String: Any]] = []

        for image in images {
            currentContentItems.append([
                "type": "input_text",
                "text": image.label
            ])

            currentContentItems.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(image.data.base64EncodedString())"
            ])
        }

        currentContentItems.append([
            "type": "input_text",
            "text": userPrompt
        ])

        inputItems.append([
            "role": "user",
            "content": currentContentItems
        ])

        return [
            "model": model,
            "instructions": systemPrompt,
            "input": inputItems,
            "max_output_tokens": 1024,
            "stream": shouldStream,
            "store": false
        ]
    }

    private static func extractOutputText(from responseJSON: [String: Any]?) -> String {
        guard let outputItems = responseJSON?["output"] as? [[String: Any]] else {
            return ""
        }

        var responseTextSegments: [String] = []

        for outputItem in outputItems {
            guard let contentItems = outputItem["content"] as? [[String: Any]] else { continue }

            for contentItem in contentItems {
                guard let contentType = contentItem["type"] as? String else { continue }

                if contentType == "output_text",
                   let text = contentItem["text"] as? String,
                   !text.isEmpty {
                    responseTextSegments.append(text)
                }
            }
        }

        return responseTextSegments.joined()
    }
}
