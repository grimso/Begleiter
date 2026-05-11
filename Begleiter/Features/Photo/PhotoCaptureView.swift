import PhotosUI
import SwiftUI

/// Modal sheet for picking a Befund photo. Behind the scenes:
/// 1. `PhotosPicker` selects the image.
/// 2. `PhotoCaptureViewModel` ingests the bytes and runs the
///    `PhotoExtractionEngine` (Apple Vision OCR on device, mock on
///    simulator).
/// 3. The parent reviews the recognised text + thumbnail and taps
///    **Übernehmen**.
/// 4. `onAdopt` callback returns the raw JPEG data + recognised text to
///    `CaptureView`, which persists the photo via `PhotoStorage` and
///    appends the OCR text to the entry's text field for the parent to
///    edit before extraction.
struct PhotoCaptureView: View {
    /// Hand-off to caller: (imageData, recognisedText).
    let onAdopt: (_ imageData: Data, _ recognisedText: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = PhotoCaptureViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(
                        selection: $model.pickerItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label(
                            model.pickerItem == nil
                                ? L10n.t("photo.pick")
                                : L10n.t("photo.pickAnother"),
                            systemImage: "photo.on.rectangle"
                        )
                    }
                } footer: {
                    Text(L10n.key("photo.pickFooter"))
                }

                if let preview = model.previewImage {
                    Section {
                        preview
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } header: {
                        Text(L10n.key("photo.previewHeader"))
                    }
                }

                Section {
                    statusRow
                    if case .done(let text, _) = model.phase {
                        Text(text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                    if case .failed(let message) = model.phase {
                        Label {
                            Text(message)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text(L10n.key("photo.ocrHeader"))
                }
            }
            .navigationTitle(L10n.key("photo.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("app.cancel")) {
                        model.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("photo.adopt")) {
                        if let data = model.imageData {
                            onAdopt(data, model.recognisedText)
                        }
                        dismiss()
                    }
                    .disabled(!model.canAdopt)
                }
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.phase {
        case .idle:
            Label(L10n.t("photo.state.idle"), systemImage: "photo")
                .foregroundStyle(.secondary)
        case .processing:
            HStack {
                ProgressView()
                Text(L10n.key("photo.state.processing"))
            }
        case .done(_, let confidence):
            let pct = Int((confidence * 100).rounded())
            Label(
                String(format: L10n.t("photo.state.done"), pct),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .failed:
            EmptyView()
        }
    }
}
