import Foundation

/// Canonicalises raw lab-parameter strings into the project's short
/// codes (`WBC`, `ANC`, `HB`, `PLT`, `CRP`, …).
///
/// Two callers consume this:
/// - ``LabPlotParser`` for the natural-language plot composer.
/// - ``AgentTools/handleGetLabTrend`` so the function-calling agent
///   matches stored lab values when the model passes a synonym like
///   `"Hemoglobin"` or `"Leukozyten"`.
///
/// Lookup is case- and diacritic-insensitive (`Hämoglobin` → `HB`,
/// `LEUKOZYTEN` → `WBC`). Inputs not in the table are returned in their
/// uppercased / trimmed form so unknown parameters still survive the
/// pipeline — the calling site decides whether an unrecognised code is a
/// hard error or a passthrough.
enum LabParameterCanonicalizer {

    /// Synonym → canonical short code. Keys are lowercased and
    /// diacritic-folded (see ``fold(_:)``). Values are the canonical
    /// short codes used elsewhere in the app.
    static let synonyms: [String: String] = [
        "wbc": "WBC", "leukos": "WBC", "leukozyten": "WBC", "leukocytes": "WBC",
        "anc": "ANC", "neutros": "ANC", "neutrophile": "ANC", "neutrophils": "ANC",
        "hb": "HB",   "hgb": "HB", "hamoglobin": "HB", "hemoglobin": "HB", "haemoglobin": "HB",
        "plt": "PLT", "thrombos": "PLT", "thrombozyten": "PLT", "platelets": "PLT",
        "crp": "CRP",
        "ldh": "LDH",
        "alt": "ALT", "gpt": "ALT",
        "ast": "AST", "got": "AST",
        "ggt": "GGT",
        "bili": "Bili", "bilirubin": "Bili",
        "krea": "Krea", "kreatinin": "Krea", "creatinine": "Krea",
        "na":  "Na",  "natrium": "Na", "sodium": "Na",
        "k":   "K",   "kalium":  "K",  "potassium": "K",
    ]

    /// Look up the canonical short code for `parameter`. Returns the
    /// uppercased trimmed input when nothing matches, so the caller
    /// always gets a usable string to render or compare.
    static func canonical(for parameter: String) -> String {
        let folded = fold(parameter)
        if let hit = synonyms[folded] { return hit }
        return parameter
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    /// Two parameter strings are considered the same series if they
    /// fold to the same canonical code. Convenience for the agent's
    /// lab-trend lookup.
    static func matches(_ stored: String, query: String) -> Bool {
        canonical(for: stored) == canonical(for: query)
    }

    /// Lowercase + diacritic-fold for matching. Mirrors the previous
    /// in-line helpers in ``LabPlotParser`` and ``RefusalService``.
    static func fold(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "de"))
            .replacingOccurrences(of: "ß", with: "ss")
    }
}
