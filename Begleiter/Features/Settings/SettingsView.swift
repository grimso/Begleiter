import SwiftUI

/// User-facing settings for runtime configuration of the Gemma stack.
///
/// Four sections:
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
struct SettingsView: View {

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

    @AppStorage(AppSettings.labPipelineModeKey)
    private var labPipelineModeRaw: String = LabPipelineMode.ocrThenGemma.rawValue

    // MARK: - Transient state

    @State private var modelReloading: Bool = false
    @State private var fellBackToE2BMessage: String?
    @State private var cacheClearedFlash: Bool = false

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

    // MARK: - Body

    var body: some View {
        Form {
            modelSection
            generationSection
            labSection
            diagnosticsSection
            developerSection
        }
        .navigationTitle(L10n.key("settings.title"))
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
                range: 256...1024,
                step: 128
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

    /// Custom picker because SwiftUI's built-in `Picker` cannot disable
    /// individual rows. We render two button rows ourselves with a
    /// trailing checkmark and an explicit `.disabled` on the multimodal
    /// row plus a "Bald verfügbar" tag.
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
                badge: L10n.t("settings.lab.comingSoon"),
                enabled: false
            )
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
        } header: {
            Text(L10n.key("settings.developer.section"))
        } footer: {
            Text(L10n.key("settings.developer.footer"))
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
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
