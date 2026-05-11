import SwiftUI

/// Modal sheet presented from `CaptureView` so the parent can record a
/// voice memo. The active `TranscriptionEngine` (Apple SFSpeechRecognizer
/// on device, mock on simulator) transcribes live in German; on stop the
/// transcript is handed back to `CaptureView` via the `onAdopt` callback
/// and the sheet dismisses.
struct VoiceRecorderView: View {
    /// Callback invoked when the parent taps "Übernehmen". Receives the
    /// final transcript and the audio filename (basename only, joined
    /// with `Documents/voice/` at playback time).
    let onAdopt: (_ transcript: String, _ audioFilename: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = VoiceRecorderViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                statusRow
                    .padding(.horizontal)

                ScrollView {
                    Text(model.displayedTranscript.isEmpty
                         ? L10n.t("voice.placeholder")
                         : model.displayedTranscript)
                        .font(.body)
                        .foregroundStyle(model.displayedTranscript.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                if case .failed(let message) = model.phase {
                    Label {
                        Text(message)
                            .font(.callout)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    .padding(.horizontal)
                }

                recordButton
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            .navigationTitle(L10n.key("voice.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("app.cancel")) {
                        model.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("voice.adopt")) {
                        let transcript = model.finalText
                        let filename = model.recordingURL?.lastPathComponent
                        onAdopt(transcript, filename)
                        dismiss()
                    }
                    .disabled(model.phase != .stopped || model.finalText.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.phase {
        case .idle:
            Label(L10n.t("voice.state.idle"), systemImage: "mic")
                .foregroundStyle(.secondary)
        case .preparing:
            Label {
                Text(L10n.key("voice.state.preparing"))
            } icon: {
                ProgressView()
            }
        case .recording:
            Label {
                Text(L10n.key("voice.state.recording"))
            } icon: {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
            }
        case .stopped:
            Label(L10n.t("voice.state.stopped"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        switch model.phase {
        case .idle, .stopped, .failed:
            Button {
                model.startRecording()
            } label: {
                Label(L10n.t("voice.start"), systemImage: "mic.fill")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        case .preparing:
            Button {} label: {
                HStack {
                    ProgressView()
                    Text(L10n.key("voice.state.preparing"))
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)
        case .recording:
            Button {
                model.stopRecording()
            } label: {
                Label(L10n.t("voice.stop"), systemImage: "stop.fill")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }
}
