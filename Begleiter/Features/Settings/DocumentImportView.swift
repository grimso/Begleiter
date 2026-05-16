import OSLog
import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private let docImportViewLog = Logger(
    subsystem: "io.grimso.Begleiter",
    category: "ui.document.import"
)

/// Minimal management surface for the "Dokument-Speicher" (document
/// memory) feature. Lives under Settings → Entwicklung →
/// "Dokumente verwalten" when ``AppSettings.importedDocsEnabled`` is
/// on (default `true` for the submission demo).
///
/// Imports one PDF at a time. Pipeline:
/// 1. `.fileImporter` picks a PDF URL.
/// 2. `OCRLayout.reconstruct(pdfPage:)` pulls layout-aware text from
///    every page (same path `PhotoCaptureViewModel.ingestPDF` uses).
/// 3. `DocumentImportService.importDocument(...)` runs ONE long-context
///    Gemma 4 call that returns title + summary + topical chunks.
/// 4. Result is inserted into SwiftData; the list re-renders.
///
/// No edit UI for chunks — the model is the source of truth. The
/// parent can re-import (replaces by docId is a future iteration; for
/// now a fresh import creates a new row).
struct DocumentImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ImportedDocument.importedAt, order: .reverse)
    private var documents: [ImportedDocument]

    @AppStorage(AppSettings.docImportMaxCharsKey)
    private var docImportMaxChars: Int = AppSettings.defaultDocImportMaxChars

    @State private var importing: Bool = false
    @State private var pickerPresented: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if documents.isEmpty && !importing {
                ContentUnavailableView {
                    Label(L10n.key("docImport.title"),
                          systemImage: "tray.full")
                } description: {
                    Text(L10n.key("docImport.empty"))
                }
            } else {
                List {
                    if importing {
                        Section {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text(L10n.key("docImport.importing"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    Section {
                        ForEach(documents) { doc in
                            documentRow(doc)
                        }
                        .onDelete(perform: deleteDocuments)
                    }
                }
            }
        }
        .navigationTitle(L10n.key("docImport.title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    pickerPresented = true
                } label: {
                    Label(L10n.key("docImport.import"), systemImage: "plus")
                }
                .disabled(importing)
            }
        }
        .fileImporter(
            isPresented: $pickerPresented,
            allowedContentTypes: [UTType.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await ingest(url: url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func documentRow(_ doc: ImportedDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(doc.title)
                .font(.body.weight(.semibold))
            Text(doc.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(doc.importedAt, style: .date)
                Text("·")
                Text(String(
                    format: L10n.t("docImport.row.chunks"),
                    doc.chunks.count
                ))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private func ingest(url: URL) async {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        await MainActor.run {
            errorMessage = nil
            importing = true
        }
        defer {
            Task { @MainActor in importing = false }
        }

        let filename = url.lastPathComponent
        // Step 1: extract layout-aware text via the same path
        // `PhotoCaptureViewModel.ingestPDF` uses.
        let sourceText: String
        do {
            let data = try Data(contentsOf: url)
            guard let document = PDFDocument(data: data) else {
                await MainActor.run {
                    errorMessage = L10n.t("docImport.error.empty")
                }
                return
            }
            let parts = (0..<document.pageCount).compactMap {
                document.page(at: $0).map(OCRLayout.reconstruct(pdfPage:))
            }
            sourceText = parts
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            docImportViewLog.error("PDF read failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run { errorMessage = error.localizedDescription }
            return
        }

        // Step 2: import via the actor.
        do {
            let imported = try await DocumentImportService.shared.importDocument(
                originalFilename: filename,
                sourceText: sourceText,
                maxChars: docImportMaxChars
            )
            await MainActor.run {
                modelContext.insert(imported)
                try? modelContext.save()
            }
        } catch let error as DocumentImportError {
            await MainActor.run {
                errorMessage = error.errorDescription
            }
        } catch {
            docImportViewLog.error("import failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                errorMessage = L10n.t("docImport.error.modelFailed")
            }
        }
    }

    private func deleteDocuments(at offsets: IndexSet) {
        for index in offsets {
            let doc = documents[index]
            modelContext.delete(doc)
        }
        try? modelContext.save()
    }
}
