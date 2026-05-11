import Foundation

/// Bridges `ChildState` (the SwiftData record) to the deterministic protocol
/// state machine. All clinical decisions still flow through the protocol
/// module — this extension is glue, not logic.
extension ChildState {

    /// Snapshot of the current phase, day-in-phase, and arm context.
    /// Returned by the future `getCurrentPhase` function-calling tool.
    func currentPhaseInfo(now: Date = .now) -> CurrentPhaseInfo {
        CurrentPhaseInfo.compute(
            phase: currentPhase,
            phaseStartDate: currentPhaseStartDate,
            riskGroup: riskGroup,
            arm: randomizationArm,
            now: now
        )
    }

    /// Metadata for the current phase (drugs, procedures, parent concerns).
    var phaseMetadata: PhaseMetadata {
        PhaseMetadata.for(currentPhase)
    }

    /// Days elapsed since the diagnosis date (1-based on the diagnosis day).
    func daysSinceDiagnosis(now: Date = .now, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: diagnosisDate)
        let to = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        return max(1, days + 1)
    }

    /// Advance to a new phase, appending the previous phase to `completedPhases`.
    ///
    /// Does **not** validate legality against `PhaseTransitions` — that is the
    /// caller's responsibility (UI typically calls `legalNextPhases(...)` to
    /// constrain the choices). Parent confirmation is the only required gate.
    func advanceTo(phase newPhase: Phase, on date: Date) {
        let completed = CompletedPhase(
            phaseRaw: currentPhase.rawValue,
            startedOn: currentPhaseStartDate,
            endedOn: date
        )
        var history = completedPhases
        history.append(completed)
        completedPhases = history
        currentPhase = newPhase
        currentPhaseStartDate = date
    }
}
