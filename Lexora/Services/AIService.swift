import Foundation
import Observation
import Security

/// Manages optional cloud AI features (GPT-4o mini via OpenAI).
/// The API key is stored exclusively in the iOS Keychain and is never
/// logged, cached, or transmitted anywhere except OpenAI's endpoint.
@Observable @MainActor
final class AIService {

    // MARK: - Keychain

    private static let keychainAccount = "com.yiga.Lexora.openAIKey"

    /// Whether a key is currently stored in the Keychain.
    var hasAPIKey: Bool { nonisolated_loadKey() != nil }

    /// Saves the key to Keychain (replaces any existing value).
    func saveKey(_ key: String) {
        let data = Data(key.trimmingCharacters(in: .whitespaces).utf8)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Removes the stored key from Keychain.
    func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Reads the stored key synchronously (safe to call from any context).
    nonisolated func nonisolated_loadKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Error

    enum AIError: LocalizedError {
        case noKey
        case tooShort
        case networkError(Error)
        case apiError(String)
        case parseError

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "No API key configured. Add your OpenAI key in Settings → AI Features."
            case .tooShort:
                return "The transcript is too short to summarise (need at least 20 words)."
            case .networkError(let e):
                return "Network error: \(e.localizedDescription)"
            case .apiError(let msg):
                return "OpenAI returned an error: \(msg)"
            case .parseError:
                return "Could not parse the AI response. Please try again."
            }
        }
    }

    // MARK: - Summarization

    /// Generates a 2–4 sentence abstractive summary of the transcript.
    /// Transcript text is sent to api.openai.com over TLS and is not stored
    /// by Lexora beyond the lifetime of this call.
    func summarise(transcript: String, language: String) async throws -> String {
        let wordCount = transcript.split(separator: " ").count
        guard wordCount >= 20 else { throw AIError.tooShort }
        guard let key = nonisolated_loadKey() else { throw AIError.noKey }

        let langName = Locale.current.localizedString(forLanguageCode: language) ?? "English"
        let system = """
        You are a concise, neutral assistant. Summarise the following voice-dictation transcript \
        in 2–4 sentences in \(langName). Focus on the main ideas. Do not add opinions or filler.
        """

        let content = try await chat(
            key: key,
            system: system,
            user: transcript,
            maxTokens: 256
        )
        return content
    }

    // MARK: - Action-item extraction

    /// Extracts up to 6 action items / follow-ups from the transcript.
    /// Returns an empty array if none are found.
    func extractActionItems(transcript: String) async throws -> [String] {
        guard transcript.split(separator: " ").count >= 20 else { throw AIError.tooShort }
        guard let key = nonisolated_loadKey() else { throw AIError.noKey }

        let system = """
        Extract concrete action items, tasks, or follow-ups from the voice dictation below. \
        Reply with ONLY a JSON object in this exact format: {"items": ["item1", "item2"]}. \
        Maximum 6 items. If there are none, return {"items": []}.
        """

        let raw = try await chat(key: key, system: system, user: transcript, maxTokens: 300)

        // Strip any markdown fences the model might add
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [String] else {
            return []
        }
        return items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Topic expansion

    /// Suggests 3–5 follow-up questions or angles to explore for the given transcript.
    func suggestFollowUps(transcript: String) async throws -> [String] {
        guard transcript.split(separator: " ").count >= 20 else { throw AIError.tooShort }
        guard let key = nonisolated_loadKey() else { throw AIError.noKey }

        let system = """
        Based on this voice-dictation transcript, suggest 3–5 follow-up questions, \
        deeper angles, or related topics the speaker might want to explore next. \
        Reply with ONLY: {"suggestions": ["question1", "question2"]}
        """

        let raw = try await chat(key: key, system: system, user: transcript, maxTokens: 300)
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["suggestions"] as? [String] else {
            return []
        }
        return items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Private HTTP helper

    private func chat(
        key: String,
        system: String,
        user: String,
        maxTokens: Int
    ) async throws -> String {
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": user]
            ],
            "max_tokens": maxTokens,
            "temperature": 0.3
        ]

        var request = URLRequest(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AIError.networkError(error)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let serverMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String }
                ?? "HTTP \(http.statusCode)"
            throw AIError.apiError(serverMsg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.parseError
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
