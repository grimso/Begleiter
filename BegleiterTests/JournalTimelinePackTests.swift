import XCTest
@testable import Begleiter

final class JournalTimelinePackTests: XCTestCase {

    // MARK: - Empty path

    /// Empty input → empty pack. Used by AskService when the parent's
    /// SwiftData store has no matching entries; the downstream
    /// empty-retrieval guard must still fire.
    func test_build_emptyEntries_returnsEmpty() {
        let pack = JournalTimelinePackBuilder.build(
            entries: [],
            budgetTokens: 10_000
        )
        XCTAssertEqual(pack.entries.count, 0)
        XCTAssertEqual(pack.omittedCount, 0)
        XCTAssertNil(pack.oldestIncludedDate)
        XCTAssertNil(pack.oldestOmittedDate)
        XCTAssertNil(pack.newestOmittedDate)
        XCTAssertEqual(pack.estimatedTokens, 0)
    }

    /// Zero-budget edge case. Builder must not crash and must return
    /// empty rather than a single overflowing entry — caller is
    /// responsible for picking a sensible budget.
    func test_build_zeroBudget_returnsEmpty() {
        let entries = (0..<5).map { makeEntry(daysAgo: $0 * 7) }
        let pack = JournalTimelinePackBuilder.build(
            entries: entries,
            budgetTokens: 0
        )
        XCTAssertEqual(pack.entries.count, 0)
        XCTAssertEqual(pack.omittedCount, 0)
    }

    // MARK: - Under-budget path

    /// All filtered entries fit → pack includes everything in
    /// chronological (oldest → newest) order, zero omissions.
    func test_build_underBudget_includesAllChronological() {
        let entries = (0..<5).map { makeEntry(daysAgo: $0 * 7, summary: "Eintrag-\($0)") }
        let pack = JournalTimelinePackBuilder.build(
            entries: entries,
            budgetTokens: 100_000  // way more than enough
        )

        XCTAssertEqual(pack.entries.count, 5)
        XCTAssertEqual(pack.omittedCount, 0)
        XCTAssertNil(pack.oldestOmittedDate)
        XCTAssertNil(pack.newestOmittedDate)
        XCTAssertGreaterThan(pack.estimatedTokens, 0)

        // Chronological — pack.entries.last is the most recent (daysAgo == 0).
        let dates = pack.entries.map(\.visitDate)
        let sortedAsc = dates.sorted()
        XCTAssertEqual(dates, sortedAsc, "Pack entries must be oldest → newest")
        XCTAssertEqual(pack.oldestIncludedDate, dates.first)
    }

    /// Input is presented newest-first to confirm the builder sorts
    /// internally — output is always chronological regardless of input
    /// order.
    func test_build_unsortedInput_isStillChronologicalOut() {
        let newestFirst = (0..<5).reversed().map { makeEntry(daysAgo: $0 * 7) }
        let pack = JournalTimelinePackBuilder.build(
            entries: newestFirst,
            budgetTokens: 100_000
        )
        let dates = pack.entries.map(\.visitDate)
        XCTAssertEqual(dates, dates.sorted())
    }

    // MARK: - Over-budget path

    /// Budget can't hold every entry → oldest gets dropped, omitted
    /// marker fields populated. Reflects the chronological-backfill
    /// design described in the plan: newest entries are strictly more
    /// useful for "what's happening now" reasoning.
    func test_build_overBudget_dropsOldest_setsOmittedMarker() {
        // 20 entries spaced one day apart. Each rendered block is ~120
        // chars (~30 tokens). A budget of 200 tokens should fit roughly
        // 6 entries — the math doesn't need to be exact, just that some
        // get dropped.
        let entries = (0..<20).map { makeEntry(daysAgo: $0) }
        let pack = JournalTimelinePackBuilder.build(
            entries: entries,
            budgetTokens: 200
        )

        XCTAssertGreaterThan(pack.entries.count, 0,
                             "Pack must include at least one entry even on tight budgets")
        XCTAssertLessThan(pack.entries.count, entries.count,
                          "Tight budget must drop at least one entry — fixture sized to ensure this")
        XCTAssertEqual(pack.entries.count + pack.omittedCount, entries.count)

        XCTAssertNotNil(pack.oldestIncludedDate)
        XCTAssertNotNil(pack.oldestOmittedDate)
        XCTAssertNotNil(pack.newestOmittedDate)
        // The oldest omitted date is the absolute oldest entry; the
        // oldest included date is more recent than that.
        XCTAssertLessThan(pack.oldestOmittedDate!, pack.oldestIncludedDate!)
        // Marker should reference both endpoints of the omitted window.
        let marker = JournalTimelinePackBuilder.omittedMarker(for: pack)
        XCTAssertNotNil(marker)
        XCTAssertTrue(marker?.contains("\(pack.omittedCount) earlier") ?? false,
                      "Omitted marker must mention the count of dropped entries")
    }

    /// No drops → no marker. Caller passes `nil` to `buildPrompt` which
    /// keeps existing tests on the empty-input path byte-identical.
    func test_omittedMarker_isNilWhenNothingDropped() {
        let entries = (0..<3).map { makeEntry(daysAgo: $0) }
        let pack = JournalTimelinePackBuilder.build(
            entries: entries,
            budgetTokens: 100_000
        )
        XCTAssertNil(JournalTimelinePackBuilder.omittedMarker(for: pack))
    }

    /// Always include at least one entry, even if a single entry by
    /// itself overflows the budget — the alternative (empty pack) is
    /// worse for the parent. The parent gets *something*; the omitted
    /// marker conveys "older material exists but was dropped."
    func test_build_alwaysIncludesAtLeastOneEntryEvenIfFirstOverflows() {
        let entries = (0..<5).map { makeEntry(daysAgo: $0, summary: String(repeating: "X", count: 4000)) }
        let pack = JournalTimelinePackBuilder.build(
            entries: entries,
            budgetTokens: 50  // far below a single entry's cost
        )
        XCTAssertEqual(pack.entries.count, 1,
                       "Pack must include exactly one entry when even the first overflows")
        XCTAssertEqual(pack.omittedCount, 4)
    }

    // MARK: - Determinism

    /// Same inputs → same pack. Important because the pack is used to
    /// derive `validEntryIds` for the citation filter; non-deterministic
    /// ordering would make filter outcomes flaky.
    func test_build_isDeterministic() {
        let entries = (0..<10).map { makeEntry(daysAgo: $0, summary: "Eintrag-\($0)") }
        let packA = JournalTimelinePackBuilder.build(entries: entries, budgetTokens: 500)
        let packB = JournalTimelinePackBuilder.build(entries: entries, budgetTokens: 500)
        XCTAssertEqual(packA.entries.map(\.entryId), packB.entries.map(\.entryId))
        XCTAssertEqual(packA.omittedCount, packB.omittedCount)
        XCTAssertEqual(packA.estimatedTokens, packB.estimatedTokens)
    }

    // MARK: - Per-entry char cap

    /// An entry with a very long summary gets truncated to the
    /// per-entry char cap. The header line (with the UUID) is always
    /// preserved so the model can still cite the entry by ID.
    func test_perEntryCharCap_truncatesTail_keepsHeader() {
        let entry = makeEntry(daysAgo: 0, summary: String(repeating: "A", count: 3000))
        let rendered = JournalTimelinePackBuilder.renderEntry(
            entry,
            index: 1,
            perEntryCharCap: 400
        )
        XCTAssertLessThanOrEqual(rendered.count, 401,  // 400 + 1 ellipsis
                                 "Rendered entry must respect per-entry char cap")
        XCTAssertTrue(rendered.contains(entry.entryId.uuidString),
                      "Header with UUID must survive truncation so the model can cite the entry")
        XCTAssertTrue(rendered.hasSuffix("…"),
                      "Truncated body must end with an ellipsis to signal cut-off")
    }

    /// Within the cap → no truncation, no ellipsis tail.
    func test_perEntryCharCap_underCap_noTruncation() {
        let entry = makeEntry(daysAgo: 0, summary: "kurz")
        let rendered = JournalTimelinePackBuilder.renderEntry(
            entry,
            index: 1,
            perEntryCharCap: 1200
        )
        XCTAssertFalse(rendered.hasSuffix("…"))
    }

    // MARK: - Variant budgets

    /// E2B is the conservative default — TTFT on iPhone 14 Pro with a
    /// 10 000-token prefill is the upper bound we've measured as
    /// usable. E4B doubles it because the 8 GB devices that run E4B
    /// have headroom for higher prefill latency.
    func test_budgetTokens_perVariant() {
        let e2b = JournalTimelinePackBuilder.budgetTokens(for: .e2b)
        let e4b = JournalTimelinePackBuilder.budgetTokens(for: .e4b)
        XCTAssertGreaterThan(e2b, 0)
        XCTAssertGreaterThan(e4b, e2b, "E4B budget should exceed E2B")
    }

    // MARK: - TokenEstimator

    func test_tokenEstimator_emptyStringIsZero() {
        XCTAssertEqual(TokenEstimator.estimateTokens(""), 0)
    }

    /// Non-empty strings always return ≥1 — keeps the budget loop from
    /// adding "free" entries even when an entry's rendered text rounds
    /// to zero in chars/4.
    func test_tokenEstimator_nonEmptyAtLeastOne() {
        XCTAssertGreaterThanOrEqual(TokenEstimator.estimateTokens("x"), 1)
    }

    // MARK: - Helpers

    private func makeEntry(daysAgo: Int, summary: String = "Routine") -> JournalEntry {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return JournalEntry(
            entryId: UUID(),
            childId: UUID(),
            visitDate: date,
            phase: .consolidationM,
            dayInPhase: 1,
            riskGroup: .standardRisk,
            arm: .standard,
            inputModalities: ["text"],
            rawText: nil,
            extractedFields: ExtractedFields(
                summary: ConfidenceField(value: summary, confidence: 0.95)
            )
        )
    }
}
