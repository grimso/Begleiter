import Foundation

/// A legal transition between two phases under the BFM 2017 protocol.
///
/// A transition fires when the parent confirms in the UI ("we finished
/// Protocol IB today"). The conditions on `requiresRiskGroup` and
/// `requiresArm` express constraints — if `nil`, no constraint applies.
struct PhaseTransition: Codable, Hashable, Sendable {
    let from: Phase
    let to: Phase
    let requiresRiskGroup: Set<RiskGroup>?
    let requiresArm: Set<RandomizationArm>?

    /// Whether this transition is permitted for the given risk group and arm.
    func permits(riskGroup: RiskGroup, arm: RandomizationArm) -> Bool {
        if let allowed = requiresRiskGroup, !allowed.contains(riskGroup) {
            return false
        }
        if let allowed = requiresArm, !allowed.contains(arm) {
            return false
        }
        return true
    }
}
