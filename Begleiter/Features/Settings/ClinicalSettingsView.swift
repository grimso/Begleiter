import SwiftData
import SwiftUI

/// User-facing settings: the clinical state captured at onboarding.
///
/// Four sections:
/// 1. **Diagnose** — `diagnosisDate` graphical picker.
/// 2. **Risikogruppe** — radio rows over `RiskGroup.allCases`.
/// 3. **Studienarm** — radio rows over `RandomizationArm.options(for:)`,
///    filtered by the currently-selected risk group. A risk-group change
///    that invalidates the current arm auto-resets it to `.unknown` and
///    surfaces a banner.
/// 4. **Aktuelle Phase** — radio rows over `Phase.canonicalOrder` and a
///    graphical picker for `currentPhaseStartDate`. Phase taps populate a
///    pending value; a confirmation dialog asks whether this is a
///    correction (overwrite only) or a real advance (record into
///    `completedPhases` via `child.advanceTo(phase:on:)`).
struct ClinicalSettingsView: View {
    @Bindable var child: ChildState
    @Environment(\.modelContext) private var modelContext

    @State private var pendingPhase: Phase?
    @State private var armResetNotice = false

    var body: some View {
        Form {
            diagnoseSection
            riskGroupSection
            armSection
            phaseSection
        }
        .scrollContentBackground(.hidden)
        .background(Color("BegleiterBackground").ignoresSafeArea())
        .listRowBackground(Color("BegleiterCardSurface"))
        .navigationTitle(L10n.key("settings.behandlung.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: child.diagnosisDate) { _, _ in
            try? modelContext.save()
        }
        .onChange(of: child.riskGroup) { _, newRisk in
            // If current arm is no longer valid for the new risk group,
            // reset to .unknown so the parent must pick again.
            if !RandomizationArm.options(for: newRisk).contains(child.randomizationArm) {
                child.randomizationArm = .unknown
                armResetNotice = true
            }
            try? modelContext.save()
        }
        .onChange(of: child.randomizationArm) { _, _ in
            armResetNotice = false
            try? modelContext.save()
        }
        .onChange(of: child.currentPhaseStartDate) { _, _ in
            try? modelContext.save()
        }
        .confirmationDialog(
            L10n.t("settings.behandlung.phase.alert.title"),
            isPresented: phaseDialogBinding,
            titleVisibility: .visible
        ) {
            Button(L10n.t("settings.behandlung.phase.alert.correction")) { applyCorrection() }
            Button(L10n.t("settings.behandlung.phase.alert.advance")) { applyAdvance() }
            Button(L10n.t("settings.behandlung.phase.alert.cancel"), role: .cancel) {
                pendingPhase = nil
            }
        }
    }

    // MARK: - Sections

    private var diagnoseSection: some View {
        Section {
            DatePicker(
                selection: $child.diagnosisDate,
                in: diagnosisDateRange,
                displayedComponents: .date
            ) {
                Text(L10n.key("settings.behandlung.diagnosisDate.label"))
            }
            .datePickerStyle(.graphical)
        } header: {
            Text(L10n.key("settings.behandlung.diagnosisDate.section"))
        }
    }

    private var riskGroupSection: some View {
        Section {
            ForEach(RiskGroup.allCases, id: \.self) { group in
                radioRow(
                    title: L10n.t("risk.\(group.rawValue).label"),
                    subtitle: L10n.t("risk.\(group.rawValue).description"),
                    isSelected: child.riskGroup == group
                ) {
                    child.riskGroup = group
                }
            }
        } header: {
            Text(L10n.key("settings.behandlung.riskGroup.section"))
        }
    }

    private var armSection: some View {
        Section {
            if armResetNotice {
                Label {
                    Text(L10n.key("settings.behandlung.arm.armResetWarning"))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }
            ForEach(RandomizationArm.options(for: child.riskGroup), id: \.self) { arm in
                radioRow(
                    title: L10n.t("arm.\(arm.rawValue).label"),
                    subtitle: nil,
                    isSelected: child.randomizationArm == arm
                ) {
                    child.randomizationArm = arm
                }
            }
        } header: {
            Text(L10n.key("settings.behandlung.arm.section"))
        }
    }

    private var phaseSection: some View {
        Section {
            ForEach(Phase.canonicalOrder, id: \.self) { phase in
                radioRow(
                    title: L10n.t("phase.\(phase.rawValue).label"),
                    subtitle: nil,
                    isSelected: child.currentPhase == phase
                ) {
                    guard phase != child.currentPhase else { return }
                    pendingPhase = phase
                }
            }
            if let pending = pendingPhase,
               !PhaseTransitions.isReachable(pending,
                                             riskGroup: child.riskGroup,
                                             arm: child.randomizationArm)
            {
                Label {
                    Text(L10n.key("onboarding.phase.unreachableWarning"))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }
            DatePicker(
                selection: $child.currentPhaseStartDate,
                in: phaseStartRange,
                displayedComponents: .date
            ) {
                Text(L10n.key("settings.behandlung.phase.startDateLabel"))
            }
            .datePickerStyle(.graphical)
        } header: {
            Text(L10n.key("settings.behandlung.phase.section"))
        }
    }

    // MARK: - Helpers

    private func radioRow(
        title: String,
        subtitle: String?,
        isSelected: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var phaseDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingPhase != nil },
            set: { if !$0 { pendingPhase = nil } }
        )
    }

    private var diagnosisDateRange: ClosedRange<Date> {
        let earliest = Calendar.current.date(byAdding: .year, value: -5, to: .now) ?? .distantPast
        return earliest...Date.now
    }

    private var phaseStartRange: ClosedRange<Date> {
        child.diagnosisDate...Date.now
    }

    // MARK: - Phase change commits

    private func applyCorrection() {
        guard let target = pendingPhase else { return }
        child.currentPhase = target
        try? modelContext.save()
        pendingPhase = nil
    }

    private func applyAdvance() {
        guard let target = pendingPhase else { return }
        child.advanceTo(phase: target, on: .now)
        try? modelContext.save()
        pendingPhase = nil
    }
}
