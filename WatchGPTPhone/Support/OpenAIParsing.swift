import Foundation

// Pure, side-effect-free parsing/classification helpers for the OpenAI bridge.
// Extracted from `PhoneRealtimeBridge` so they are not MainActor-isolated and
// can be unit tested directly.

enum OpenAIResponseParsing {
    /// Extracts assistant text from a /v1/responses payload, handling both the
    /// convenience `output_text` field and the structured `output[].content`
    /// walk.
    static func outputText(from json: [String: Any]) -> String? {
        if let outputText = json["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        if let output = json["output"] as? [[String: Any]] {
            let text = output.compactMap { item -> String? in
                guard let content = item["content"] as? [[String: Any]] else { return nil }
                return content.compactMap { $0["text"] as? String }.joined()
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }

        return nil
    }

    /// Number of server-side web searches OpenAI ran while producing a response.
    static func webSearchCallCount(in json: [String: Any]) -> Int {
        guard let output = json["output"] as? [[String: Any]] else { return 0 }
        return output.filter { ($0["type"] as? String) == "web_search_call" }.count
    }
}

enum RealtimeErrorClassifier {
    struct Info: Equatable {
        let message: String
        let code: String
    }

    static func parse(_ event: [String: Any]) -> Info {
        if let nested = event["error"] as? [String: Any] {
            let message = (nested["message"] as? String) ?? "OpenAI realtime error"
            let code = (nested["code"] as? String) ?? (nested["type"] as? String) ?? ""
            return Info(message: message, code: code)
        }
        let message = (event["message"] as? String) ?? "OpenAI realtime error"
        let code = (event["code"] as? String) ?? ""
        return Info(message: message, code: code)
    }

    /// Conservative allow-list: only swallow errors known to leave the session
    /// usable. Anything unrecognized (auth, model access, transport) is fatal so
    /// real failures aren't hidden.
    static func isNonFatal(_ info: Info) -> Bool {
        let haystack = (info.code + " " + info.message).lowercased()
        let benign = [
            "no active response",
            "already has an active response",
            "conversation_already_has_active_response",
            "cancellation failed",
            "response_cancel_not_active",
            "buffer is empty",
            "buffer too small",
            "commit_empty",
            "input_audio_buffer_commit_empty"
        ]
        return benign.contains { haystack.contains($0) }
    }
}

enum ThinkTranscriptFilter {
    static let hallucinationPhrases: Set<String> = [
        "thank you",
        "thank you very much",
        "thanks",
        "thanks for watching",
        "thank you for watching",
        "thanks for listening",
        "thank you for listening",
        "please subscribe",
        "see you next time",
        "you",
        "bye",
        "okay"
    ]

    /// gpt-4o-mini-transcribe hallucinates stock phrases on near-silence; this
    /// flags whole-string matches only, so genuine short answers aren't dropped.
    static func isLikelyHallucination(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?…"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.isEmpty {
            return true
        }
        return hallucinationPhrases.contains(normalized)
    }
}
