import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Modal sheet for picking a Befund attachment. Two sources:
/// 1. **PhotosPicker** — photos in the Photos library.
/// 2. **.fileImporter** — Files app, iCloud Drive, Downloads, etc.
///    Accepts `.image` and `.pdf`. PDFs go through PDFKit's embedded-text
///    extraction (no OCR needed when text is digital) and fall back to
///    rendering page 1 for Vision OCR if the PDF is image-only.
///
/// Once extracted, `onAdopt` returns the raw file bytes + recognised text
/// + the file extension to use when persisting. `CaptureView` persists
/// via `PhotoStorage` and appends the recognised text to the entry's
/// text field for the parent to edit before Gemma extraction.
struct PhotoCaptureView: View {
    /// Hand-off to caller: (fileData, recognisedText, fileExtension).
    /// `fileExtension` is the original extension ("jpg", "pdf", "png", …)
    /// so the file survives in its native format on disk.
    let onAdopt: (_ fileData: Data, _ recognisedText: String, _ fileExtension: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = PhotoCaptureViewModel()
    @State private var presentingFileImporter = false

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
                    Button {
                        presentingFileImporter = true
                    } label: {
                        Label(L10n.t("photo.pickFile"), systemImage: "doc")
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
                } footer: {
                    Text(L10n.key("photo.ocrFooter"))
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
                            onAdopt(data, model.recognisedText, model.fileExtension)
                        }
                        dismiss()
                    }
                    .disabled(!model.canAdopt)
                }
            }
            .fileImporter(
                isPresented: $presentingFileImporter,
                allowedContentTypes: [.image, .pdf]
            ) { result in
                switch result {
                case .success(let url):
                    model.ingest(fileURL: url)
                case .failure(let error):
                    // The picker reports cancellation as a failure with a
                    // specific code; treat it as a no-op rather than a
                    // visible error.
                    if (error as NSError).code != NSUserCancelledError {
                        // Surface other errors via the view model's
                        // failed state — easier to display consistently.
                        Task { @MainActor in
                            await model.surfaceFileImporterError(error.localizedDescription)
                        }
                    }
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
