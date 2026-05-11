import Foundation

/// Pure-function lookup of legal phase transitions under BFM 2017.
///
/// This is the most clinically-loaded file in the protocol module after
/// `PhaseMetadata`. Downstream features (briefings, handoffs, anticipated
/// events) rely on the legality matrix being correct.
///
/// CLINICAL-REVIEW: every entry in `all` should be reviewed by a clinical
/// advisor. The public BFM literature is consistent on the major branches
/// (SR/MR → Protocol M; HR → HR1/HR2/HR3 cycle), but exact ordering and
/// edge cases warrant verification.
enum PhaseTransitions {

    /// Complete set of legal transitions in the protocol.
    static let all: [PhaseTransition] = [
        // After IA, all children proceed to IB. // CLINICAL-REVIEW
        PhaseTransition(
            from: .inductionIA, to: .inductionIB,
            requiresRiskGroup: nil, requiresArm: nil
        ),

        // After IB, SR and MR go to Protocol M; HR goes to HR-1'. // CLINICAL-REVIEW
        PhaseTransition(
            from: .inductionIB, to: .consolidationM,
            requiresRiskGroup: [.standardRisk, .mediumRisk], requiresArm: nil
        ),
        PhaseTransition(
            from: .inductionIB, to: .consolidationHR1,
            requiresRiskGroup: [.highRisk], requiresArm: nil
        ),

        // SR/MR path: Protocol M → Reinduction II. // CLINICAL-REVIEW
        PhaseTransition(
            from: .consolidationM, to: .reinductionII,
            requiresRiskGroup: [.standardRisk, .mediumRisk], requiresArm: nil
        ),

        // HR path: HR1 → HR2 → HR3 → Reinduction II. // CLINICAL-REVIEW:
        // BFM 2017 conventionally cycles HR-1', HR-2', HR-3' in that order
        // (sometimes repeated); advisor should confirm whether repeats are
        // modeled here or treated as journal events within a single phase.
        PhaseTransition(
            from: .consolidationHR1, to: .consolidationHR2,
            requiresRiskGroup: [.highRisk], requiresArm: nil
        ),
        PhaseTransition(
            from: .consolidationHR2, to: .consolidationHR3,
            requiresRiskGroup: [.highRisk], requiresArm: nil
        ),
        PhaseTransition(
            from: .consolidationHR3, to: .reinductionII,
            requiresRiskGroup: [.highRisk], requiresArm: nil
        ),

        // All paths converge: Reinduction II → Maintenance. // CLINICAL-REVIEW
        PhaseTransition(
            from: .reinductionII, to: .maintenance,
            requiresRiskGroup: nil, requiresArm: nil
        ),

        // Maintenance has no successor (treatment end).
    ]

    /// Legal next phases from `phase` for a child of the given `riskGroup` and `arm`.
    /// Returns an empty array if no legal next phase exists (e.g. from `.maintenance`).
    static func legalNextPhases(
        from phase: Phase,
        riskGroup: RiskGroup,
        arm: RandomizationArm
    ) -> [Phase] {
        all
            .filter { $0.from == phase && $0.permits(riskGroup: riskGroup, arm: arm) }
            .map(\.to)
    }

    /// Whether `from → to` is a legal single-step transition.
    static func isLegal(
        from: Phase, to: Phase,
        riskGroup: RiskGroup, arm: RandomizationArm
    ) -> Bool {
        legalNextPhases(from: from, riskGroup: riskGroup, arm: arm).contains(to)
    }

    /// Whether `target` is reachable from `inductionIA` for the given risk group/arm,
    /// following only legal transitions. Used by onboarding to warn (non-blocking)
    /// when a parent picks a phase that the state machine considers unreachable.
    static func isReachable(
        _ target: Phase,
        riskGroup: RiskGroup,
        arm: RandomizationArm
    ) -> Bool {
        if target == .inductionIA { return true }
        var frontier: Set<Phase> = [.inductionIA]
        var visited: Set<Phase> = []
        while let current = frontier.popFirst() {
            if visited.contains(current) { continue }
            visited.insert(current)
            for next in legalNextPhases(from: current, riskGroup: riskGroup, arm: arm) {
                if next == target { return true }
                frontier.insert(next)
            }
        }
        return false
    }
}
