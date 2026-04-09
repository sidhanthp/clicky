//
//  OpenAITTSClient.swift
//  leanring-buddy
//
//  Streams text-to-speech audio from the OpenAI Audio API and plays it back
//  through the system audio output.
//

import AVFoundation
import Foundation

@MainActor
final class OpenAITTSClient {
    private let requestURL: URL
    private let authorizationHeaderValue: String?
    private let model: String
    private let voice: String
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    init(
        requestURL: String,
        authorizationHeaderValue: String?,
        model: String,
        voice: String
    ) {
        self.requestURL = URL(string: requestURL)!
        self.authorizationHeaderValue = authorizationHeaderValue
        self.model = model
        self.voice = voice

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Sends `text` to the OpenAI speech API and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(_ text: String) async throws {
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        if let authorizationHeaderValue {
            request.setValue(authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": model,
            "voice": voice,
            "format": "mp3",
            "input": text
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OpenAITTS",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "OpenAITTS",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.play()
        print("🔊 OpenAI TTS: playing \(data.count / 1024)KB audio")
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }
}
