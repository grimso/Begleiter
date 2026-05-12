import XCTest
@testable import Begleiter

/// Tests for `LabSeries.aggregate(entries:)` — the pure aggregation core
/// that feeds the new Blutwerte top-level surface.
///
/// All tests construct fixture `JournalEntry`s via the public initialiser
/// — no `ModelContainer` required, so the suite runs on the simulator
/// without touching SwiftData persistence or MLX.
final class LabSeriesTests: XCTestCase {

    // MARK: - Fixture helpers

    private func makeEntry(
        visitDate: Date = .now,
        labs: [LabValue],
        status: ProcessingStatus = .extracted
    ) -> JournalEntry {
        var fields = ExtractedFields.empty
        fields.labValues = ConfidenceField(value: labs, confidence: 0.9)
        return JournalEntry(
            childId: UUID(),
            visitDate: visitDate,
            phase: .inductionIA,
            dayInPhase: 1,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            rawText: "fixture",
            extractedFields: fields,
            processingStatus: status
        )
    }

    private func lab(
        _ parameter: String,
        _ value: Double,
        unit: String = "G/L",
        refMin: Double? = nil,
        refMax: Double? = nil,
        at date: Date = .now,
        source: LabValue.Source = .befundPhoto,
        germanLabel: String? = nil
    ) -> LabValue {
        LabValue(
            parameter: parameter,
            germanLabel: germanLabel ?? parameter,
            value: value,
            unit: unit,
            referenceMin: refMin,
            referenceMax: refMax,
            measuredAt: date,
            source: source
        )
    }

    private func date(_ daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
    }

    // MARK: - Tests

    func test_aggregate_empty_returnsEmpty() {
        XCTAssertTrue(LabSeries.aggregate(entries: []).isEmpty)
    }

    func test_aggregate_groupsByParameter_caseInsensitive_andFoldsHgbIntoHb() {
        let entries = [
            makeEntry(visitDate: date(2), labs: [lab("Hb", 11.0, unit: "g/dL", at: date(2))]),
            makeEntry(visitDate: date(1), labs: [lab("HGB", 10.5, unit: "g/dL", at: date(1))]),
        ]
        let series = LabSeries.aggregate(entries: entries)

        XCTAssertEqual(series.count, 1, "Hb and HGB should fold into one series")
        XCTAssertEqual(series[0].parameter, "HB")
        XCTAssertEqual(series[0].points.count, 2)
    }

    func test_aggregate_ordersByPriorityThenAlpha() {
        // Priority is ANC, PLT, HB, WBC, CRP, ALT, AST — then alphabetical
        let entries = [
            makeEntry(labs: [
                lab("ZZZ", 1),           // alpha tail
                lab("CRP", 3, unit: "mg/L"),
                lab("ANC", 0.8),
                lab("AAA", 1),           // alpha tail (sorted before ZZZ)
                lab("HB", 11, unit: "g/dL"),
                lab("PLT", 50),
            ]),
        ]
        let series = LabSeries.aggregate(entries: entries)
        XCTAssertEqual(series.map(\.parameter), ["ANC", "PLT", "HB", "CRP", "AAA", "ZZZ"])
    }

    func test_aggregate_skipsNonExtractedEntries() {
        let entries = [
            makeEntry(visitDate: date(3), labs: [lab("ANC", 1.0, at: date(3))], status: .pending),
            makeEntry(visitDate: date(2), labs: [lab("ANC", 1.2, at: date(2))], status: .extracting),
            makeEntry(visitDate: date(1), labs: [lab("ANC", 1.5, at: date(1))], status: .failed(message: "x")),
        ]
        XCTAssertTrue(LabSeries.aggregate(entries: entries).isEmpty)

        let mixed = entries + [
            makeEntry(visitDate: date(0), labs: [lab("ANC", 1.8, at: date(0))], status: .extracted),
        ]
        let series = LabSeries.aggregate(entries: mixed)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].points.count, 1, "only the .extracted entry's point counts")
    }

    func test_aggregate_pointsSortedAscendingByMeasuredAt() {
        // Feed entries in mixed order; measurement dates also out of order.
        let entries = [
            makeEntry(visitDate: date(1), labs: [lab("ANC", 2.0, at: date(1))]),
            makeEntry(visitDate: date(5), labs: [lab("ANC", 0.5, at: date(5))]),
            makeEntry(visitDate: date(3), labs: [lab("ANC", 1.2, at: date(3))]),
        ]
        let series = LabSeries.aggregate(entries: entries)
        XCTAssertEqual(series.count, 1)
        let dates = series[0].points.map(\.date)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(series[0].points.map(\.value), [0.5, 1.2, 2.0])
    }

    func test_aggregate_referenceRange_takesMostRecentNonNil() {
        // Newer measurement supplies the band → use newer.
        let newer = makeEntry(visitDate: date(1), labs: [
            lab("PLT", 80, refMin: 150, refMax: 400, at: date(1)),
        ])
        let older = makeEntry(visitDate: date(5), labs: [
            lab("PLT", 60, refMin: 140, refMax: 380, at: date(5)),
        ])
        let series = LabSeries.aggregate(entries: [newer, older])
        XCTAssertEqual(series[0].referenceMin, 150)
        XCTAssertEqual(series[0].referenceMax, 400)
    }

    func test_aggregate_referenceRange_fallsBackToOlderWhenNewerLacksIt() {
        let newer = makeEntry(visitDate: date(1), labs: [
            lab("PLT", 80, at: date(1)),                                     // no refRange
        ])
        let older = makeEntry(visitDate: date(5), labs: [
            lab("PLT", 60, refMin: 140, refMax: 380, at: date(5)),
        ])
        let series = LabSeries.aggregate(entries: [newer, older])
        XCTAssertEqual(series[0].referenceMin, 140)
        XCTAssertEqual(series[0].referenceMax, 380)
    }

    func test_trend_up_down_stable() {
        let goingUp = makeEntry(visitDate: date(1), labs: [
            lab("ANC", 1.0, at: date(2)),
            lab("ANC", 1.5, at: date(1)),   // +50%
        ])
        let goingDown = makeEntry(visitDate: date(1), labs: [
            lab("WBC", 4.0, at: date(2)),
            lab("WBC", 3.0, at: date(1)),   // −25%
        ])
        let stable = makeEntry(visitDate: date(1), labs: [
            lab("HB", 11.0, unit: "g/dL", at: date(2)),
            lab("HB", 11.2, unit: "g/dL", at: date(1)),  // ~2% < 5% threshold
        ])
        let series = LabSeries.aggregate(entries: [goingUp, goingDown, stable])
        let byName = Dictionary(uniqueKeysWithValues: series.map { ($0.parameter, $0) })
        XCTAssertEqual(byName["ANC"]?.trend, .up)
        XCTAssertEqual(byName["WBC"]?.trend, .down)
        XCTAssertEqual(byName["HB"]?.trend, .stable)
    }

    func test_trend_singlePoint_isStable() {
        let entry = makeEntry(labs: [lab("ANC", 0.4)])
        let series = LabSeries.aggregate(entries: [entry])
        XCTAssertEqual(series[0].trend, .stable, "no previous point → stable, not panicked into a direction")
    }

    func test_isLatestOutOfRange_belowMin_aboveMax_inBand_andWhenUnknown() {
        let belowMin = makeEntry(labs: [lab("ANC", 0.3, refMin: 1.0, refMax: 7.0)])
        let aboveMax = makeEntry(labs: [lab("CRP", 50, unit: "mg/L", refMin: 0, refMax: 5)])
        let inBand   = makeEntry(labs: [lab("HB", 12.0, unit: "g/dL", refMin: 10, refMax: 14)])
        let noBand   = makeEntry(labs: [lab("WBC", 3.0)])

        let series = LabSeries.aggregate(entries: [belowMin, aboveMax, inBand, noBand])
        let byName = Dictionary(uniqueKeysWithValues: series.map { ($0.parameter, $0) })

        XCTAssertEqual(byName["ANC"]?.isLatestOutOfRange, true)
        XCTAssertEqual(byName["CRP"]?.isLatestOutOfRange, true)
        XCTAssertEqual(byName["HB"]?.isLatestOutOfRange, false)
        XCTAssertEqual(byName["WBC"]?.isLatestOutOfRange, false, "no reference band → never out of range")
    }

    func test_canonicalKey_normalisesSynonyms() {
        XCTAssertEqual(LabSeries.canonicalKey(for: "anc"), "ANC")
        XCTAssertEqual(LabSeries.canonicalKey(for: " Hb "), "HB")
        XCTAssertEqual(LabSeries.canonicalKey(for: "HGB"), "HB")
        XCTAssertEqual(LabSeries.canonicalKey(for: "Hämoglobin"), "HB")
        XCTAssertEqual(LabSeries.canonicalKey(for: "Hemoglobin"), "HB")
        XCTAssertEqual(LabSeries.canonicalKey(for: "PLT"), "PLT")
    }
}
