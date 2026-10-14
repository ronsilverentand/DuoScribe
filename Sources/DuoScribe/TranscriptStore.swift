import Foundation

/// Writes the combined Me/Them transcript as a plain text file.
enum TranscriptStore {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DuoScribe", isDirectory: true)
    }

    static func newFileURL(for date: Date) -> URL {
        folder.appendingPathComponent("Transcript \(fileNameFormatter.string(from: date)).txt")
    }

    /// Both speakers merged into one conversation, in the order things were said.
    static func render(lines: [TranscriptLine], started: Date) -> String {
        var text = "Transcript, \(headerFormatter.string(from: started))\n\n"
        for line in lines.sorted(by: { $0.start < $1.start }) {
            text += "[\(timeFormatter.string(from: line.start))] \(line.speaker.rawValue): \(line.text)\n"
        }
        return text
    }

    static func write(lines: [TranscriptLine], started: Date, to url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try render(lines: lines, started: started).write(to: url, atomically: true, encoding: .utf8)
    }

    static let timeFormatter: DateFormatter = makeFormatter("HH:mm:ss")
    private static let fileNameFormatter: DateFormatter = makeFormatter("yyyy-MM-dd HH.mm.ss")
    private static let headerFormatter: DateFormatter = makeFormatter("EEEE d MMMM yyyy, HH:mm")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
