import Foundation

/// A chronologically-ordered slice of the parent's journal, sized to fit
/// inside a single Gemma 4 prompt as long-context input. This is the
/// **default journal-context shape** for `AskService.answer(_:in:)` in
/// `.chat` mode when ``AppSettings/askTimelinePackEnabled`` is on —
/// replacing the previous "top-4 BM25 hits" path with the full timeline
/// (or as much of it as fits the per-model budget).
///
/// The pack is **always chronological, oldest → newest**. Putting the
/// most recent entries at the bottom of the prompt anchors the model on
/// "what's happening now" — the question the parent is most often
/// actually asking ("what reactions has my child had", "when did the
/// last X happen") wants the recent material near the answer.
///
/// **Overflow policy: chronological backfill from newest, drop oldest.**
/// When the token budget can't hold every filtered entry, the builder
/// walks newest → oldest, accumulating tokens, and stops once the
/// budget is exhausted. Older entries are dropped — recent material is
/// strictly more useful for "what is the current state" reasoning, and
/// rolling summaries of older windows are post-submission polish (see
/// the plan file, S2 risks).
///
/// **No on-the-fly Gemma summarization.** The pack is built from the
/// pre-extracted fields produced at ingest time (drugs, labs,
/// reactions, observations, openQuestions, summary) — no model calls
/// happen during pack assembly. The whole module is deterministic and
/// unit-testable without Gemma.
nonisolated struct JournalTimelinePack: Sendable, Hashable {
    /// Entries that fit inside the budget, sorted **oldest → newest**.
    /// `entries.last` is the most recent journal entry.
    let entries: [JournalEntry]

    /// How many entries were dropped from the oldest end of the timeline
    /// to fit the budget. `0` means the full filtered set fit.
    let omittedCount: Int

    /// `visitDate` of the oldest entry included in `entries`.
    /// `nil` when `entries` is empty.
    let oldestIncludedDate: Date?

    /// `visitDate` of the oldest entry that was **dropped**.
    /// `nil` when `omittedCount == 0`.
    let oldestOmittedDate: Date?

    /// `visitDate` of the newest entry that was dropped — i.e. the entry
    /// immediately older than `oldestIncludedDate` in the source set.
    /// `nil` when `omittedCount == 0`. Used in the omitted-range
    /// description that gets prepended to the prompt.
    let newestOmittedDate: Date?

    /// Approximate prompt-side token cost of the pack's entry blocks
    /// (sum of `TokenEstimator.estimateTokens` over each rendered
    /// entry's text). Surfaces in `AskDebugInfo.timelinePackTokens` for
    /// the Diagnose sheet.
    let estimatedTokens: Int

    /// Hand-back of the per-entry char cap the builder used. Tests
    /// assert against this to verify truncation behaviour.
    let perEntryCharCap: Int

    /// Empty pack — no entries, no tokens used. Returned for fresh
    /// installs and for unit tests that want to exercise the empty
    /// path.
    static let empty = JournalTimelinePack(
        entries: [],
        omittedCount: 0,
        oldestIncludedDate: nil,
        oldestOmittedDate: nil,
        newestOmittedDate: nil,
        estimatedTokens: 0,
        perEntryCharCap: 0
    )
}

/// Stateless builder for ``JournalTimelinePack``. All methods are
/// deterministic given fixed inputs — important for the unit tests that
/// pin overflow behaviour without running Gemma.
nonisolated enum JournalTimelinePackBuilder {
    /// Default per-entry character cap. Most entries with pre-extracted
    /// fields render well under this; the cap exists as a safety net so
    /// a single entry with a 5 000-char `rawText` field can't dominate
    /// the budget.
    static let defaultPerEntryCharCap: Int = 1200

    /// Build a chronological pack from `entries`. Inputs need not be
    /// pre-sorted — the builder sorts internally to ensure deterministic
    /// output regardless of the SwiftData query order.
    ///
    /// - Parameters:
    ///   - entries: Candidate journal entries already filtered by scope
    ///     (e.g. `RetrievalService.Filters.labsOnly` for the labs scope).
    ///     Pre-extracted fields drive the rendered tokens; entries with
    ///     `ExtractedFields.empty` still get a one-line header row.
    ///   - budgetTokens: Soft cap on the pack's prompt-side token cost.
    ///     The builder stops adding entries once accumulated tokens
    ///     would exceed this number. `0` returns ``JournalTimelinePack/empty``.
    ///   - perEntryCharCap: Per-entry rendering cap before truncation
    ///     (default ``defaultPerEntryCharCap``).
    static func build(
        entries: [JournalEntry],
        budgetTokens: Int,
        perEntryCharCap: Int = defaultPerEntryCharCap
    ) -> JournalTimelinePack {
        guard budgetTokens > 0, !entries.isEmpty else {
            return .empty
        }

        // Sort newest → oldest for the backfill walk. We reverse before
        // emitting so the final order is oldest → newest.
        let newestFirst = entries.sorted { $0.visitDate > $1.visitDate }

        var includedReversed: [JournalEntry] = []
        var usedTokens = 0
        var firstDroppedIndex: Int? = nil

        for (index, entry) in newestFirst.enumerated() {
            let rendered = renderEntry(
                entry,
                index: includedReversed.count + 1,
                perEntryCharCap: perEntryCharCap
            )
            let tokens = TokenEstimator.estimateTokens(rendered)
            if usedTokens + tokens > budgetTokens, !includedReversed.isEmpty {
                // We have at least one entry already; this one doesn't
                // fit. Stop here — older entries get dropped.
                firstDroppedIndex = index
                break
            }
            includedReversed.append(entry)
            usedTokens += tokens
            // Always include at least one entry, even if it overflows
            // the budget on its own — the alternative is an empty pack
            // which is worse for the parent.
        }

        // Check whether the loop ran past every candidate (no drops) or
        // stopped early (drops).
        if firstDroppedIndex == nil, includedReversed.count < newestFirst.count {
            firstDroppedIndex = includedReversed.count
        }

        let included = Array(includedReversed.reversed()) // oldest → newest

        let omittedCount = newestFirst.count - includedReversed.count
        let oldestIncluded = included.first?.visitDate
        let newestOmitted: Date? = {
            guard let i = firstDroppedIndex, i < newestFirst.count else { return nil }
            return newestFirst[i].visitDate
        }()
        let oldestOmitted: Date? = {
            guard omittedCount > 0 else { return nil }
            return newestFirst.last?.visitDate
        }()

        return JournalTimelinePack(
            entries: included,
            omittedCount: omittedCount,
            oldestIncludedDate: oldestIncluded,
            oldestOmittedDate: oldestOmitted,
            newestOmittedDate: newestOmitted,
            estimatedTokens: usedTokens,
            perEntryCharCap: perEntryCharCap
        )
    }

    /// Per-variant token budget. E2B starts conservative — TTFT on
    /// iPhone 14 Pro with a 10 000-token prefill is ~6–10 s; raising
    /// this is a post-measurement decision (see plan §S2 risks). E4B
    /// runs on 8 GB devices with more headroom.
    static func budgetTokens(for variant: ModelVariant) -> Int {
        switch variant {
        case .e2b: return 10_000
        case .e4b: return 20_000
        }
    }

    /// Render a single entry as a compact prompt block. Format matches
    /// the existing ``AskService/buildPrompt(question:entries:chunks:)``
    /// entry block format with a `phase=` segment added to the header.
    /// Truncated to `perEntryCharCap` characters at the tail if needed —
    /// the header is always preserved so the model can still cite by ID.
    static func renderEntry(
        _ entry: JournalEntry,
        index: Int,
        perEntryCharCap: Int = defaultPerEntryCharCap
    ) -> String {
        let date = ISO8601DateFormatter.justDate.string(from: entry.visitDate)
        let phase = entry.phase.rawValue
        let f = entry.extractedFields
        var lines: [String] = [
            "[ENTRY \(index)] id=\(entry.entryId.uuidString) datum=\(date) phase=\(phase)"
        ]
        if let summary = f.summary?.value, !summary.isEmpty {
            lines.append("zusf: \(summary)")
        }
        if let drugs = f.drugsMentioned?.value, !drugs.isEmpty {
            lines.append("med: \(drugs.map { $0.germanLabel }.joined(separator: ", "))")
        }
        if let labs = f.labValues?.value, !labs.isEmpty {
            let lab = labs.map { "\($0.germanLabel) \($0.value)\($0.unit)" }.joined(separator: ", ")
            lines.append("lab: \(lab)")
        }
        if let rx = f.reactions?.value, !rx.isEmpty {
            lines.append("rx: \(rx.map { $0.description }.joined(separator: "; "))")
        }
        if let obs = f.parentObservations?.value, !obs.isEmpty {
            lines.append("obs: \(obs.joined(separator: "; "))")
        }
        if let asks = f.openQuestions?.value, !asks.isEmpty {
            lines.append("frg: \(asks.joined(separator: "; "))")
        }
        if let decisions = f.decisions?.value, !decisions.isEmpty {
            lines.append("ent: \(decisions.joined(separator: "; "))")
        }
        let block = lines.joined(separator: "\n")
        guard block.count > perEntryCharCap else { return block }

        // Truncate at the body but keep the header line intact. The
        // header carries the ID the model must cite from.
        let header = lines.first ?? ""
        let bodyBudget = max(0, perEntryCharCap - header.count - 1)
        let body = block.dropFirst(header.count + 1)
        let truncatedBody = body.prefix(bodyBudget)
        return header + "\n" + truncatedBody + "…"
    }

    /// Prose marker describing the entries dropped from the oldest end
    /// of the timeline. Prepended to the prompt's `JOURNAL ENTRIES:`
    /// section so the model knows it's looking at a window, not the
    /// entire journal. Returns `nil` when no entries were dropped.
    ///
    /// The marker is deliberately **not** wrapped in `[ENTRY n]` syntax —
    /// it doesn't carry a UUID and must never be cited. The citation
    /// parser will drop any `[E:...]` token whose body isn't a valid
    /// UUID, so even if Gemma hallucinated a cite to this marker it
    /// would be filtered out at parse time.
    static func omittedMarker(for pack: JournalTimelinePack) -> String? {
        guard pack.omittedCount > 0,
              let oldestOmitted = pack.oldestOmittedDate,
              let newestOmitted = pack.newestOmittedDate
        else { return nil }
        let from = ISO8601DateFormatter.justDate.string(from: oldestOmitted)
        let to = ISO8601DateFormatter.justDate.string(from: newestOmitted)
        return "NOTE: \(pack.omittedCount) earlier journal entries from \(from) to \(to) were omitted from this pack to fit the context budget. The included entries below run chronologically, oldest → newest."
    }
}

/// Cheap, deterministic token-count estimator. Uses a chars/4 heuristic
/// which slightly over-estimates German text — preferable to a strict
/// lower bound because the safety margin keeps us off the model's
/// context ceiling.
///
/// We deliberately do **not** call the actual MLX tokenizer here. The
/// tokenizer lives inside the loaded-model actor and isn't reachable
/// from prompt-assembly code without an `await`; the heuristic is
/// good enough for budgeting decisions and lets the pack builder stay
/// `nonisolated`.
nonisolated enum TokenEstimator {
    /// Approximate token count for `text`. Returns at least 1 for
    /// non-empty input (the chat template adds a small constant
    /// overhead per block).
    static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.count / 4 + 1
    }
}

private extension ISO8601DateFormatter {
    static let justDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}
