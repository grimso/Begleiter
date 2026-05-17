import Foundation

/// Tolerant normalizer that sits between Gemma's raw decoded `LabPlotSpec`
/// and the resolver. Three responsibilities:
///   1. Canonicalize parameters via ``LabParameterCanonicalizer`` so
///      synonyms like `"Leukozyten"` survive into the resolver as `"WBC"`.
///   2. Canonicalize phase windows — the model often emits the
///      human-readable form ("Induktion IA") instead of the
///      ``Phase`` rawValue. Drop windows whose phase string can't be
///      resolved either way.
///   3. Validate that the spec still has at least one parameter and one
///      window after normalisation. Empty specs become typed parser
///      errors instead of silently producing an empty plot.
///
/// Pure-Swift, `nonisolated enum`. No I/O. The Gemma path calls this
/// once per inference attempt; the heuristic path skips it because its
/// own pipeline already emits canonical short codes and rawValues.
nonisolated enum LabPlotSpecNormalizer {

    /// Canonicalize → validate. Returns the cleaned spec on success or a
    /// typed ``LabPlotParserError`` matching the error surface the
    /// heuristic path already produces, so the composer view's error
    /// banner doesn't need to know which parser failed.
    static func normalize(_ spec: LabPlotSpec) -> Result<LabPlotSpec, LabPlotParserError> {
        // 1. Parameters — canonicalize + dedupe preserving order.
        var seen: Set<String> = []
        var canonicalParameters: [String] = []
        for raw in spec.parameters {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let canonical = LabParameterCanonicalizer.canonical(for: trimmed)
            if seen.insert(canonical).inserted {
                canonicalParameters.append(canonical)
            }
        }

        // 2. Windows — canonicalize phase rawValues, clamp day ranges,
        //    drop windows whose phase string is unrecognised.
        var canonicalWindows: [LabPlotSpec.Window] = []
        for window in spec.windows {
            switch window {
            case .phase(let rawPhase, let fromDay, let toDay, let label):
                guard let phase = resolvePhase(rawPhase) else { continue }
                let (clampedFrom, clampedTo) = clampDayRange(fromDay: fromDay, toDay: toDay, phase: phase)
                canonicalWindows.append(.phase(
                    phase: phase.rawValue,
                    fromDay: clampedFrom,
                    toDay: clampedTo,
                    label: label
                ))
            case .relativeDays(let daysBack, let label):
                let clamped = max(1, min(daysBack, 365 * 5))
                canonicalWindows.append(.relativeDays(daysBack: clamped, label: label))
            case .absolute(let from, let to, let label):
                canonicalWindows.append(.absolute(
                    from: min(from, to),
                    to:   max(from, to),
                    label: label
                ))
            }
        }

        // 3. Validation gate.
        guard !canonicalParameters.isEmpty else {
            return .failure(.noParametersResolved)
        }
        guard !canonicalWindows.isEmpty else {
            return .failure(.noWindowsResolved)
        }

        return .success(LabPlotSpec(
            title: spec.title,
            parameters: canonicalParameters,
            windows: canonicalWindows,
            layout: spec.layout
        ))
    }

    // MARK: - Phase resolution

    /// Resolve a raw phase string from Gemma onto a canonical
    /// ``Phase``. Tries `Phase(rawValue:)` first, then a folded synonym
    /// table that mirrors ``LabPlotParser``'s heuristic table — so
    /// "Induktion IA", "Protokoll IA", "Konsolidierung", etc. all map
    /// to the right phase.
    private static func resolvePhase(_ raw: String) -> Phase? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Phase(rawValue: trimmed) { return direct }
        let folded = fold(trimmed)
        return phaseSynonyms[folded].flatMap(Phase.init(rawValue:))
    }

    /// Lower-case + diacritic-fold (matches ``LabPlotParser.foldedForMatching``).
    private static func fold(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "de"))
            .replacingOccurrences(of: "ß", with: "ss")
    }

    /// German + English synonym → `Phase.rawValue`. Keys are folded.
    /// Mirrors the heuristic parser's table; kept in sync deliberately.
    private static let phaseSynonyms: [String: String] = [
        "induktion ia":            "inductionIA",
        "induktion 1a":            "inductionIA",
        "induktion":               "inductionIA",
        "induction ia":            "inductionIA",
        "induction":               "inductionIA",
        "protokoll ia":            "inductionIA",
        "protokoll 1a":            "inductionIA",
        "protocol ia":             "inductionIA",

        "induktion ib":            "inductionIB",
        "induktion 1b":            "inductionIB",
        "induction ib":            "inductionIB",
        "protokoll ib":            "inductionIB",
        "protokoll 1b":            "inductionIB",
        "protocol ib":             "inductionIB",

        "konsolidierung m":        "consolidationM",
        "konsolidierung":          "consolidationM",
        "consolidation m":         "consolidationM",
        "consolidation":           "consolidationM",
        "protokoll m":             "consolidationM",
        "protocol m":              "consolidationM",

        "konsolidierung hr1":      "consolidationHR1",
        "konsolidierung hr 1":     "consolidationHR1",
        "consolidation hr1":       "consolidationHR1",
        "hr-1":                    "consolidationHR1",
        "hr1":                     "consolidationHR1",

        "konsolidierung hr2":      "consolidationHR2",
        "konsolidierung hr 2":     "consolidationHR2",
        "consolidation hr2":       "consolidationHR2",
        "hr-2":                    "consolidationHR2",
        "hr2":                     "consolidationHR2",

        "konsolidierung hr3":      "consolidationHR3",
        "konsolidierung hr 3":     "consolidationHR3",
        "consolidation hr3":       "consolidationHR3",
        "hr-3":                    "consolidationHR3",
        "hr3":                     "consolidationHR3",

        "reinduktion ii":          "reinductionII",
        "reinduktion 2":           "reinductionII",
        "reinduktion":             "reinductionII",
        "reinduction ii":          "reinductionII",
        "reinduction":             "reinductionII",
        "protokoll ii":            "reinductionII",
        "protokoll 2":             "reinductionII",
        "protocol ii":             "reinductionII",

        "erhaltung":               "maintenance",
        "erhaltungstherapie":      "maintenance",
        "maintenance":             "maintenance",
    ]

    /// Clamp the (fromDay, toDay) pair so it stays inside a reasonable
    /// window for the phase. Three responsibilities:
    /// - Catch model hallucinations like `toDay: 9999`: cap to 2× the
    ///   phase's typical duration.
    /// - Catch the model's lazy default `fromDay: 1, toDay: 1` (a 1-day
    ///   slice that never matches in practice — the parent who said
    ///   "Konsolidierung M" almost always meant the whole phase): when
    ///   the range collapses to a single day, expand to the phase's
    ///   `typicalDurationDays`. Short-by-design windows like
    ///   `fromDay: 1, toDay: 7` (parent said "first 7 days") pass
    ///   through unmodified because they already span > 1 day.
    /// - Ensure lo ≥ 1 and hi ≥ lo.
    private static func clampDayRange(fromDay: Int, toDay: Int, phase: Phase) -> (Int, Int) {
        let typical = PhaseMetadata.for(phase).typicalDurationDays
        let upperCap = max(1, typical * 2)
        let lo = max(1, min(fromDay, upperCap))
        var hi = max(lo, min(max(fromDay, toDay), upperCap))
        if hi == lo {
            hi = max(lo, typical)
        }
        return (lo, hi)
    }
}
