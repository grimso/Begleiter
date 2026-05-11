import SwiftData
import SwiftUI

/// Timeline of journal entries, grouped by phase.
///
/// Iteration 3: chronological list grouped by `phase`, sorted newest first
/// within each section. Tapping a row opens `EntryDetailView`. The "+"
/// toolbar button presents `CaptureView` as a sheet.
///
/// Search, facet filters, lab-value sparklines, and knowledge-graph
/// suggested questions arrive in iteration 6 along with retrieval.
struct TimelineView: View {
    let child: ChildState

    @Query(sort: \JournalEntry.visitDate, order: .reverse) private var entries: [JournalEntry]
    @State private var presentingCapture = false

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(groupedByPhase, id: \.phase) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    NavigationLink {
                                        EntryDetailView(entry: entry)
                                    } label: {
                                        TimelineRow(entry: entry)
                                    }
                                }
                            } header: {
                                Text(group.phaseLabel)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.key("timeline.title"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        presentingCapture = true
                    } label: {
                        Label(L10n.t("timeline.add"), systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SmokeTestView()
                    } label: {
                        Image(systemName: "brain.head.profile")
                    }
                    .accessibilityLabel(L10n.t("debug.smoke.title"))
                }
            }
            .sheet(isPresented: $presentingCapture) {
                CaptureView(child: child)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.t("timeline.empty.title"), systemImage: "book.closed")
        } description: {
            Text(L10n.key("timeline.empty.description"))
        } actions: {
            Button {
                presentingCapture = true
            } label: {
                Text(L10n.key("timeline.empty.action"))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Grouping

    private struct PhaseGroup {
        let phase: Phase
        let phaseLabel: String
        let entries: [JournalEntry]
    }

    private var groupedByPhase: [PhaseGroup] {
        // Preserve canonical phase order, dropping phases with no entries.
        Phase.canonicalOrder.compactMap { phase in
            let inPhase = entries.filter { $0.phase == phase }
            guard !inPhase.isEmpty else { return nil }
            let label = NSLocalizedString("phase.\(phase.rawValue).label", comment: "")
            return PhaseGroup(phase: phase, phaseLabel: label, entries: inPhase)
        }
    }
}

private struct TimelineRow: View {
    let entry: JournalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.visitDate, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let visitType = entry.extractedFields.visitType?.value {
                    Text(visitType.germanLabel)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            Text(entry.displayTitle)
                .font(.body)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}
