//
//  AIVisionService.swift
//  DualPhoneCodingAssistant
//
//  Service layer (MVVM). Sends a single captured frame to Anthropic's
//  Claude API (vision-capable model) and asks it to either solve the
//  coding question shown on screen, or say "NONE" if there isn't one.
//
//  Before wiring this into the full capture pipeline, prove it works in
//  isolation first — see Scripts/manual_ai_test.md for a copy-paste curl
//  version of the exact same request this file sends.
//

import Foundation
import UIKit

/// Errors specific to the AI vision call.
enum AIVisionServiceError: Error {
    /// No API key was found via `AIVisionService.apiKey` — see the TODO
    /// on that property.
    case missingAPIKey
    /// The image couldn't be JPEG-encoded.
    case imageEncodingFailed
    /// HTTP response wasn't 200, or the body couldn't be parsed as an
    /// Anthropic Messages API response. `body` is the raw response text,
    /// useful for debugging in the Xcode console.
    case requestFailed(statusCode: Int, body: String)
    case unexpectedResponseShape
}

/// Talks to Anthropic's Messages API (`POST /v1/messages`) to solve a
/// coding-practice question captured from Phone A's camera.
///
/// This is intentionally a plain `URLSession` client rather than the
/// Anthropic Swift SDK — there is no official first-party Swift SDK, and
/// pulling in a community package is unnecessary weight for one endpoint
/// in a personal project.
final class AIVisionService {

    static let shared = AIVisionService()

    /// Model used for the vision + solve call. Any current Claude model
    /// with vision support works; Opus is used here for solve quality
    /// since this call only fires once per new question (see
    /// `QuestionAnchorDetector`'s settle timer), so cost per call is low
    /// and it's worth spending on the best answer.
    private let model = "claude-opus-5"

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"

    /// The exact prompt sent alongside the image. Kept as a single source
    /// of truth so Scripts/manual_ai_test.md and this file can be tested
    /// against literally the same instruction.
    static let prompt = """
    If this image shows a programming/coding practice question, extract \
    and solve it in full with working code; otherwise respond exactly NONE.
    """

    private init() {}

    /// The Anthropic API key.
    ///
    /// TODO: Fill this in once on your Mac — do NOT hardcode the key here.
    /// Recommended approach:
    ///   1. Create a `Secrets.plist` file in the Xcode project (add it to
    ///      the app target, and add it to `.gitignore` so it never gets
    ///      committed).
    ///   2. Give it a single key: `AnthropicAPIKey` (String) with your
    ///      real key as the value.
    ///   3. Leave the code below as-is — it reads that key at runtime.
    private var apiKey: String? {
        guard
            let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let key = plist["AnthropicAPIKey"] as? String,
            !key.isEmpty
        else {
            return nil
        }
        return key
    }

    /// Sends `image` to Claude with `AIVisionService.prompt` and returns
    /// the solved answer text, or `nil` if the AI decided the image did
    /// not contain a coding question (i.e. it replied exactly "NONE").
    ///
    /// - Throws: `AIVisionServiceError` for missing key / network / HTTP /
    ///   parsing failures. Callers (see `CaptureViewModel`) should treat a
    ///   thrown error as "skip this frame, try again on the next detected
    ///   change" rather than fatal.
    func solveQuestion(from image: UIImage) async throws -> String? {
        guard let apiKey else {
            throw AIVisionServiceError.missingAPIKey
        }
        guard let jpegData = image.jpegData(compressionQuality: 0.8) else {
            throw AIVisionServiceError.imageEncodingFailed
        }
        let base64Image = jpegData.base64EncodedString()

        let requestBody = MessagesRequest(
            model: model,
            maxTokens: 16000,
            messages: [
                MessagesRequest.Message(
                    role: "user",
                    content: [
                        .image(mediaType: "image/jpeg", base64Data: base64Image),
                        .text(Self.prompt)
                    ]
                )
            ]
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIVisionServiceError.unexpectedResponseShape
        }
        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw AIVisionServiceError.requestFailed(statusCode: httpResponse.statusCode, body: bodyText)
        }

        let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)

        // The response `content` array can contain multiple block types
        // (e.g. "thinking" blocks may appear ahead of the answer since
        // this model thinks by default). We only care about the first
        // "text" block — that's Claude's actual reply text.
        guard let textBlock = decoded.content.first(where: { $0.type == "text" }),
              let text = textBlock.text else {
            throw AIVisionServiceError.unexpectedResponseShape
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "NONE" ? nil : trimmed
    }
}

// MARK: - Request/response models

/// Minimal Codable mirror of the Anthropic Messages API request shape
/// (`POST /v1/messages`) — only the fields this app actually sends.
///
/// Expected JSON:
/// ```json
/// {
///   "model": "claude-opus-5",
///   "max_tokens": 16000,
///   "messages": [{
///     "role": "user",
///     "content": [
///       {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "<base64>"}},
///       {"type": "text", "text": "If this image shows..."}
///     ]
///   }]
/// }
/// ```
private struct MessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages
    }

    struct Message: Encodable {
        let role: String
        let content: [ContentBlock]
    }

    enum ContentBlock: Encodable {
        case text(String)
        case image(mediaType: String, base64Data: String)

        private enum CodingKeys: String, CodingKey {
            case type, text, source
        }
        private enum SourceKeys: String, CodingKey {
            case type, mediaType = "media_type", data
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let mediaType, let base64Data):
                try container.encode("image", forKey: .type)
                var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                try source.encode("base64", forKey: .type)
                try source.encode(mediaType, forKey: .mediaType)
                try source.encode(base64Data, forKey: .data)
            }
        }
    }
}

/// Minimal Codable mirror of the Anthropic Messages API response shape —
/// only the fields this app actually reads.
///
/// Expected JSON (trimmed to relevant fields):
/// ```json
/// {
///   "content": [
///     {"type": "text", "text": "Here is the solved question..."}
///   ],
///   "stop_reason": "end_turn"
/// }
/// ```
private struct MessagesResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let type: String
        /// Present when `type == "text"`. Other block types (e.g.
        /// "thinking") are decoded but ignored — their fields simply
        /// aren't modeled here.
        let text: String?
    }
}
