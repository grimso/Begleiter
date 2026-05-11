import SwiftData
import SwiftUI

/// Pre-visit briefing screen — the "Vorbereitung Morgen" entry point.
///
/// Sections (matching the spec):
/// - Aktueller Stand (one-line "where are we now")
/// - Was war seit dem letzten Termin
/// - Offene Punkte
/// - Drei Vorschläge für Fragen
/// - Was mitnehmen
///
/// Every claim has a tappable citation chip that opens the source
/// `JournalEntry` via `EntryDetailView`.
struct PreVisitBriefingView: View {
    let child: ChildState

    @Query(sort: \JournalEntry.visitDate, order: .reverse) private var entries: [JournalEntry]
    @State private var model = BriefingViewModel()
    @State private var routeEntry: JournalEntry?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        L10n.t("briefing.visitDate"),
                        selection: $model.visitDate,
                        in: Date.now...,
                        displayedComponents: .date
                    )
                } header: {
                    Text(L10n.key("briefing.targetSection"))
                }

                if !model.isBusy && model.state == .idle {
                    Section {
                        Button {
                            model.generate(child: child, allEntries: entries)
                        } label: {
                            Text(L10n.key("briefing.generate"))
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(entries.isEmpty)
                    } footer: {
                        if entries.isEmpty {
                            Text(L10n.key("briefing.noEntriesFooter"))
                        } else {
                            Text(L10n.key("briefing.uses8EntriesFooter"))
                        }
                    }
                }

                if model.isBusy {
                    Section {
                        HStack {
                            ProgressView()
                            Text(L10n.key("briefing.generating"))
                        }
                    }
                }

                if case .failed(let message) = model.state {
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

                if case .done(let briefing) = model.state {
                    briefingSections(briefing)
                }
            }
            .navigationTitle(L10n.key("briefing.title"))
            .navigationDestination(item: $routeEntry) { entry in
                EntryDetailView(entry: entry)
            }
        }
    }

    @ViewBuilder
    private func briefingSections(_ briefing: Briefing) -> some View {
        Section {
            claimRow(briefing.aktuellerStand)
        } header: {
            Text(L10n.key("briefing.section.stand"))
        }

        if !briefing.seitDemLetztenTermin.isEmpty {
            Section {
                ForEach(briefing.seitDemLetztenTermin, id: \.self) { claim in
                    claimRow(claim)
                }
            } header: {
                Text(L10n.key("briefing.section.seitDemLetztenTermin"))
            }
        }

        if !briefing.offenePunkte.isEmpty {
            Section {
                ForEach(briefing.offenePunkte, id: \.self) { claim in
                    claimRow(claim)
                }
            } header: {
                Text(L10n.key("briefing.section.offenePunkte"))
            }
        }

        if !briefing.fragenVorschlaege.isEmpty {
            Section {
                ForEach(briefing.fragenVorschlaege, id: \.self) { question in
                    Label {
                        Text(question)
                    } icon: {
                        Image(systemName: "questionmark.circle")
                    }
                }
            } header: {
                Text(L10n.key("briefing.section.fragen"))
            }
        }

        if !briefing.mitzunehmen.isEmpty {
            Section {
                ForEach(briefing.mitzunehmen, id: \.self) { item in
                    Label(item, systemImage: "bag")
                }
            } header: {
                Text(L10n.key("briefing.section.mitzunehmen"))
            }
        }
    }

    @ViewBuilder
    private func claimRow(_ claim: BriefingClaim) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(claim.text)
            if let id = claim.entryId, let entry = model.resolveEntry[id] {
                Button {
                    routeEntry = entry
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption2)
                        Text(entry.visitDate, format: .dateTime.day().month().year(.twoDigits))
                            .font(.caption2.monospacedDigit())
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
