import XCTest
@testable import Begleiter

final class LabPlotResolverTests: XCTestCase {

    // MARK: - Fixtures

    private var calendar: Calendar { .current }

    private func day(_ offset: Int, from anchor: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: anchor))!
    }

    /// Make a JournalEntry with one ANC lab value at the given date.
    private func entry(
        anc: Double,
        on date: Date,
        phase: Phase = .inductionIA,
        dayInPhase: Int = 1
    ) -> JournalEntry {
        let lab = LabValue(
            parameter: "ANC",
            germanLabel: "Neutrophile",
            value: anc,
            unit: "G/L",
            measuredAt: date
        )
        let fields = ExtractedFields(
            labValues: ConfidenceField(value: [lab], confidence: 0.9)
        )
        return JournalEntry(
            childId: UUID(),
            visitDate: date,
            phase: phase,
            dayInPhase: dayInPhase,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            extractedFields: fields
        )
    }

    private func makeChild(
        phase: Phase = .inductionIA,
        phaseStart: Date = .now,
        completed: [CompletedPhase] = []
    ) -> ChildState {
        let c = ChildState(
            diagnosisDate: phaseStart,
            riskGroup: .standardRisk,
            randomizationArm: .standard,
            currentPhase: phase,
            currentPhaseStartDate: phaseStart,
            completedPhases: completed
        )
        return c
    }

    // MARK: - Window resolution

    func test_resolve_phaseWindow_collectsPointsInRange() {
        let phaseStart = calendar.startOfDay(for: .now)
        let child = makeChild(phaseStart: phaseStart)
        let inWindow1  = entry(anc: 1.2, on: day(2, from: phaseStart))  // day 3
        let inWindow2  = entry(anc: 0.4, on: day(10, from: phaseStart)) // day 11
        let outOfRange = entry(anc: 2.1, on: day(20, from: phaseStart)) // day 21

        let spec = LabPlotSpec(
            title: "ANC, Tag 1–14",
            parameters: ["ANC"],
            windows: [
                .phase(phase: "inductionIA", fromDay: 1, toDay: 14, label: nil)
            ],
            layout: .sideBySideByParameter
        )

        let result = LabPlotResolver.resolve(
            spec: spec,
            child: child,
            entries: [inWindow1, inWindow2, outOfRange]
        )

        XCTAssertEqual(result.panels.count, 1)
        XCTAssertEqual(result.panels[0].parameter, "ANC")
        XCTAssertEqual(result.panels[0].windows.count, 1)
        let cellPoints = result.panels[0].windows[0].points
        XCTAssertEqual(cellPoints.count, 2)
        XCTAssertEqual(cellPoints.map { $0.value }, [1.2, 0.4])
        XCTAssertFalse(result.warnings.contains(.noPointsInWindow))
    }

    func test_resolve_phaseNotYetEntered_emitsWarningAndNilRange() {
        let child = makeChild(phase: .inductionIA)  // current is IA
        let spec = LabPlotSpec(
            title: "ANC in Reinduction",
            parameters: ["ANC"],
            windows: [
                .phase(phase: "reinductionII", fromDay: 1, toDay: 7, label: nil)
            ],
            layout: .sideBySideByParameter
        )

        let result = LabPlotResolver.resolve(
            spec: spec,
            child: child,
            entries: []
        )

        XCTAssertEqual(result.resolvedRanges, [nil])
        XCTAssertTrue(result.warnings.contains(.phaseNotYetEntered))
        XCTAssertTrue(result.panels[0].windows[0].points.isEmpty)
    }

    func test_resolve_relativeDaysWindow_usesNowAsAnchor() {
        let now = calendar.startOfDay(for: .now)
        let child = makeChild(phaseStart: day(-100, from: now))
        let inWindow  = entry(anc: 0.8, on: day(-3, from: now))
        let outBefore = entry(anc: 0.5, on: day(-20, from: now))

        let spec = LabPlotSpec(
            title: "letzte Woche",
            parameters: ["ANC"],
            windows: [.relativeDays(daysBack: 7, label: nil)],
            layout: .sideBySideByParameter
        )

        let result = LabPlotResolver.resolve(
            spec: spec,
            child: child,
            entries: [inWindow, outBefore],
            now: now
        )

        XCTAssertEqual(result.panels[0].windows[0].points.count, 1)
        XCTAssertEqual(result.panels[0].windows[0].points.first?.value, 0.8)
    }

    func test_resolve_emptyWindow_emitsWarning() {
        let phaseStart = calendar.startOfDay(for: .now)
        let child = makeChild(phaseStart: phaseStart)
        // Only entry is outside the window.
        let entry = entry(anc: 1.0, on: day(20, from: phaseStart))

        let spec = LabPlotSpec(
            title: "first week",
            parameters: ["ANC"],
            windows: [.phase(phase: "inductionIA", fromDay: 1, toDay: 7, label: nil)],
            layout: .sideBySideByParameter
        )

        let result = LabPlotResolver.resolve(
            spec: spec,
            child: child,
            entries: [entry]
        )

        XCTAssertTrue(result.warnings.contains(.noPointsInWindow))
        XCTAssertTrue(result.panels[0].windows[0].points.isEmpty)
    }

    func test_resolve_multipleParametersAndWindows_buildsGrid() {
        let phaseStart = calendar.startOfDay(for: .now)
        let now = day(20, from: phaseStart)
        let child = makeChild(phaseStart: phaseStart)

        // Multi-lab entry covering ANC and HB across two windows.
        let earlyDate = day(3, from: phaseStart)   // day 4
        let recentDate = day(19, from: phaseStart) // day 20 → today
        let earlyEntry = makeMultiLabEntry(
            anc: 1.2, hb: 9.0, on: earlyDate,
            phase: .inductionIA, dayInPhase: 4
        )
        let recentEntry = makeMultiLabEntry(
            anc: 0.6, hb: 8.5, on: recentDate,
            phase: .inductionIA, dayInPhase: 20
        )

        let spec = LabPlotSpec(
            title: "Blutbild: IA Tag 1–14 vs letzte Woche",
            parameters: ["ANC", "HB"],
            windows: [
                .phase(phase: "inductionIA", fromDay: 1, toDay: 14, label: nil),
                .relativeDays(daysBack: 7, label: nil)
            ],
            layout: .sideBySideByParameter
        )

        let result = LabPlotResolver.resolve(
            spec: spec,
            child: child,
            entries: [earlyEntry, recentEntry],
            now: now
        )

        XCTAssertEqual(result.panels.count, 2)
        // ANC: one point in window-1 (early), one in window-2 (recent).
        XCTAssertEqual(result.panels[0].parameter, "ANC")
        XCTAssertEqual(result.panels[0].windows[0].points.count, 1)
        XCTAssertEqual(result.panels[0].windows[0].points.first?.value, 1.2)
        XCTAssertEqual(result.panels[0].windows[1].points.count, 1)
        XCTAssertEqual(result.panels[0].windows[1].points.first?.value, 0.6)
        // HB: same shape.
        XCTAssertEqual(result.panels[1].parameter, "HB")
        XCTAssertEqual(result.panels[1].windows[0].points.first?.value, 9.0)
        XCTAssertEqual(result.panels[1].windows[1].points.first?.value, 8.5)
    }

    func test_displayLabel_phaseWithNoExplicitLabel_synthesisesGerman() {
        let label = LabPlotResolver.displayLabel(
            for: .phase(phase: "inductionIA", fromDay: 1, toDay: 14, label: nil)
        )
        XCTAssertTrue(label.contains("Tag 1–14"), "got: \(label)")
        XCTAssertTrue(label.contains("Induktion"), "got: \(label)")
    }

    func test_displayLabel_relativeDays_usesIdiomaticGerman() {
        XCTAssertEqual(
            LabPlotResolver.displayLabel(for: .relativeDays(daysBack: 7, label: nil)),
            "letzte Woche"
        )
        XCTAssertEqual(
            LabPlotResolver.displayLabel(for: .relativeDays(daysBack: 30, label: nil)),
            "letzter Monat"
        )
    }

    // MARK: - Helpers

    private func makeMultiLabEntry(
        anc: Double,
        hb: Double,
        on date: Date,
        phase: Phase,
        dayInPhase: Int
    ) -> JournalEntry {
        let labs = [
            LabValue(parameter: "ANC", germanLabel: "Neutrophile",
                     value: anc, unit: "G/L", measuredAt: date),
            LabValue(parameter: "HB", germanLabel: "Hämoglobin",
                     value: hb, unit: "g/dL", measuredAt: date),
        ]
        let fields = ExtractedFields(
            labValues: ConfidenceField(value: labs, confidence: 0.9)
        )
        return JournalEntry(
            childId: UUID(),
            visitDate: date,
            phase: phase,
            dayInPhase: dayInPhase,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            extractedFields: fields
        )
    }
}
