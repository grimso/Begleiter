import SwiftData
import SwiftUI

struct HandoffDocumentView: View {
    let child: ChildState

    @Query(sort: \JournalEntry.visitDate, order: .reverse) private var entries: [JournalEntry]
    @State private var model = HandoffViewModel()
    @State private var presentingShare = false
    @State private var shareableText: String = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L10n.key("handoff.title"))
                .toolbar {
                    if case .done = model.state {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                shareableText = Self.plainText(of: currentDocument!)
                                presentingShare = true
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel(L10n.t("handoff.share"))
                        }
                    }
                }
                .sheet(isPresented: $presentingShare) {
                    ShareSheet(items: [shareableText])
                }
                .scrollContentBackground(.hidden)
                .background(Color("BegleiterBackground").ignoresSafeArea())
        }
    }

    private var currentDocument: HandoffDocument? {
        if case .done(let doc) = model.state { return doc }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            controlsForm
        case .generating:
            VStack(spacing: 16) {
                ProgressView()
                Text(L10n.key("handoff.generating"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                .padding()
                Button(L10n.t("handoff.retry")) {
                    model.reset()
                }
            }
        case .done(let doc):
            documentForm(doc)
        }
    }

    private var controlsForm: some View {
        Form {
            Section {
                Picker(selection: $model.language) {
                    ForEach([HandoffLanguage.german, .english], id: \.self) { lang in
                        Text(lang.humanLabel).tag(lang)
                    }
                } label: {
                    Text(L10n.key("handoff.language"))
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L10n.key("handoff.options"))
            } footer: {
                Text(L10n.key("handoff.footer"))
            }
            .listRowBackground(Color("BegleiterCardSurface"))

            Section {
                Button {
                    model.generate(child: child, entries: entries)
                } label: {
                    Text(L10n.key("handoff.generate"))
                        .frame(maxWidth: .infinity)
                }
                .disabled(entries.isEmpty)
            }
            .listRowBackground(Color("BegleiterCardSurface"))
        }
    }

    private func documentForm(_ doc: HandoffDocument) -> some View {
        Form {
            // Same clinical-validation disclaimer the briefing surface
            // ships. The handoff is a clinician-facing document but
            // still draws phase / risk-group / drug labels from the
            // CLINICAL-REVIEW-marked `PhaseMetadata` tables; pinning
            // the disclaimer here keeps the receiving doctor honest
            // about what's auditable code vs what needs advisor sweep.
            Section {
                Label {
                    Text(L10n.key("briefing.disclaimer.protocolUnreviewed"))
                        .font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                }
            }
            .listRowBackground(Color.orange.opacity(0.08))

            Section {
                LabeledContent(L10n.t("handoff.field.patientId"), value: doc.patientId)
                LabeledContent(L10n.t("handoff.field.diagnose"), value: doc.diagnose)
                LabeledContent(L10n.t("handoff.field.riskGroup"), value: doc.riskGroupLabel)
                LabeledContent(L10n.t("handoff.field.arm"), value: doc.randomizationLabel)
                LabeledContent(L10n.t("handoff.field.phase"), value: doc.phaseLabel)
                LabeledContent(L10n.t("handoff.field.dayInPhase"), value: "\(doc.dayInPhase)")
            } header: {
                Text(L10n.key("handoff.section.identification"))
            }
            .listRowBackground(Color("BegleiterCardSurface"))

            if !doc.behandlungsverlauf.isEmpty {
                Section {
                    ForEach(doc.behandlungsverlauf, id: \.self) { claim in
                        Self.claimRow(claim)
                    }
                } header: {
                    Text(L10n.key("handoff.section.history"))
                }
                .listRowBackground(Color("BegleiterCardSurface"))
            }

            if !doc.aktuelleLabore.isEmpty {
                Section {
                    ForEach(doc.aktuelleLabore, id: \.self) { line in
                        HStack {
                            Text(line.germanLabel)
                            Spacer()
                            Text(line.value).font(.body.monospacedDigit())
                        }
                    }
                } header: {
                    Text(L10n.key("handoff.section.labs"))
                }
                .listRowBackground(Color("BegleiterCardSurface"))
            }

            if !doc.reaktionen.isEmpty {
                Section {
                    ForEach(doc.reaktionen, id: \.self) { claim in
                        Self.claimRow(claim)
                    }
                } header: {
                    Text(L10n.key("handoff.section.reactions"))
                }
                .listRowBackground(Color("BegleiterCardSurface"))
            }

            if !doc.aktuelleMedikation.isEmpty {
                Section {
                    ForEach(doc.aktuelleMedikation, id: \.self) { Text($0) }
                } header: {
                    Text(L10n.key("handoff.section.medication"))
                }
                .listRowBackground(Color("BegleiterCardSurface"))
            }

            if !doc.familienanliegen.isEmpty {
                Section {
                    ForEach(doc.familienanliegen, id: \.self) { claim in
                        Self.claimRow(claim)
                    }
                } header: {
                    Text(L10n.key("handoff.section.familyConcerns"))
                }
                .listRowBackground(Color("BegleiterCardSurface"))
            }
        }
    }

    /// Render one `HandoffClaim` as a row with the prose plus an
    /// optional short-UUID chip showing the cited journal entry. Items
    /// without an `entryId` (history bullets from
    /// `ChildState.completedPhases`, or Gemma prose where the model
    /// declined to cite a specific entry) render as a plain line — no
    /// chip — so the rotating doctor sees citations only where they
    /// exist.
    @ViewBuilder
    private static func claimRow(_ claim: HandoffClaim) -> some View {
        if let entryId = claim.entryId {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(claim.text)
                Spacer(minLength: 8)
                Text(String(entryId.uuidString.prefix(8)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.purple)
                    .accessibilityLabel(Text(L10n.t("handoff.claim.citationLabel")))
            }
        } else {
            Text(claim.text)
        }
    }

    /// Plain-text serialization for AirDrop / Mail / share sheet.
    ///
    /// The exported artifact is what reaches a rotating doctor — the
    /// reviewer flagged that the in-app safety surface (clinical
    /// disclaimer banner + citation chips) had no equivalent on the
    /// share-sheet boundary. This rewrite restores both:
    /// - The clinical-validation disclaimer ships as a `HINWEIS:` block
    ///   immediately under the patient header, so the receiving
    ///   physician sees it before any clinical content.
    /// - Every bullet sourced from a journal entry appends `[E:<short>]`
    ///   where `<short>` is the first 8 characters of the entry UUID,
    ///   matching the chip the in-app view renders. Bullets without an
    ///   `entryId` (deterministic phase history from
    ///   `ChildState.completedPhases`) export without a marker.
    static func plainText(of doc: HandoffDocument) -> String {
        var lines: [String] = []
        lines.append("ÜBERGABE — \(doc.patientId)")
        lines.append("")
        lines.append("HINWEIS: Protokoll-basierte Angaben (Medikamentenpläne, zu erwartende Ereignisse, Risikogruppen-Stratifizierung) stammen aus öffentlich publizierten BFM-2017-Schemata. Konkrete klinische Werte sind nicht klinisch validiert und mit dem Behandlungsteam abzugleichen.")
        lines.append("")
        lines.append("Diagnose: \(doc.diagnose)")
        lines.append("Risikogruppe: \(doc.riskGroupLabel)")
        lines.append("Studienarm: \(doc.randomizationLabel)")
        lines.append("Aktuelle Phase: \(doc.phaseLabel) (Tag \(doc.dayInPhase))")
        lines.append("")
        if !doc.behandlungsverlauf.isEmpty {
            lines.append("BEHANDLUNGSVERLAUF:")
            lines.append(contentsOf: doc.behandlungsverlauf.map(Self.formatBullet))
            lines.append("")
        }
        if !doc.aktuelleLabore.isEmpty {
            lines.append("AKTUELLE LABORE:")
            for lab in doc.aktuelleLabore {
                var line = "  • \(lab.germanLabel): \(lab.value)"
                if let ref = lab.referenceRange { line += " (Ref: \(ref))" }
                lines.append(line)
            }
            lines.append("")
        }
        if !doc.reaktionen.isEmpty {
            lines.append("REAKTIONEN / NEBENWIRKUNGEN:")
            lines.append(contentsOf: doc.reaktionen.map(Self.formatBullet))
            lines.append("")
        }
        if !doc.aktuelleMedikation.isEmpty {
            lines.append("AKTUELLE MEDIKATION:")
            lines.append(contentsOf: doc.aktuelleMedikation.map { "  • \($0)" })
            lines.append("")
        }
        if !doc.familienanliegen.isEmpty {
            lines.append("ANLIEGEN DER FAMILIE:")
            lines.append(contentsOf: doc.familienanliegen.map(Self.formatBullet))
            lines.append("")
        }
        lines.append("— Erstellt mit Begleiter, on-device.")
        return lines.joined(separator: "\n")
    }

    private static func formatBullet(_ claim: HandoffClaim) -> String {
        if let entryId = claim.entryId {
            let short = String(entryId.uuidString.prefix(8))
            return "  • \(claim.text) [E:\(short)]"
        }
        return "  • \(claim.text)"
    }
}

/// UIKit share sheet wrapped for SwiftUI.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
