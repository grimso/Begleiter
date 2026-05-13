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

    /// Resolve a phase + day-in-phase offset window to an absolute
    /// `DateInterval`. Used by `LabPlotResolver` to turn a phase-
    /// relative `LabPlotSpec.Window.phase("inductionIA", 1, 14, …)`
    /// into "the first two weeks after the parent reported Induction IA
    /// began".
    ///
    /// `fromDay` and `toDay` are 1-indexed inclusive day-in-phase
    /// offsets (matching `JournalEntry.dayInPhase`). The returned
    /// `DateInterval` runs from `phaseStart + (fromDay-1)` days, 00:00
    /// to `phaseStart + toDay` days, 00:00 — so the entire `toDay` is
    /// included.
    ///
    /// Returns `nil` for phases the child has neither completed nor is
    /// currently in (i.e. "future" phases). The caller surfaces a
    /// `LabPlotWarning.phaseNotYetEntered`.
    ///
    /// Looks up history in this order:
    /// 1. `completedPhases` — for phases the child has already finished.
    /// 2. `currentPhase` — uses `currentPhaseStartDate` as the anchor.
    func dateRange(
        forPhase phase: Phase,
        fromDay: Int,
        toDay: Int,
        calendar: Calendar = .current
    ) -> DateInterval? {
        // Clamp/normalise the day offsets so the parser doesn't have to
        // guess (e.g. "Tag 14 bis 7" becomes a 1-day window starting at
        // the smaller bound).
        let lo = max(1, min(fromDay, toDay))
        let hi = max(1, max(fromDay, toDay))

        // 1. Was this phase already completed? Use its recorded
        //    startedOn as the anchor.
        if let completed = completedPhases.first(where: {
            $0.phaseRaw == phase.rawValue
        }) {
            return intervalFromStart(
                completed.startedOn,
                fromDay: lo, toDay: hi,
                calendar: calendar
            )
        }

        // 2. Is this the child's current phase?
        if currentPhase == phase {
            return intervalFromStart(
                currentPhaseStartDate,
                fromDay: lo, toDay: hi,
                calendar: calendar
            )
        }

        // 3. Phase not yet entered.
        return nil
    }

    /// Internal: `phaseStart + (fromDay-1)` days … `phaseStart + toDay`
    /// days, both at midnight in the supplied calendar.
    private func intervalFromStart(
        _ phaseStart: Date,
        fromDay: Int,
        toDay: Int,
        calendar: Calendar
    ) -> DateInterval {
        let anchor = calendar.startOfDay(for: phaseStart)
        let start = calendar.date(byAdding: .day, value: fromDay - 1, to: anchor)
            ?? anchor
        let end = calendar.date(byAdding: .day, value: toDay, to: anchor)
            ?? anchor
        return DateInterval(start: start, end: max(start, end))
    }
}
