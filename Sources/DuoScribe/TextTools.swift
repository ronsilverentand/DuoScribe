import Foundation

enum TextTools {
    /// Phrases Whisper tends to produce from noise or music (it learned them from subtitle credits).
    private static let hallucinationMarkers = [
        "amara.org",
        "ondertitels ingediend",
        "ondertiteld door",
        "ondertiteling:",
        "tv gelderland",
        "subtitles by",
        "transcribed by",
        "transcription by",
    ]

    /// Tidies raw model output; returns an empty string when there is nothing worth showing.
    static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\n", with: " ")
        // Non-speech tags such as [MUZIEK], (applaus), *zucht* and leftover <|tokens|>.
        text = text.replacingOccurrences(
            of: #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*|<\|[^|]*\|>"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let lowered = text.lowercased()
        if hallucinationMarkers.contains(where: { lowered.contains($0) }) {
            return ""
        }
        return words(in: text).isEmpty ? "" : text
    }

    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// True when most words of `candidate` also occur in `reference`:
    /// the microphone picked up what was playing through the speakers.
    static func isEcho(candidate: String, reference: String) -> Bool {
        let candidateWords = words(in: candidate)
        guard candidateWords.count >= 2 else { return false }

        var available: [String: Int] = [:]
        for word in words(in: reference) {
            available[word, default: 0] += 1
        }
        var matched = 0
        for word in candidateWords {
            if let count = available[word], count > 0 {
                available[word] = count - 1
                matched += 1
            }
        }
        return Double(matched) / Double(candidateWords.count) >= 0.6
    }
}
