import SwiftUI
import SwiftData

/// The route of the onboarding NavigationStack. Each case is one screen.
enum OnboardingStep: Hashable {
    case diagnosisDate
    case riskGroup
    case arm
    case phase
    case confirm
}

/// Root of the onboarding flow. Manages the `NavigationStack` path and owns
/// the shared `OnboardingViewModel`.
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var model = OnboardingViewModel()
    @State private var path: [OnboardingStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeScreen(onStart: {
                path.append(.diagnosisDate)
            })
            .navigationDestination(for: OnboardingStep.self) { step in
                switch step {
                case .diagnosisDate:
                    DiagnosisDateView(model: model, onNext: {
                        path.append(.riskGroup)
                    })
                case .riskGroup:
                    RiskGroupView(model: model, onNext: {
                        path.append(.arm)
                    })
                case .arm:
                    ArmView(model: model, onNext: {
                        path.append(.phase)
                    })
                case .phase:
                    PhaseSelectionView(model: model, onNext: {
                        path.append(.confirm)
                    })
                case .confirm:
                    ConfirmScreen(model: model, onFinish: finish)
                }
            }
        }
    }

    private func finish() {
        do {
            try model.finish(context: modelContext)
        } catch {
            // CLINICAL-REVIEW: in iteration 1 we surface SwiftData save errors
            // to the console only. A user-facing error UI lands with the
            // next iteration when error states have a designed treatment.
            assertionFailure("Onboarding save failed: \(error)")
        }
    }
}

// MARK: - Welcome screen (inline because it has no inputs to validate)

private struct WelcomeScreen: View {
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Text(L10n.key("onboarding.welcome.title"))
                .font(.largeTitle)
                .bold()
            Text(L10n.key("onboarding.welcome.subtitle"))
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(L10n.key("onboarding.welcome.body"))
                .font(.body)
            Spacer()
            Button(action: onStart) {
                Text(L10n.key("onboarding.welcome.start"))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - Confirm screen

private struct ConfirmScreen: View {
    let model: OnboardingViewModel
    let onFinish: () -> Void

    var body: some View {
        Form {
            Section {
                if let date = model.diagnosisDate {
                    LabeledContent(
                        L10n.t("onboarding.confirm.diagnosisDate"),
                        value: date.formatted(date: .long, time: .omitted)
                    )
                }
                if let risk = model.riskGroup {
                    LabeledContent(
                        L10n.t("onboarding.confirm.riskGroup"),
                        value: NSLocalizedString("risk.\(risk.rawValue).label", comment: "")
                    )
                }
                if let arm = model.randomizationArm {
                    LabeledContent(
                        L10n.t("onboarding.confirm.arm"),
                        value: NSLocalizedString("arm.\(arm.rawValue).label", comment: "")
                    )
                }
                if let phase = model.currentPhase {
                    LabeledContent(
                        L10n.t("onboarding.confirm.phase"),
                        value: NSLocalizedString("phase.\(phase.rawValue).label", comment: "")
                    )
                }
                if let phaseStart = model.currentPhaseStartDate {
                    LabeledContent(
                        L10n.t("onboarding.confirm.phaseStart"),
                        value: phaseStart.formatted(date: .long, time: .omitted)
                    )
                }
            } header: {
                Text(L10n.key("onboarding.confirm.subtitle"))
            }

            Section {
                Button(action: onFinish) {
                    Text(L10n.key("onboarding.confirm.finish"))
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.canFinish)
            }
        }
        .navigationTitle(L10n.key("onboarding.confirm.title"))
    }
}
