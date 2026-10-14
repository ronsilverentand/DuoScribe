import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            HStack(spacing: 0) {
                column(for: .me)
                Divider()
                column(for: .them)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 440)
    }

    private func column(for speaker: Speaker) -> some View {
        TranscriptColumn(
            speaker: speaker,
            lines: model.lines.filter { $0.speaker == speaker },
            partial: model.partials[speaker],
            level: model.levels[speaker] ?? 0,
            isRunning: model.isRunning
        )
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                model.toggle()
            } label: {
                Label(model.isRunning ? "Stop" : "Start", systemImage: model.isRunning ? "stop.fill" : "record.circle")
                    .frame(minWidth: 72)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(model.isRunning ? Color.red : Color.accentColor)
            .disabled(!model.canToggle)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Start or stop transcribing (Command-Return)")

            Picker("Language", selection: $model.languageMode) {
                ForEach(LanguageMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Auto detects Dutch or English per sentence. Pick one language if detection gets it wrong.")

            Toggle("Filter speaker echo", isOn: $model.echoFilter)
                .toggleStyle(.checkbox)
                .help("Without headphones the microphone also hears the other side. This drops microphone lines that repeat what was playing.")

            Spacer(minLength: 12)

            status
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var status: some View {
        switch model.modelStatus {
        case .idle:
            Text("Speech model not loaded")
                .foregroundStyle(.secondary)
        case .downloading(let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                    .frame(width: 120)
                Text("Downloading speech model, \(Int(fraction * 100))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing speech model (the first time takes a few minutes)")
                    .foregroundStyle(.secondary)
            }
        case .ready:
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isRunning ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                Text(model.isRunning ? "Listening" : "Ready")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text("Speech model failed: \(message)")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry") {
                    model.loadModel()
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let url = model.transcriptURL {
                Text(model.isRunning ? "Saving to \(url.lastPathComponent)" : "Saved as \(url.lastPathComponent)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("The combined Me/Them transcript is saved in Documents/DuoScribe.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show in Finder") {
                model.revealTranscript()
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// One side of the conversation.
struct TranscriptColumn: View {
    let speaker: Speaker
    let lines: [TranscriptLine]
    let partial: String?
    let level: Float
    let isRunning: Bool

    private let bottomID = "bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if lines.isEmpty && partial == nil {
                            Text(isRunning ? "Waiting for speech" : "Nothing yet")
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(lines) { line in
                            LineView(line: line)
                        }
                        if let partial = partial {
                            Text(partial)
                                .italic()
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: lines.count) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
                .onChange(of: partial) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(speaker.rawValue)
                    .font(.headline)
                Text(speaker.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            LevelMeter(level: level)
                .frame(width: 90, height: 6)
                .opacity(isRunning ? 1 : 0.35)
                .help("Input level. If this stays flat while sound is playing, check the app's permissions.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct LineView: View {
    let line: TranscriptLine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(TranscriptStore.timeFormatter.string(from: line.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(line.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small horizontal bar; the scale is logarithmic like a normal audio meter.
struct LevelMeter: View {
    let level: Float

    private var fraction: CGFloat {
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(Double(level))
        return CGFloat(min(max((decibels + 60) / 60, 0), 1))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(Color.green)
                    .frame(width: geometry.size.width * fraction)
                    .animation(.linear(duration: 0.1), value: fraction)
            }
        }
    }
}
