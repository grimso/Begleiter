import SwiftUI

/// Developer-facing smoke test for iteration 2: load Gemma 4 (4-bit) on-device,
/// run a single prompt, render the response. Not part of the parent UX.
struct SmokeTestView: View {
    @State private var model = SmokeTestViewModel()

    var body: some View {
        Form {
            Section {
                stateRow
                if isLoading {
                    // The HF HubClient reports progress as files-completed, not
                    // bytes — and the snapshot's largest file (model.safetensors)
                    // is downloaded last, so the byte-accurate fraction stays
                    // ~0 for most of the download. Showing an indeterminate
                    // ProgressView is more honest than a percentage that
                    // doesn't move.
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Button {
                    model.loadModel()
                } label: {
                    Text(L10n.key("debug.smoke.loadButton"))
                        .frame(maxWidth: .infinity)
                }
                .disabled(isLoading)
            } header: {
                Text(L10n.key("debug.smoke.modelSection"))
            } footer: {
                Text(L10n.key("debug.smoke.modelFooter"))
            }

            Section {
                TextField(
                    L10n.t("debug.smoke.promptPlaceholder"),
                    text: $model.prompt,
                    axis: .vertical
                )
                .lineLimit(3...8)
                .disabled(model.isGenerating)

                Button {
                    model.generate()
                } label: {
                    HStack {
                        if model.isGenerating {
                            ProgressView()
                            Text(L10n.key("debug.smoke.generating"))
                        } else {
                            Text(L10n.key("debug.smoke.generateButton"))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(model.isGenerating || isLoading || model.loadState != .loaded)
            } header: {
                Text(L10n.key("debug.smoke.promptSection"))
            }

            if let error = model.errorMessage {
                Section {
                    Label {
                        Text(error)
                            .font(.callout)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }

            if !model.output.isEmpty {
                Section {
                    Text(model.output)
                        .font(.body)
                        .textSelection(.enabled)
                } header: {
                    Text(L10n.key("debug.smoke.outputSection"))
                }
            }
        }
        .navigationTitle(L10n.key("debug.smoke.title"))
    }

    private var isLoading: Bool {
        if case .loading = model.loadState { return true }
        return false
    }

    @ViewBuilder
    private var stateRow: some View {
        switch model.loadState {
        case .idle:
            Label(L10n.t("debug.smoke.state.idle"), systemImage: "circle")
                .foregroundStyle(.secondary)
        case .loading:
            Label(
                L10n.t("debug.smoke.state.downloading"),
                systemImage: "arrow.down.circle"
            )
        case .loaded:
            Label(L10n.t("debug.smoke.state.loaded"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}
