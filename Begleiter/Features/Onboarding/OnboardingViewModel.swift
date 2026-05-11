import Foundation
import SwiftData
import SwiftUI

/// Inputs collected across the onboarding flow. Each is `nil` until the
/// parent has made a choice on the corresponding screen.
@MainActor
@Observable
final class OnboardingViewModel {
    var diagnosisDate: Date?
    var riskGroup: RiskGroup?
    var randomizationArm: RandomizationArm?
    var currentPhase: Phase?
    var currentPhaseStartDate: Date?

    /// Whether all required inputs are present and the parent can finish onboarding.
    var canFinish: Bool {
        diagnosisDate != nil
            && riskGroup != nil
            && randomizationArm != nil
            && currentPhase != nil
            && currentPhaseStartDate != nil
    }

    /// Whether the currently-selected phase is reachable under the chosen
    /// risk group + arm. Used by `PhaseSelectionView` to surface a
    /// non-blocking warning. Returns `true` if any input is still missing.
    var selectedPhaseIsReachable: Bool {
        guard let phase = currentPhase,
              let risk = riskGroup,
              let arm = randomizationArm
        else { return true }
        return PhaseTransitions.isReachable(phase, riskGroup: risk, arm: arm)
    }

    /// Available arms for the currently-selected risk group. Empty if no
    /// risk group has been chosen yet.
    var armOptions: [RandomizationArm] {
        guard let risk = riskGroup else { return [] }
        return RandomizationArm.options(for: risk)
    }

    /// Persist the collected inputs as a new `ChildState` in the model context.
    /// Throws only if the SwiftData save itself throws.
    func finish(context: ModelContext) throws {
        guard let diagnosisDate,
              let riskGroup,
              let randomizationArm,
              let currentPhase,
              let currentPhaseStartDate
        else {
            preconditionFailure("OnboardingViewModel.finish called before canFinish")
        }
        let child = ChildState(
            diagnosisDate: diagnosisDate,
            riskGroup: riskGroup,
            randomizationArm: randomizationArm,
            currentPhase: currentPhase,
            currentPhaseStartDate: currentPhaseStartDate
        )
        context.insert(child)
        try context.save()
    }
}
