import Foundation

/// A snapshot of where a child currently stands in the protocol.
///
/// Returned by the (future) `getCurrentPhase(childId:)` function-calling
/// tool, and used directly by the home/timeline UI.
struct CurrentPhaseInfo: Codable, Hashable, Sendable {
    let phase: Phase
    let dayInPhase: Int
    let riskGroup: RiskGroup
    let arm: RandomizationArm
    let phaseStartDate: Date

    /// `dayInPhase` is 1-based on the start date.
    static func compute(
        phase: Phase,
        phaseStartDate: Date,
        riskGroup: RiskGroup,
        arm: RandomizationArm,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> CurrentPhaseInfo {
        let startOfPhaseDay = calendar.startOfDay(for: phaseStartDate)
        let startOfToday = calendar.startOfDay(for: now)
        let components = calendar.dateComponents([.day], from: startOfPhaseDay, to: startOfToday)
        let day = max(1, (components.day ?? 0) + 1)
        return CurrentPhaseInfo(
            phase: phase,
            dayInPhase: day,
            riskGroup: riskGroup,
            arm: arm,
            phaseStartDate: phaseStartDate
        )
    }
}
