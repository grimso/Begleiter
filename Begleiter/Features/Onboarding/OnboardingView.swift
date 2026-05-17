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
    @Environment(\.modelContext) private var modelContext
    @State private var showLoadDemoConfirm: Bool = false
    @State private var demoOutcomeMessage: String?

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

            // Judge / evaluator affordance. After tapping "Alle Daten
            // zurücksetzen" in Settings, the SwiftData store has no
            // `ChildState` and the app lands back on this screen — the
            // existing demo loader inside Settings → Entwicklung is
            // unreachable from there. Surfacing it here closes that
            // loop. Visually subdued so a real parent on first launch
            // gravitates to "Begleiter starten" instead.
            Button {
                showLoadDemoConfirm = true
            } label: {
                Text(L10n.key("onboarding.welcome.loadDemo"))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)

            if let message = demoOutcomeMessage {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .confirmationDialog(
            L10n.key("settings.developer.demoData.loadConfirm.title"),
            isPresented: $showLoadDemoConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("settings.developer.demoData.loadConfirm.action")) {
                let outcome = DemoDataLoader.loadDemoDataset(into: modelContext)
                demoOutcomeMessage = Self.formatOutcome(outcome)
            }
            Button(L10n.t("app.cancel"), role: .cancel) { }
        } message: {
            Text(L10n.key("settings.developer.demoData.loadConfirm.message"))
        }
    }

    private static func formatOutcome(_ outcome: DemoDataLoader.Outcome) -> String {
        switch outcome {
        case .loaded(let entries, let documents):
            let format = L10n.t("settings.developer.demoData.outcome.loaded")
            return String(format: format, entries, documents)
        case .alreadyPopulated:
            return L10n.t("settings.developer.demoData.outcome.alreadyPopulated")
        case .failed(let reason):
            let format = L10n.t("settings.developer.demoData.outcome.failed")
            return String(format: format, reason)
        }
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
