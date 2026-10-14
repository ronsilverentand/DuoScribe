import Foundation

/// Which side of the conversation a piece of text came from.
enum Speaker: String, CaseIterable, Hashable {
    case me = "Me"
    case them = "Them"

    var subtitle: String {
        switch self {
        case .me: return "Microphone"
        case .them: return "Speakers / headphones"
        }
    }
}

/// One finished utterance.
struct TranscriptLine: Identifiable, Equatable {
    let id = UUID()
    let speaker: Speaker
    let start: Date
    let end: Date
    let text: String
}

enum LanguageMode: String, CaseIterable, Identifiable {
    case auto
    case dutch
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto NL/EN"
        case .dutch: return "Nederlands"
        case .english: return "English"
        }
    }

    /// Whisper language code, or nil to let the model detect it.
    var code: String? {
        switch self {
        case .auto: return nil
        case .dutch: return "nl"
        case .english: return "en"
        }
    }
}

enum ModelStatus: Equatable {
    case idle
    case downloading(Double)
    case loading
    case ready
    case failed(String)
}

enum CaptureError: LocalizedError {
    case coreAudio(String, Int32)
    case unsupportedFormat
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .coreAudio(let what, let status):
            return "Core Audio error \(status) while \(what)."
        case .unsupportedFormat:
            return "The system audio stream has a format this app does not handle."
        case .noInputDevice:
            return "No microphone was found."
        }
    }
}
