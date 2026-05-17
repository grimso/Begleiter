import Foundation

/// Post-process span recovery for imported-document chunks.
///
/// ``DocumentImportService`` asks Gemma to produce topical chunks
/// (Gemma's structured paraphrase of the source PDF). The prompt
/// requires verbatim copying of concrete values — drug names, lab
/// numbers, dates — but the surrounding prose is the model's own. So
/// after parsing the chunk array we walk each chunk's text against the
/// original ``ImportedDocument/sourceText`` and find the **longest
/// contiguous character run** the two share. That run is the chunk's
/// ``DocumentChunk/sourceSpan`` — a real anchor back into the source
/// PDF the UI can highlight when the parent taps a
/// `[D:docId#chunkIndex]` citation chip.
///
/// **Honest framing.** This does not turn the chunk into an extractive
/// citation; the chunk text is still Gemma's prose. But it does ship a
/// trustworthy *partial* source-span guarantee: when a span exists,
/// the parent can see the exact original characters Gemma was looking
/// at. When no span ≥ ``defaultMinSpanLength`` matches, we record
/// `nil` and the UI shows the chunk text alone with a "no verbatim
/// span recovered" note.
///
/// Pure function; no Gemma calls. Runs at import time inside
/// ``DocumentImportService`` after the chunk JSON parses.
nonisolated enum SourceSpanRecovery {
    /// Minimum span length we accept. Below this, the match is more
    /// likely to be a generic phrase ("Die Patientin", "Therapie mit")
    /// than a genuine source anchor — so we drop it. Tuned by hand
    /// against the demo Entlassungsbericht and a small sample of real
    /// discharge letters; documented in ``SourceSpanRecoveryTests``.
    static let defaultMinSpanLength: Int = 30

    /// Find the longest contiguous run of characters from `chunkText`
    /// that appears verbatim in `sourceText`. Returns the span's
    /// position in `sourceText`, or `nil` when no run reaches
    /// `minLength`.
    ///
    /// Algorithm: 1D dynamic-programming longest-common-substring with
    /// O(m) memory, O(n×m) time (n = chunk length, m = source length).
    /// For the import sizes we ship (`docImportMaxChars` ≤ 64 000,
    /// chunk text ~200–500 chars), this is single-digit milliseconds on
    /// device.
    ///
    /// Determinism: ties (multiple equally-long matches) are broken by
    /// taking the **first** occurrence in source order, so the recovery
    /// pass is repeatable across imports of the same PDF.
    static func findLongestVerbatimSpan(
        of chunkText: String,
        in sourceText: String,
        minLength: Int = defaultMinSpanLength
    ) -> SourceSpan? {
        guard minLength > 0 else { return nil }
        // Character arrays let the inner loop compare via `==` on
        // Character (grapheme cluster) — handles `°`, `½`, combining
        // accents correctly without falling back to UTF-16 surrogate
        // arithmetic.
        let chunk = Array(chunkText)
        let source = Array(sourceText)
        let n = chunk.count
        let m = source.count
        guard n > 0, m > 0 else { return nil }

        // dp[j] = longest common substring ending at chunk[i-1] /
        // source[j-1] for the current chunk row. Iterating j *down*
        // lets us read the (i-1, j-1) value off `dp[j-1]` before it's
        // overwritten this pass — that's how the 1D-collapse keeps the
        // last row available without a second buffer.
        var dp = [Int](repeating: 0, count: m + 1)
        var maxLen = 0
        var maxEnd = 0  // exclusive end index in `source`

        for i in 1...n {
            // Iterate j high → low so `dp[j-1]` still holds the
            // previous chunk-row's value when we read it (the 1D-
            // collapse trick). Side effect: this also surfaces later
            // source-position matches first within a single chunk-row
            // scan, so on ties we explicitly prefer the earlier
            // `maxEnd` to keep the recovery deterministic and aligned
            // with "first occurrence in source order."
            var j = m
            while j >= 1 {
                if chunk[i - 1] == source[j - 1] {
                    dp[j] = dp[j - 1] + 1
                    if dp[j] > maxLen || (dp[j] == maxLen && j < maxEnd) {
                        maxLen = dp[j]
                        maxEnd = j
                    }
                } else {
                    dp[j] = 0
                }
                j -= 1
            }
        }

        guard maxLen >= minLength else { return nil }
        return SourceSpan(start: maxEnd - maxLen, length: maxLen)
    }

    /// Convenience for ``DocumentImportService`` — re-emits a chunk
    /// with its `sourceSpan` populated (or left `nil`) given the
    /// original chunk and the source text it was derived from. Pure
    /// function; safe to call from any actor.
    static func annotated(
        chunk: DocumentChunk,
        sourceText: String,
        minLength: Int = defaultMinSpanLength
    ) -> DocumentChunk {
        let span = findLongestVerbatimSpan(
            of: chunk.text,
            in: sourceText,
            minLength: minLength
        )
        return DocumentChunk(
            index: chunk.index,
            kind: chunk.kind,
            text: chunk.text,
            sourceSpan: span
        )
    }
}
