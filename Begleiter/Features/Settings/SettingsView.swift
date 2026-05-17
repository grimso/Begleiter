import SwiftData
import SwiftUI

/// Developer-facing settings for runtime configuration of the Gemma stack.
///
/// Reached via Profile tab → Entwicklung. The user-facing clinical fields
/// (diagnosis date, risk group, arm, current phase) live in the sibling
/// `ClinicalSettingsView` and are not surfaced here.
///
/// Sections:
/// 1. **Modell** — switch Gemma 4 variant (E2B / E4B). Triggers a
///    background reload via `GemmaService.shared.reload(variant:)`.
/// 2. **Generierungslänge** — per-feature `maxTokens` (extraction,
///    briefing, handoff). Read at every inference call site so changes
///    take effect immediately on the next generation.
/// 3. **Befund-Verarbeitung** — pipeline mode. OCR→Gemma is the live
///    path; the multimodal row is rendered but disabled until the
///    MLXVLM hookup ships.
/// 4. **Diagnose** — read-only model identifier + "clear cache" button
///    that forces the next call to reload weights from the local HF
///    cache (no network).
/// 5. **Entwicklung** — developer toggles (latency HUD, ask diagnostics,
///    thinking mode, dense reranker, ask mode picker, document store).
struct SettingsView: View {

    @Environment(\.modelContext) private var modelContext

    // MARK: - Persisted settings

    @AppStorage(AppSettings.modelVariantKey)
    private var modelVariantRaw: String = ModelVariant.e2b.rawValue

    @AppStorage(AppSettings.extractionMaxTokensKey)
    private var extractionMaxTokens: Int = AppSettings.defaultExtractionMaxTokens

    @AppStorage(AppSettings.briefingMaxTokensKey)
    private var briefingMaxTokens: Int = AppSettings.defaultBriefingMaxTokens

    @AppStorage(AppSettings.handoffMaxTokensKey)
    private var handoffMaxTokens: Int = AppSettings.defaultHandoffMaxTokens

    @AppStorage(AppSettings.askMaxTokensKey)
    private var askMaxTokens: Int = AppSettings.defaultAskMaxTokens

    @AppStorage(AppSettings.askAgentMaxTokensKey)
    private var askAgentMaxTokens: Int = AppSettings.defaultAskAgentMaxTokens

    @AppStorage(AppSettings.importedDocsEnabledKey)
    private var importedDocsEnabled: Bool = AppSettings.defaultImportedDocsEnabled

    @AppStorage(AppSettings.docImportMaxCharsKey)
    private var docImportMaxChars: Int = AppSettings.defaultDocImportMaxChars

    @AppStorage(AppSettings.askDiagnosticsEnabledKey)
    private var askDiagnosticsEnabled: Bool = AppSettings.defaultAskDiagnosticsEnabled

    @AppStorage(AppSettings.askThinkingEnabledKey)
    private var askThinkingEnabled: Bool = AppSettings.defaultAskThinkingEnabled

    @AppStorage(AppSettings.askDenseRerankerEnabledKey)
    private var askDenseRerankerEnabled: Bool = AppSettings.defaultAskDenseRerankerEnabled

    @AppStorage(AppSettings.askEventGuardEnabledKey)
    private var askEventGuardEnabled: Bool = AppSettings.defaultAskEventGuardEnabled

    @AppStorage(AppSettings.askTimelinePackEnabledKey)
    private var askTimelinePackEnabled: Bool = AppSettings.defaultAskTimelinePackEnabled

    @AppStorage(AppSettings.askAgentEnabledKey)
    private var askAgentEnabled: Bool = AppSettings.defaultAskAgentEnabled

    @AppStorage(AppSettings.askModeKey)
    private var askModeRaw: String = AskMode.chat.rawValue

    @AppStorage(AppSettings.labPipelineModeKey)
    private var labPipelineModeRaw: String = LabPipelineMode.ocrThenGemma.rawValue

    @AppStorage(AppSettings.visionMaxLongEdgeKey)
    private var visionMaxLongEdge: Int = AppSettings.defaultVisionMaxLongEdge

    @AppStorage(AppSettings.latencyHUDEnabledKey)
    private var latencyHUDEnabled: Bool = AppSettings.defaultLatencyHUDEnabled

    // MARK: - Transient state

    @State private var modelReloading: Bool = false
    @State private var fellBackToE2BMessage: String?
    @State private var cacheClearedFlash: Bool = false
    @State private var memorySnapshot: MemoryDiagnostics.UISnapshot = MemoryDiagnostics.uiSnapshot()
    @State private var showDemoLoadConfirm: Bool = false
    @State private var showDemoResetConfirm: Bool = false
    @State private var demoOutcomeMessage: String?

    // MARK: - Derived bindings

    /// Bridge the raw-string `@AppStorage` into a typed `Binding<ModelVariant>`
    /// for the picker. Writes both directions so the picker stays in sync
    /// with any external mutation (e.g. the fall-back demotion in
    /// `GemmaService.reload(variant:)`).
    private var modelVariant: Binding<ModelVariant> {
        Binding(
            get: { ModelVariant(rawValue: modelVariantRaw) ?? .e2b },
            set: { newValue in
                let previous = modelVariantRaw
                modelVariantRaw = newValue.rawValue
                guard previous != newValue.rawValue else { return }
                Task { await applyModelChange(newValue) }
            }
        )
    }

    private var labPipelineMode: Binding<LabPipelineMode> {
        Binding(
            get: { LabPipelineMode(rawValue: labPipelineModeRaw) ?? .ocrThenGemma },
            set: { labPipelineModeRaw = $0.rawValue }
        )
    }

    private var askMode: Binding<AskMode> {
        Binding(
            get: { AskMode(rawValue: askModeRaw) ?? .chat },
            set: { askModeRaw = $0.rawValue }
        )
    }

    // MARK: - Body

    var body: some View {
        Form {
            modelSection
            generationSection
            labSection
            diagnosticsSection
            developerSection
        }
        .scrollContentBackground(.hidden)
        .background(Color("BegleiterBackground").ignoresSafeArea())
        .listRowBackground(Color("BegleiterCardSurface"))
        .navigationTitle(L10n.key("settings.entwicklung.title"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            L10n.t("settings.model.fellBackTitle"),
            isPresented: Binding(
                get: { fellBackToE2BMessage != nil },
                set: { if !$0 { fellBackToE2BMessage = nil } }
            )
        ) {
            Button(L10n.t("app.done"), role: .cancel) { fellBackToE2BMessage = nil }
        } message: {
            Text(fellBackToE2BMessage ?? "")
        }
    }

    // MARK: - Sections

    private var modelSection: some View {
        Section {
            Picker(selection: modelVariant) {
                Text(L10n.key("settings.model.e2b")).tag(ModelVariant.e2b)
                Text(L10n.key("settings.model.e4b")).tag(ModelVariant.e4b)
            } label: {
                Text(L10n.key("settings.model.picker"))
            }
            .disabled(modelReloading)

            if modelReloading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.key("settings.model.applying"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L10n.key("settings.model.section"))
        } footer: {
            Text(L10n.key("settings.model.footer"))
        }
    }

    private var generationSection: some View {
        Section {
            tokenStepper(
                title: L10n.t("settings.generation.extraction"),
                value: $extractionMaxTokens,
                range: 512...4096,
                step: 256
            )
            tokenStepper(
                title: L10n.t("settings.generation.briefing"),
                value: $briefingMaxTokens,
                range: 256...2048,
                step: 128
            )
            tokenStepper(
                title: L10n.t("settings.generation.handoff"),
                value: $handoffMaxTokens,
                range: 256...2048,
                step: 128
            )
            tokenStepper(
                title: L10n.t("settings.generation.ask"),
                value: $askMaxTokens,
                range: 256...8192,
                step: 256
            )
            tokenStepper(
                title: L10n.t("settings.generation.askAgent"),
                value: $askAgentMaxTokens,
                range: 1024...8192,
                step: 256
            )
        } header: {
            Text(L10n.key("settings.generation.section"))
        } footer: {
            Text(L10n.key("settings.generation.footer"))
        }
    }

    /// Single-row `Stepper` with the value shown inline. Steppers are the
    /// honest control here — sliders would suggest continuous tuning, but
    /// `maxTokens` is meaningful only at coarse granularity.
    private func tokenStepper(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Custom picker because SwiftUI's built-in `Picker` cannot decorate
    /// individual rows. Both modes are functional today; the multimodal
    /// row carries an "Experimentell" tag because it loads a second copy
    /// of Gemma 4 (vision tower) and has had less testing on real Befund
    /// photos. Default stays `.ocrThenGemma` so existing users see no
    /// behavior change after the update.
    private var labSection: some View {
        Section {
            labRow(
                title: L10n.t("settings.lab.ocr"),
                mode: .ocrThenGemma,
                badge: nil,
                enabled: true
            )
            labRow(
                title: L10n.t("settings.lab.multimodal"),
                mode: .directMultimodal,
                badge: L10n.t("settings.lab.experimentalBadge"),
                enabled: true
            )
            // Only show the long-edge slider when the multimodal path
            // is actually selected — the OCR path doesn't pass images
            // through to Gemma so the setting would be inert there.
            if labPipelineMode.wrappedValue == .directMultimodal {
                Stepper(value: $visionMaxLongEdge, in: 768...2048, step: 128) {
                    HStack {
                        Text(L10n.key("settings.lab.maxLongEdge"))
                        Spacer()
                        Text("\(visionMaxLongEdge) px")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(L10n.key("settings.lab.section"))
        } footer: {
            Text(L10n.key("settings.lab.footer"))
        }
    }

    private func labRow(
        title: String,
        mode: LabPipelineMode,
        badge: String?,
        enabled: Bool
    ) -> some View {
        Button {
            guard enabled else { return }
            labPipelineMode.wrappedValue = mode
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(enabled ? .primary : .secondary)
                if let badge {
                    Text(badge)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if labPipelineMode.wrappedValue == mode {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var diagnosticsSection: some View {
        Section {
            LabeledContent(L10n.t("settings.diagnostics.model")) {
                Text(modelVariant.wrappedValue.displayName)
                    .foregroundStyle(.secondary)
            }
            LabeledContent(L10n.t("settings.diagnostics.modelId")) {
                Text(modelVariant.wrappedValue.modelId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            LabeledContent(L10n.t("settings.diagnostics.mlxVersion")) {
                Text(Self.mlxSwiftLmVersion)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LabeledContent(L10n.t("settings.diagnostics.memoryCeiling")) {
                Text(Self.formatBytes(memorySnapshot.ceiling))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LabeledContent(L10n.t("settings.diagnostics.memoryResident")) {
                Text(Self.formatBytes(memorySnapshot.resident))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let appliedAt = AppSettings.demoDefaultsAppliedAt {
                LabeledContent(L10n.t("settings.diagnostics.demoDefaultsAppliedAt")) {
                    Text(appliedAt.formatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                memorySnapshot = MemoryDiagnostics.uiSnapshot()
            } label: {
                Label(L10n.key("settings.diagnostics.memoryRefresh"),
                      systemImage: "arrow.clockwise")
            }
            Label(L10n.key("settings.diagnostics.memoryHint"),
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await clearCache() }
            } label: {
                HStack {
                    Text(L10n.key("settings.diagnostics.clearCache"))
                    Spacer()
                    if cacheClearedFlash {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .disabled(modelReloading)
        } header: {
            Text(L10n.key("settings.diagnostics.section"))
        } footer: {
            Text(L10n.key("settings.diagnostics.clearCacheFooter"))
        }
    }

    /// Developer-facing entries that don't belong on a parent's top bar.
    /// Houses the model smoke-test moved out of the TimelineView toolbar
    /// so the toolbar can host the new "Fragen" entry without overflowing
    /// on small iPhones.
    private var developerSection: some View {
        Section {
            NavigationLink {
                SmokeTestView()
            } label: {
                Label(L10n.key("settings.developer.smokeTest"),
                      systemImage: "brain.head.profile")
            }
            Toggle(isOn: $askDiagnosticsEnabled) {
                Label(L10n.key("settings.developer.askDiagnostics"),
                      systemImage: "stethoscope")
            }
            Toggle(isOn: $latencyHUDEnabled) {
                Label(L10n.key("settings.developer.latencyHUD"),
                      systemImage: "stopwatch")
            }
            if latencyHUDEnabled {
                Label(L10n.key("settings.developer.latencyHUD.hint"),
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: $askThinkingEnabled) {
                Label(L10n.key("settings.developer.askThinking"),
                      systemImage: "brain")
            }
            if askThinkingEnabled && askMaxTokens < 1024 {
                Label(L10n.key("settings.developer.askThinking.budgetHint"),
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle(isOn: $askDenseRerankerEnabled) {
                Label(L10n.key("settings.developer.askDenseReranker"),
                      systemImage: "rectangle.stack.badge.plus")
            }
            if askDenseRerankerEnabled {
                Label(L10n.key("settings.developer.askDenseReranker.firstLaunchHint"),
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button {
                Task { await clearRerankerCache() }
            } label: {
                Label(L10n.key("settings.developer.askDenseReranker.clearCache"),
                      systemImage: "trash")
            }
            .disabled(!askDenseRerankerEnabled)
            Toggle(isOn: $askTimelinePackEnabled) {
                Label(L10n.key("settings.developer.askTimelinePack"),
                      systemImage: "clock.arrow.circlepath")
            }
            if askTimelinePackEnabled {
                Label(L10n.key("settings.developer.askTimelinePack.hint"),
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: $askEventGuardEnabled) {
                Label(L10n.key("settings.developer.askEventGuard"),
                      systemImage: "calendar.badge.exclamationmark")
            }
            // Picker intentionally omits `.mlxToolCall` — that mode is the
            // broken-upstream evidence path (see
            // `docs/upstream-issue-gemma4-toolcall.md`). The enum case + the
            // engine code stay so the existing UserDefaults migration in
            // `AppSettings.askMode` still resolves cleanly for legacy
            // installs; we just don't expose it as a parent-facing option.
            Picker(selection: askMode) {
                Text(L10n.key("settings.developer.askMode.chat")).tag(AskMode.chat)
                Text(L10n.key("settings.developer.askMode.customAgent")).tag(AskMode.customAgent)
            } label: {
                Label(L10n.key("settings.developer.askMode"),
                      systemImage: "wrench.and.screwdriver")
            }
            if askMode.wrappedValue == .customAgent {
                Label(L10n.key("settings.developer.askMode.customAgent.hint"),
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if askMode.wrappedValue != .chat && askAgentMaxTokens < 2048 {
                Label(L10n.key("settings.developer.askMode.budgetHint"),
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle(isOn: $importedDocsEnabled) {
                Label(L10n.key("settings.developer.importedDocs"),
                      systemImage: "doc.text.magnifyingglass")
            }
            if importedDocsEnabled {
                Stepper(value: $docImportMaxChars, in: 4000...64000, step: 2000) {
                    HStack {
                        Text(L10n.key("settings.developer.docImportMaxChars"))
                        Spacer()
                        Text("\(docImportMaxChars)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    DocumentImportView()
                } label: {
                    Label(L10n.key("settings.developer.documentStore"),
                          systemImage: "tray.full")
                }
            }
            // Demo data loader. Surfaces a confirmation alert so a parent
            // can't accidentally overwrite real data; the loader itself
            // refuses to write when any child / entry / document already
            // exists, but the alert is the parent-facing safety net.
            Button {
                showDemoLoadConfirm = true
            } label: {
                Label(L10n.key("settings.developer.demoData.load"),
                      systemImage: "sparkles.rectangle.stack")
            }
            Button(role: .destructive) {
                showDemoResetConfirm = true
            } label: {
                Label(L10n.key("settings.developer.demoData.reset"),
                      systemImage: "trash")
            }
            if let message = demoOutcomeMessage {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.key("settings.developer.section"))
        } footer: {
            Text(L10n.key("settings.developer.footer"))
        }
        .confirmationDialog(
            L10n.key("settings.developer.demoData.loadConfirm.title"),
            isPresented: $showDemoLoadConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("settings.developer.demoData.loadConfirm.action")) {
                let outcome = DemoDataLoader.loadDemoDataset(into: modelContext)
                demoOutcomeMessage = Self.formatDemoOutcome(outcome)
            }
            Button(L10n.t("app.cancel"), role: .cancel) { }
        } message: {
            Text(L10n.key("settings.developer.demoData.loadConfirm.message"))
        }
        .confirmationDialog(
            L10n.key("settings.developer.demoData.resetConfirm.title"),
            isPresented: $showDemoResetConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("settings.developer.demoData.resetConfirm.action"), role: .destructive) {
                let outcome = DemoDataLoader.resetAllData(in: modelContext)
                demoOutcomeMessage = Self.formatDemoOutcome(outcome)
            }
            Button(L10n.t("app.cancel"), role: .cancel) { }
        } message: {
            Text(L10n.key("settings.developer.demoData.resetConfirm.message"))
        }
    }

    /// User-facing summary of a `DemoDataLoader.Outcome`. Kept terse so
    /// it fits in a `.caption` Label under the buttons.
    private static func formatDemoOutcome(_ outcome: DemoDataLoader.Outcome) -> String {
        switch outcome {
        case .loaded(let entries, let documents):
            if entries == 0 && documents == 0 {
                return L10n.t("settings.developer.demoData.outcome.reset")
            }
            let format = L10n.t("settings.developer.demoData.outcome.loaded")
            return String(format: format, entries, documents)
        case .alreadyPopulated:
            return L10n.t("settings.developer.demoData.outcome.alreadyPopulated")
        case .failed(let reason):
            let format = L10n.t("settings.developer.demoData.outcome.failed")
            return String(format: format, reason)
        }
    }

    /// Clear the corpus + journal embedding caches. Called from the
    /// "Embedding-Cache leeren" button under the dense-rerank toggle.
    /// On the next reranked question the embedder rebuilds all vectors.
    @MainActor
    private func clearRerankerCache() async {
        CorpusService.shared.clearCachedVectors()
        // Zero all journal entry embeddings via a single SwiftData
        // transaction. The next rerank call repopulates lazily.
        let descriptor = FetchDescriptor<JournalEntry>()
        if let entries = try? modelContext.fetch(descriptor) {
            for entry in entries where !entry.embedding.isEmpty {
                entry.embedding = []
            }
            try? modelContext.save()
        }
    }

    // MARK: - Actions

    /// Apply a model-variant change. Toggles the in-flight flag for the
    /// duration of the reload, surfaces the soft fall-back error if E4B
    /// couldn't load, and ensures `modelVariantRaw` reflects the
    /// effective state (`GemmaService` persists the demotion itself but
    /// the picker reads the raw key, so this lines up automatically).
    private func applyModelChange(_ variant: ModelVariant) async {
        modelReloading = true
        defer { modelReloading = false }
        do {
            try await GemmaService.shared.reload(variant: variant)
        } catch let fallback as GemmaReloadError {
            fellBackToE2BMessage = fallback.errorDescription
            // Re-sync the picker — GemmaService already persisted .e2b.
            modelVariantRaw = ModelVariant.e2b.rawValue
        } catch {
            fellBackToE2BMessage = error.localizedDescription
        }
    }

    /// Drop the in-memory model. Next inference pulls from the local HF
    /// cache (~3–5 s). Used when the user wants to free memory without
    /// changing the variant — for example, between long generations on
    /// an older device.
    private func clearCache() async {
        await GemmaService.shared.unload()
        cacheClearedFlash = true
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        cacheClearedFlash = false
    }

    // MARK: - Diagnostics constants

    /// Pinned `mlx-swift-lm` version. No runtime API to introspect, so we
    /// surface the value from `Package.resolved` as a constant. Bump this
    /// when bumping the package pin so the Diagnostics view stays honest.
    private static let mlxSwiftLmVersion = "3.31.3"

    /// Bytes → human-readable string (MB up to 1024 MB, then GB). Used by
    /// the memory rows in the Diagnose section so the parent reads
    /// "2940 MB" rather than 3 081 207 808.
    private static func formatBytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "—" }
        let mb = Double(bytes) / (1024 * 1024)
        if mb < 1024 {
            return String(format: "%.0f MB", mb)
        }
        return String(format: "%.2f GB", mb / 1024)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
