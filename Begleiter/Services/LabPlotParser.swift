import Foundation
import MLXLMCommon
import OSLog

private let plotLog = Logger(subsystem: "io.grimso.Begleiter", category: "labs.plot")

/// Which path turns a natural-language question into a `LabPlotSpec`.
/// The composer view shows a segmented picker; the user can A/B both on
/// the same question.
nonisolated enum LabPlotParserKind: String, Sendable, Hashable, CaseIterable {
    /// Pure-Swift regex + dictionary scanner. Fast, deterministic,
    /// offline. Covers the seed example and the four starter chips by
    /// design.
    case heuristic
    /// Asks Gemma to emit a `LabPlotSpec` JSON given the canonical
    /// parameter list, phase raw values, and the schema. Slower, more
    /// flexible — handles synonyms and phrasings the heuristic misses.
    /// Landed in a follow-up chunk.
    case gemma
}

/// Errors the parser surfaces. The composer view renders them as a
/// banner above the input so the parent can revise the wording.
enum LabPlotParserError: Error, LocalizedError {
    case noParametersResolved
    case noWindowsResolved
    case gemmaReturnedNoJSON
    case gemmaReturnedInvalidJSON(String)
    case gemmaError(String)

    var errorDescription: String? {
        switch self {
        case .noParametersResolved:
            return "Konnte keine Laborwerte aus der Frage erkennen. Bitte explizit nennen (z.B. 'Blutbild', 'HB', 'CRP')."
        case .noWindowsResolved:
            return "Konnte keinen Zeitraum aus der Frage erkennen. Bitte z.B. 'Induktion IA Woche 1-2' oder 'letzte Woche' angeben."
        case .gemmaReturnedNoJSON:
            return "Gemma hat keinen JSON-Block geliefert."
        case .gemmaReturnedInvalidJSON(let detail):
            return "Gemma hat ungültiges JSON geliefert: \(detail)"
        case .gemmaError(let detail):
            return "Gemma-Aufruf fehlgeschlagen: \(detail)"
        }
    }
}

/// Turns a free-form German question like "Blutbild für die ersten zwei
/// Wochen in Induktion und die letzte Woche nebeneinander" into a
/// `LabPlotSpec`. Two paths share the same surface so callers can swap.
actor LabPlotParser {

    /// App-wide singleton — both paths are stateless apart from the
    /// shared `GemmaService`, which is also a singleton.
    static let shared = LabPlotParser()

    private let gemma: GemmaService

    init(gemma: GemmaService = .shared) {
        self.gemma = gemma
    }

    /// Parse a German question into a spec.
    /// - Parameters:
    ///   - question: parent's raw input. Mixed case OK.
    ///   - kind: which parser to run. `.heuristic` is offline; `.gemma`
    ///     hits the on-device model and is slower.
    func parse(
        question: String,
        kind: LabPlotParserKind
    ) async throws -> LabPlotSpec {
        switch kind {
        case .heuristic:
            return try Self.parseHeuristic(question: question)
        case .gemma:
            return try await parseViaGemma(question: question)
        }
    }

    // MARK: - Heuristic path

    /// Canonical short-hands → expanded parameter list. Keys are lower-
    /// cased and diacritic-folded (matches `foldedForMatching`).
    private static let parameterShorthands: [String: [String]] = [
        "blutbild":       ["WBC", "ANC", "HB", "PLT"],
        "blutwerte":      ["WBC", "ANC", "HB", "PLT"],
        "cbc":            ["WBC", "ANC", "HB", "PLT"],
        "leberwerte":     ["ALT", "AST", "GGT", "Bili"],
        "nierenwerte":    ["Krea", "Na", "K"],
        "entzundung":     ["CRP", "LDH"],   // entzündung folded
        "entzundungswerte": ["CRP", "LDH"],
    ]

    /// Individual canonical short codes the parser recognises directly,
    /// keyed by lower-case/folded display form.
    private static let parameterDirect: [String: String] = [
        "wbc": "WBC", "leukos": "WBC", "leukozyten": "WBC",
        "anc": "ANC", "neutros": "ANC", "neutrophile": "ANC",
        "hb": "HB",   "hamoglobin": "HB", "hemoglobin": "HB",
        "hgb": "HB",
        "plt": "PLT", "thrombos": "PLT", "thrombozyten": "PLT",
        "crp": "CRP",
        "ldh": "LDH",
        "alt": "ALT", "gpt": "ALT",
        "ast": "AST", "got": "AST",
        "ggt": "GGT",
        "bili": "Bili", "bilirubin": "Bili",
        "krea": "Krea", "kreatinin": "Krea",
        "na":  "Na",  "natrium": "Na",
        "k":   "K",   "kalium":  "K",
    ]

    /// Phase synonyms → `Phase.rawValue`. Lower-case + diacritic-folded.
    /// "Induktion" without a suffix maps to IA (the default starting
    /// phase); the parser also accepts "Induktion IA"/"Protokoll IA".
    private static let phaseSynonyms: [String: String] = [
        "induktion ia":       "inductionIA",
        "induktion":          "inductionIA",
        "protokoll ia":       "inductionIA",
        "induktion ib":       "inductionIB",
        "protokoll ib":       "inductionIB",
        "konsolidierung m":   "consolidationM",
        "konsolidierung":     "consolidationM",
        "protokoll m":        "consolidationM",
        "konsolidierung hr1": "consolidationHR1",
        "konsolidierung hr2": "consolidationHR2",
        "konsolidierung hr3": "consolidationHR3",
        "reinduktion ii":     "reinductionII",
        "reinduktion":        "reinductionII",
        "protokoll ii":       "reinductionII",
        "erhaltung":          "maintenance",
        "erhaltungstherapie": "maintenance",
        "maintenance":        "maintenance",
    ]

    /// Layout phrases. The most specific phrase wins; if multiple are
    /// present, "side-by-side"-flavoured wins over "overlay" because
    /// the side-by-side example sentence happens to include both ideas.
    private static let layoutPhrases: [(phrase: String, layout: LabPlotSpec.Layout)] = [
        ("nebeneinander", .sideBySideByParameter),
        ("side by side",  .sideBySideByParameter),
        ("vergleich",     .sideBySideByParameter),
        ("uberlagern",    .overlayWindowsPerParameter),  // überlagern folded
        ("ubereinander",  .overlayWindowsPerParameter),  // übereinander folded
        ("overlay",       .overlayWindowsPerParameter),
    ]

    /// Standalone heuristic entry point so tests don't need to spin up
    /// the actor.
    static func parseHeuristic(question: String) throws -> LabPlotSpec {
        let folded = foldedForMatching(question)

        // 1. Parameters.
        var parameters: [String] = []
        var seen: Set<String> = []
        // Short-hands first (greedy): "Blutbild" should expand before
        // we look at individual codes that might also match.
        for (phrase, expansion) in parameterShorthands where folded.contains(phrase) {
            for code in expansion where !seen.contains(code) {
                seen.insert(code); parameters.append(code)
            }
        }
        // Individual parameter mentions.
        for (phrase, code) in parameterDirect.sorted(by: { $0.key.count > $1.key.count }) {
            // Word-boundary check so "k" alone doesn't match inside "kreatinin".
            if containsAsWord(folded, phrase: phrase), !seen.contains(code) {
                seen.insert(code); parameters.append(code)
            }
        }

        // 2. Windows.
        let windows = parseWindows(folded: folded)

        guard !parameters.isEmpty else { throw LabPlotParserError.noParametersResolved }
        guard !windows.isEmpty     else { throw LabPlotParserError.noWindowsResolved }

        // 3. Layout. Default depends on window count.
        let layout: LabPlotSpec.Layout = detectLayout(folded: folded, windowCount: windows.count)

        // 4. Title — assembled from the recognised pieces. The renderer
        // gets a German one-liner; Gemma path emits a freer title.
        let title = synthesiseTitle(parameters: parameters, windows: windows)

        return LabPlotSpec(
            title: title,
            parameters: parameters,
            windows: windows,
            layout: layout
        )
    }

    /// Find one or more time windows in the folded question.
    /// Order: phase windows first (anchored to a known phase term),
    /// then relative-days windows ("letzte X Tage/Wochen"). Returns up
    /// to two windows — the seed example needs exactly two.
    private static func parseWindows(folded: String) -> [LabPlotSpec.Window] {
        var windows: [LabPlotSpec.Window] = []

        // Detect phase mentions. We walk the synonyms longest-first so
        // "induktion ia" beats "induktion" AND "reinduktion" beats
        // "induktion" (which is a substring of "reinduktion"). Each
        // accepted phrase claims its matched character range; later
        // phrases whose range overlaps an already-claimed one are
        // skipped to avoid double-counting "induktion" inside
        // "reinduktion".
        var claimedRanges: [Range<String.Index>] = []
        var phaseHits: [(matchRange: Range<String.Index>, phase: String)] = []
        for (phrase, phaseRaw) in phaseSynonyms.sorted(by: { $0.key.count > $1.key.count }) {
            guard let range = folded.range(of: phrase) else { continue }
            let overlaps = claimedRanges.contains { $0.overlaps(range) }
            if overlaps { continue }
            claimedRanges.append(range)
            phaseHits.append((range, phaseRaw))
        }

        // For each phase hit, try to extract a day/week window AROUND it.
        for (range, phaseRaw) in phaseHits {
            let context = contextWindow(in: folded, around: range, span: 40)
            if let (from, to) = extractDayRange(context: context) {
                windows.append(.phase(phase: phaseRaw, fromDay: from, toDay: to, label: nil))
                continue
            }
            // No explicit day-range → use the whole phase via typical
            // duration. This handles "Leberwerte überlagern für die
            // Reinduktion" without a window phrase.
            if let phase = Phase(rawValue: phaseRaw) {
                let totalDays = PhaseMetadata.for(phase).typicalDurationDays
                windows.append(.phase(phase: phaseRaw, fromDay: 1, toDay: max(1, totalDays), label: nil))
            }
        }

        // Relative-days windows: "letzte Woche", "letzten Monat", "letzte 14 Tage".
        for match in relativeWindowMatches(in: folded) {
            windows.append(.relativeDays(daysBack: match, label: nil))
        }

        // Dedupe (parser may have surfaced the same window twice via
        // overlapping phrase scans). Preserve order.
        var seen: Set<LabPlotSpec.Window> = []
        var deduped: [LabPlotSpec.Window] = []
        for window in windows where !seen.contains(window) {
            seen.insert(window); deduped.append(window)
        }
        return Array(deduped.prefix(2))
    }

    /// Try to extract a (fromDay, toDay) from a snippet of text around
    /// a phase mention. Supports patterns:
    /// - "erste(n) N tag(e|en)" → 1..N
    /// - "erste(n) N woche(n)"  → 1..N*7
    /// - "woche(n) N(–|-)M"     → (N-1)*7+1 .. M*7
    /// - "tag(e) N(–|-)M"       → N..M
    /// - "letzte N tage/wochen" inside a phase context is treated as
    ///   relative-days at the top level — NOT a phase day range.
    private static func extractDayRange(context: String) -> (Int, Int)? {
        // erste(n)? N tage|wochen
        if let m = match(context, pattern: #"erste[nr]?\s+(\d+|zwei|drei|vier)\s+(tag(en?)?|woche[n]?)"#) {
            let n = parseGermanCount(m[1])
            let unit = m[2]
            let multiplier = unit.hasPrefix("woche") ? 7 : 1
            return (1, n * multiplier)
        }
        // woche(n)? N - M (and N alone)
        if let m = match(context, pattern: #"woche[n]?\s+(\d+)(\s*[-–]\s*(\d+))?"#) {
            let n = Int(m[1]) ?? 1
            let mEnd = (m.count > 3 ? Int(m[3]) : nil) ?? n
            return ((n - 1) * 7 + 1, mEnd * 7)
        }
        // tag(e)? N - M
        if let m = match(context, pattern: #"tag(en?)?\s+(\d+)(\s*[-–]\s*(\d+))?"#) {
            let n = Int(m[2]) ?? 1
            let mEnd = (m.count > 4 ? Int(m[4]) : nil) ?? n
            return (n, mEnd)
        }
        return nil
    }

    /// Find any "letzte N tage|wochen|monat(e)" expressions. Returns
    /// daysBack values (Int).
    private static func relativeWindowMatches(in text: String) -> [Int] {
        var hits: [Int] = []
        // "letzte Woche" / "letzten Monat" — count omitted, default 1
        if match(text, pattern: #"letzte[nr]?\s+woche"#) != nil { hits.append(7) }
        if match(text, pattern: #"letzte[nr]?\s+monat"#) != nil { hits.append(30) }
        if match(text, pattern: #"letzte[nr]?\s+jahr"#) != nil  { hits.append(365) }
        // "letzten N tage|wochen|monat(e)"
        if let m = match(text, pattern: #"letzte[nr]?\s+(\d+|zwei|drei|vier)\s+(tag(en?)?|woche[n]?|monat(en?)?)"#) {
            let n = parseGermanCount(m[1])
            let unit = m[2]
            let multiplier: Int
            if unit.hasPrefix("woche")  { multiplier = 7 }
            else if unit.hasPrefix("monat") { multiplier = 30 }
            else { multiplier = 1 }
            hits.append(n * multiplier)
        }
        return hits
    }

    private static func detectLayout(folded: String, windowCount: Int) -> LabPlotSpec.Layout {
        for (phrase, layout) in layoutPhrases where folded.contains(phrase) {
            return layout
        }
        // Default: two windows → side-by-side; one window → still
        // side-by-side (only one column, but the layout is consistent).
        return .sideBySideByParameter
    }

    /// Build a short German title from the recognised pieces.
    private static func synthesiseTitle(
        parameters: [String],
        windows: [LabPlotSpec.Window]
    ) -> String {
        let paramPart: String = {
            if parameters.count == 4 && Set(parameters) == Set(["WBC", "ANC", "HB", "PLT"]) {
                return "Blutbild"
            }
            if parameters.count == 1 { return parameters[0] }
            return parameters.joined(separator: " / ")
        }()
        let windowParts = windows.map(LabPlotResolver.displayLabel(for:))
        return "\(paramPart): \(windowParts.joined(separator: " vs "))"
    }

    // MARK: - Gemma path (lands in a follow-up chunk)

    private func parseViaGemma(question: String) async throws -> LabPlotSpec {
        let prompt = Self.buildGemmaPrompt(question: question)
        let raw: String
        do {
            raw = try await gemma.generate(
                prompt: prompt,
                parameters: GenerateParameters(maxTokens: 512, temperature: 0.2),
                enableThinking: false,
                surface: "labplot"
            )
        } catch {
            throw LabPlotParserError.gemmaError(error.localizedDescription)
        }
        return try Self.parseGemmaJSON(raw)
    }

    static func parseGemmaJSON(_ raw: String) throws -> LabPlotSpec {
        guard let jsonString = ExtractionService.firstJSONObject(in: raw) else {
            throw LabPlotParserError.gemmaReturnedNoJSON
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw LabPlotParserError.gemmaReturnedInvalidJSON("UTF-8 encoding failed")
        }
        do {
            return try JSONDecoder.extraction.decode(LabPlotSpec.self, from: data)
        } catch {
            throw LabPlotParserError.gemmaReturnedInvalidJSON(error.localizedDescription)
        }
    }

    static func buildGemmaPrompt(question: String) -> String {
        """
        You translate a parent's German question into a lab-plot spec as JSON.

        Rules:
        - JSON only. No explanation, no markdown fences.
        - Never invent values. The German title is short and parent-readable.
        - parameters: list of canonical codes from {WBC, ANC, HB, PLT, RBC, HCT, MCV, CRP, LDH, ALT, AST, GGT, Bili, Krea, Na, K, Ca, Mg}. For "Blutbild"/"CBC" use [WBC, ANC, HB, PLT].
        - windows: 1 or 2 entries.
          - phase window: {"kind":"phase","phase":"<rawValue>","fromDay":<int>,"toDay":<int>,"label":"<German label>"}
            phase rawValues: inductionIA, inductionIB, consolidationM, consolidationHR1, consolidationHR2, consolidationHR3, reinductionII, maintenance.
          - relative window: {"kind":"relativeDays","daysBack":<int>,"label":"<German label>"}
          - absolute window (rare): {"kind":"absolute","from":"YYYY-MM-DDT00:00:00Z","to":"YYYY-MM-DDT00:00:00Z","label":"<German label>"}
        - layout: "sideBySideByParameter" (default for 2 windows) or "overlayWindowsPerParameter".

        Schema:
        {"title":"<short German title>","parameters":["..."],"windows":[{"kind":"...","...":"..."}],"layout":"sideBySideByParameter"}

        Question (German): \(question)

        JSON:
        """
    }

    // MARK: - Text utilities

    /// Lowercase + diacritic-fold for matching. Mirrors
    /// `RefusalService.foldedForMatching` / `EventQuestionDetector`.
    private static func foldedForMatching(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "de"))
            .replacingOccurrences(of: "ß", with: "ss")
    }

    /// Whole-word substring check. Used for the short-code dictionary
    /// so "k" doesn't match inside "kreatinin".
    private static func containsAsWord(_ haystack: String, phrase: String) -> Bool {
        let pattern = "(^|\\W)\(NSRegularExpression.escapedPattern(for: phrase))(\\W|$)"
        return haystack.range(of: pattern, options: .regularExpression) != nil
    }

    /// A snippet of `text` of up to `span` characters before AND after
    /// `range`. Used to scope day-range extraction to the vicinity of a
    /// phase mention.
    private static func contextWindow(
        in text: String,
        around range: Range<String.Index>,
        span: Int
    ) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -span, limitedBy: text.startIndex)
            ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: span, limitedBy: text.endIndex)
            ?? text.endIndex
        return String(text[lower..<upper])
    }

    /// Run an NSRegularExpression and return the matched groups as
    /// strings. Returns nil when there's no match. Group 0 is the full
    /// match; groups 1..n are the captures.
    private static func match(_ text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<match.numberOfRanges {
            let r = match.range(at: i)
            if r.location == NSNotFound, let _ = Range(r, in: text) {
                groups.append("")
            } else if let swiftRange = Range(r, in: text) {
                groups.append(String(text[swiftRange]))
            } else {
                groups.append("")
            }
        }
        return groups
    }

    /// Parse a German numeric count: digits or the small spelled-out
    /// numbers we need to recognise in the heuristic ("zwei" → 2).
    private static func parseGermanCount(_ s: String) -> Int {
        if let n = Int(s) { return n }
        switch s.lowercased() {
        case "zwei": return 2
        case "drei": return 3
        case "vier": return 4
        case "fünf", "funf": return 5
        case "sechs": return 6
        case "sieben": return 7
        default: return 1
        }
    }
}
