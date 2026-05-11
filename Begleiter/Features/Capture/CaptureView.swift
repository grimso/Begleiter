import SwiftData
import SwiftUI

/// Text-only journal capture screen.
///
/// Iteration 3: parent types German text describing a visit/event,
/// optionally adjusts the visit date, and taps "Eintrag analysieren".
/// Gemma 4 extracts structured fields; the entry is saved and the view
/// dismisses.
///
/// Voice and Befund photo input arrive in iterations 4 and 5.
struct CaptureView: View {
    let child: ChildState

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var model = CaptureViewModel()
    @State private var presentingVoiceRecorder = false
    @FocusState private var textFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        L10n.t("capture.visitDate"),
                        selection: $model.visitDate,
                        in: ...Date.now,
                        displayedComponents: .date
                    )
                } header: {
                    Text(L10n.key("capture.context.header"))
                } footer: {
                    Text(phaseFooter)
                }

                Section {
                    TextEditor(text: $model.text)
                        .frame(minHeight: 180)
                        .focused($textFocused)
                        .disabled(model.isBusy)
                    Button {
                        textFocused = false
                        presentingVoiceRecorder = true
                    } label: {
                        Label(L10n.t("capture.voice.button"), systemImage: "mic.fill")
                    }
                    .disabled(model.isBusy)
                } header: {
                    Text(L10n.key("capture.text.header"))
                } footer: {
                    Text(L10n.key("capture.text.footer"))
                }

                if case .failed(let message) = model.phase {
                    Section {
                        Label {
                            Text(message)
                                .font(.callout)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section {
                    Button {
                        textFocused = false
                        model.submit(child: child, context: modelContext)
                    } label: {
                        HStack {
                            if model.isBusy {
                                ProgressView()
                                Text(busyLabel)
                            } else {
                                Text(L10n.key("capture.submit"))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.canSubmit)
                }
            }
            .navigationTitle(L10n.key("capture.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("app.cancel")) { dismiss() }
                        .disabled(model.isBusy)
                }
            }
            .onChange(of: model.phase) { _, new in
                if case .done = new { dismiss() }
            }
            .onAppear { textFocused = true }
            .sheet(isPresented: $presentingVoiceRecorder) {
                VoiceRecorderView { transcript, audioFilename in
                    // Append to whatever's already in the text field so
                    // voice + typed text compose cleanly. The parent can
                    // still edit before tapping "Eintrag analysieren".
                    let prefix = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.text = prefix.isEmpty ? transcript : prefix + "\n" + transcript
                    model.voiceTranscript = transcript
                    model.voiceAudioFilename = audioFilename
                }
            }
        }
    }

    private var phaseFooter: String {
        let info = child.currentPhaseInfo()
        let phaseLabel = NSLocalizedString("phase.\(info.phase.rawValue).label", comment: "")
        return String(
            format: L10n.t("capture.context.footer"),
            phaseLabel,
            info.dayInPhase
        )
    }

    private var busyLabel: String {
        switch model.phase {
        case .extracting: return L10n.t("capture.busy.extracting")
        case .saving:     return L10n.t("capture.busy.saving")
        default:          return ""
        }
    }
}
