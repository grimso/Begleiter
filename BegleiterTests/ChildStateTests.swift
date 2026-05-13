import XCTest
import SwiftData
@testable import Begleiter

/// Tests for the ChildState SwiftData model and its protocol bridge.
final class ChildStateTests: XCTestCase {

    func makeChild(
        diagnosisDate: Date = .now,
        riskGroup: RiskGroup = .standardRisk,
        arm: RandomizationArm = .standard,
        phase: Phase = .inductionIA,
        phaseStart: Date = .now
    ) -> ChildState {
        ChildState(
            diagnosisDate: diagnosisDate,
            riskGroup: riskGroup,
            randomizationArm: arm,
            currentPhase: phase,
            currentPhaseStartDate: phaseStart
        )
    }

    func test_typedAccessors_roundtrip() {
        let child = makeChild()
        XCTAssertEqual(child.riskGroup, .standardRisk)
        XCTAssertEqual(child.randomizationArm, .standard)
        XCTAssertEqual(child.currentPhase, .inductionIA)

        child.riskGroup = .highRisk
        child.randomizationArm = .rHR
        child.currentPhase = .consolidationHR2
        XCTAssertEqual(child.riskGroupRaw, "HR")
        XCTAssertEqual(child.randomizationArmRaw, "R-HR")
        XCTAssertEqual(child.currentPhaseRaw, "consolidationHR2")
    }

    func test_completedPhases_initiallyEmpty() {
        let child = makeChild()
        XCTAssertTrue(child.completedPhases.isEmpty)
    }

    func test_advanceTo_appendsCompletedPhase_andUpdatesCurrent() {
        let calendar = Calendar.current
        let day1 = calendar.startOfDay(for: .now)
        let day40 = calendar.date(byAdding: .day, value: 39, to: day1)!

        let child = makeChild(phase: .inductionIA, phaseStart: day1)
        child.advanceTo(phase: .inductionIB, on: day40)

        XCTAssertEqual(child.currentPhase, .inductionIB)
        XCTAssertEqual(child.currentPhaseStartDate, day40)
        XCTAssertEqual(child.completedPhases.count, 1)
        XCTAssertEqual(child.completedPhases[0].phaseRaw, "inductionIA")
        XCTAssertEqual(child.completedPhases[0].startedOn, day1)
        XCTAssertEqual(child.completedPhases[0].endedOn, day40)
    }

    func test_currentPhaseInfo_computesDayInPhase() {
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: .now)
        let tenDaysAgo = calendar.date(byAdding: .day, value: -10, to: now)!

        let child = makeChild(phase: .inductionIA, phaseStart: tenDaysAgo)
        let info = child.currentPhaseInfo(now: now)
        XCTAssertEqual(info.dayInPhase, 11) // 1-based: day 1 is the start day
        XCTAssertEqual(info.phase, .inductionIA)
        XCTAssertEqual(info.riskGroup, .standardRisk)
    }

    func test_daysSinceDiagnosis_isOneBased() {
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: .now)
        let fiveDaysAgo = calendar.date(byAdding: .day, value: -5, to: now)!

        let child = makeChild(diagnosisDate: fiveDaysAgo)
        XCTAssertEqual(child.daysSinceDiagnosis(now: now), 6) // 1-based
    }

    func test_phaseMetadata_matchesCurrentPhase() {
        let child = makeChild(phase: .reinductionII)
        XCTAssertEqual(child.phaseMetadata.phase, .reinductionII)
    }

    // MARK: - dateRange(forPhase:fromDay:toDay:)

    func test_dateRange_forCurrentPhase_usesCurrentPhaseStartDate() {
        let calendar = Calendar.current
        let day1 = calendar.startOfDay(for: .now)
        let child = makeChild(phase: .inductionIA, phaseStart: day1)

        // First two weeks: days 1-14 → start of day1 ..< start of day15
        let range = child.dateRange(forPhase: .inductionIA, fromDay: 1, toDay: 14)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.start, day1)
        let day15 = calendar.date(byAdding: .day, value: 14, to: day1)!
        XCTAssertEqual(range?.end, day15)
    }

    func test_dateRange_forCompletedPhase_usesCompletedPhaseStartedOn() {
        let calendar = Calendar.current
        let day1 = calendar.startOfDay(for: .now)
        let day40 = calendar.date(byAdding: .day, value: 39, to: day1)!

        let child = makeChild(phase: .inductionIA, phaseStart: day1)
        child.advanceTo(phase: .inductionIB, on: day40)
        // Now child's current phase is IB; IA is completed with startedOn=day1.

        let range = child.dateRange(forPhase: .inductionIA, fromDay: 1, toDay: 14)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.start, day1)
        let day15 = calendar.date(byAdding: .day, value: 14, to: day1)!
        XCTAssertEqual(range?.end, day15)
    }

    func test_dateRange_forUnenteredPhase_returnsNil() {
        let child = makeChild(phase: .inductionIA)
        // Child is in IA, hasn't entered Reinduction II yet.
        XCTAssertNil(child.dateRange(forPhase: .reinductionII, fromDay: 1, toDay: 7))
    }

    func test_dateRange_normalisesReversedDayOffsets() {
        let calendar = Calendar.current
        let day1 = calendar.startOfDay(for: .now)
        let child = makeChild(phase: .inductionIA, phaseStart: day1)

        // Reversed input: should produce the same window as 7..14.
        let reversed = child.dateRange(forPhase: .inductionIA, fromDay: 14, toDay: 7)
        let normal = child.dateRange(forPhase: .inductionIA, fromDay: 7, toDay: 14)
        XCTAssertEqual(reversed, normal)
    }

    func test_dateRange_singleDayWindow() {
        let calendar = Calendar.current
        let day1 = calendar.startOfDay(for: .now)
        let child = makeChild(phase: .inductionIA, phaseStart: day1)

        // fromDay == toDay == 5 → start of day5 ..< start of day6.
        let range = child.dateRange(forPhase: .inductionIA, fromDay: 5, toDay: 5)
        XCTAssertNotNil(range)
        let day5 = calendar.date(byAdding: .day, value: 4, to: day1)!
        let day6 = calendar.date(byAdding: .day, value: 5, to: day1)!
        XCTAssertEqual(range?.start, day5)
        XCTAssertEqual(range?.end, day6)
    }
}
