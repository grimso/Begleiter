import Foundation

/// Pure-Swift heuristic that decides whether a German question is asking
/// about **past events from the journal** (e.g. "Welche allergischen
/// Reaktionen gab es?") versus general knowledge (e.g. "Was sind die
/// Nebenwirkungen von Methotrexat?").
///
/// Used by `AskService.answer(...)` as a safety net: when the question
/// looks like an event-question AND journal retrieval returned zero
/// hits, the service short-circuits before Gemma with the canonical
/// "Im Journal finde ich dazu keinen Eintrag." answer — instead of
/// letting Gemma paraphrase a corpus chunk into something that reads
/// like a journal claim.
///
/// Detection is intentionally pattern-based and conservative: we'd
/// rather miss some event-questions (letting Gemma answer with both
/// sources) than over-refuse knowledge-questions. The phrase list
/// targets idiomatic past-tense constructions parents actually use in
/// German clinic conversations.
///
/// Behaviour is wholly controlled by
/// `AppSettings.askEventGuardEnabled` (default `true`); flipping the
/// toggle off in Settings → Entwicklung disables the guard for
/// side-by-side comparison.
nonisolated enum EventQuestionDetector {

    /// Phrases that strongly signal a past-tense event question in
    /// German parent-clinic conversations. Matched case-insensitively
    /// against the foldedForMatching-normalised question (umlauts
    /// stripped, lowercased) — same fold `RefusalService` uses, so the
    /// behaviour is consistent across the codebase.
    ///
    /// **Curation guideline**: a phrase only earns its place here if
    /// it almost never appears in knowledge-questions. "hatte" alone is
    /// too broad ("Was hatte für Nebenwirkungen Methotrexat?"); but
    /// "wann hatte" is safe. False-positives produce a stricter
    /// refusal than necessary; false-negatives just let the normal
    /// flow run, which is fine.
    static let eventPhrases: [String] = [
        "gab es",
        "wann gab",
        "wann hatte",
        "wann hat",
        "wann war",
        "wann ist",
        "wann sind",
        "wann wurde",
        "wie war",
        "wie ist verlaufen",
        "wie verlief",
        "wann verlief",
        "was ist passiert",
        "was passiert ist",
        "ist aufgetreten",
        "sind aufgetreten",
        "hat mein kind",
        "hatte mein kind",
        "hatte luca",
        "hatten wir",
        "hatten sie",
        "war der letzte",
        "war die letzte",
        "war das letzte",
    ]

    /// Returns `true` if `question` looks like a past-tense event
    /// question over the parent's journal. Caller is expected to also
    /// check that journal retrieval returned no hits before short-
    /// circuiting — this function on its own doesn't know what's in
    /// the journal.
    static func looksLikeEventQuestion(_ question: String) -> Bool {
        let needle = foldedForMatching(question)
        for phrase in eventPhrases {
            if needle.contains(phrase) { return true }
        }
        return false
    }

    /// Lowercased + diacritic-folded form used for matching. Mirrors
    /// `RefusalService.foldedForMatching` (private there) so the two
    /// safety nets normalise identically.
    private static func foldedForMatching(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "de"))
            .replacingOccurrences(of: "ß", with: "ss")
    }
}
