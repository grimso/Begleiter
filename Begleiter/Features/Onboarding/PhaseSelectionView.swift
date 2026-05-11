import SwiftUI

struct PhaseSelectionView: View {
    @Bindable var model: OnboardingViewModel
    let onNext: () -> Void

    @State private var phaseStart: Date = .now

    var body: some View {
        Form {
            Section {
                ForEach(Phase.canonicalOrder, id: \.self) { phase in
                    PhaseRow(
                        phase: phase,
                        isSelected: model.currentPhase == phase,
                        onTap: { model.currentPhase = phase }
                    )
                }
            } header: {
                Text(L10n.key("onboarding.phase.subtitle"))
            } footer: {
                Text(L10n.key("onboarding.phase.caption"))
            }

            Section {
                DatePicker(
                    selection: $phaseStart,
                    in: phaseStartRange,
                    displayedComponents: .date
                ) {
                    Text(L10n.key("onboarding.phase.startDateLabel"))
                }
            }

            if !model.selectedPhaseIsReachable {
                Section {
                    Label {
                        Text(L10n.key("onboarding.phase.unreachableWarning"))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Button {
                    model.currentPhaseStartDate = phaseStart
                    onNext()
                } label: {
                    Text(L10n.key("app.continue"))
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.currentPhase == nil)
            }
        }
        .navigationTitle(L10n.key("onboarding.phase.title"))
        .onAppear {
            // Default the phase start to the diagnosis date if the parent
            // hasn't picked one yet; this is usually a reasonable starting
            // guess for the first phase (Induction IA).
            if let existing = model.currentPhaseStartDate {
                phaseStart = existing
            } else if let diagnosis = model.diagnosisDate {
                phaseStart = diagnosis
            }
        }
    }

    /// Phase start must not be in the future and not before the diagnosis
    /// date if one is set; otherwise allow up to 3 years back.
    private var phaseStartRange: ClosedRange<Date> {
        let earliest = model.diagnosisDate
            ?? Calendar.current.date(byAdding: .year, value: -3, to: .now)
            ?? .now
        return earliest...Date.now
    }
}

private struct PhaseRow: View {
    let phase: Phase
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Text(L10n.key("phase.\(phase.rawValue).label"))
                    .foregroundStyle(.primary)
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
}
