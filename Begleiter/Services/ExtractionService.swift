import Foundation

/// Errors surfaced by `ExtractionService` when extraction cannot proceed.
enum ExtractionError: Error, LocalizedError {
    case emptyInput
    case modelReturnedNoJSON
    case modelReturnedInvalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Der Text ist leer."
        case .modelReturnedNoJSON:
            return "Gemma hat keinen JSON-Block geliefert."
        case .modelReturnedInvalidJSON(let detail):
            return "Gemma hat ungültiges JSON geliefert: \(detail)"
        }
    }
}

/// Turns a German free-text journal entry into structured `ExtractedFields`
/// using Gemma 4 via `GemmaService`.
///
/// Strategy is intentionally simple in iteration 3:
/// 1. Build a system prompt that contains (a) the JSON schema the model
///    must emit, (b) explicit "facts not in the text → null" rules, and
///    (c) current phase context so the model can sanity-check what it
///    extracts.
/// 2. Ask Gemma for the entry. Parse the response as JSON.
/// 3. On parse failure, retry once with a stricter "ONLY JSON, no prose"
///    instruction. On second failure, return the parse error.
///
/// Function calling and tool dispatch are deferred to iteration 6 (briefing
/// generator). Direct prompting is sufficient and more reliable for
/// extraction because we always want structured output — we're never
/// asking the model to decide "should I call a tool?".
actor ExtractionService {

    /// App-wide shared instance. Memory-pressure handler in `BegleiterApp`
    /// targets this so the cached Gemma weights can be released on iOS
    /// memory warnings without the handler needing a reference to each
    /// CaptureViewModel.
    static let shared = ExtractionService()

    private let gemma: GemmaService

    /// Default to a smaller max-token cap than GemmaService's default (256).
    /// Extraction outputs are JSON — typically <120 tokens for a normal
    /// entry. The tighter cap trims KV-cache headroom, giving us more
    /// margin under iPhone 14 Pro's per-app limit. Temperature is also
    /// reduced because structured extraction wants deterministic output.
    init(gemma: GemmaService = GemmaService(maxTokens: 128, temperature: 0.3)) {
        self.gemma = gemma
    }

    /// Pass-through to the underlying GemmaService so the memory-warning
    /// handler can drop the model.
    func unloadModel() async {
        await gemma.unload()
    }

    /// Extract structured fields from a German text journal entry.
    ///
    /// - Parameters:
    ///   - text: parent's raw German text. Trimmed.
    ///   - phase: current treatment phase (from `ChildState`).
    ///   - dayInPhase: day number within the phase.
    ///   - visitDate: the date the entry refers to.
    /// - Returns: parsed `ExtractedFields`.
    /// - Throws: `ExtractionError` if no usable JSON could be obtained.
    func extract(
        text: String,
        phase: Phase,
        dayInPhase: Int,
        visitDate: Date
    ) async throws -> ExtractedFields {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExtractionError.emptyInput }

        let prompt = Self.buildPrompt(
            text: trimmed,
            phase: phase,
            dayInPhase: dayInPhase,
            visitDate: visitDate,
            strictMode: false
        )

        do {
            let raw = try await gemma.generate(prompt: prompt)
            return try Self.parseExtractedFields(from: raw)
        } catch {
            // Retry once with stricter instructions.
            let retryPrompt = Self.buildPrompt(
                text: trimmed,
                phase: phase,
                dayInPhase: dayInPhase,
                visitDate: visitDate,
                strictMode: true
            )
            let raw = try await gemma.generate(prompt: retryPrompt)
            return try Self.parseExtractedFields(from: raw)
        }
    }

    // MARK: - Prompt construction

    /// Constructs the full prompt sent to Gemma. Pure function for testability.
    static func buildPrompt(
        text: String,
        phase: Phase,
        dayInPhase: Int,
        visitDate: Date,
        strictMode: Bool
    ) -> String {
        let dateString = Self.dateFormatter.string(from: visitDate)
        let phaseLabel = phase.germanLabel

        let header = strictMode
            ? "WICHTIG: Antworten Sie AUSSCHLIESSLICH mit gültigem JSON. Kein Markdown, kein Text vor oder nach dem JSON, keine Erklärungen. Beginnen Sie direkt mit { und enden Sie mit }."
            : "Antworten Sie ausschließlich mit JSON nach dem unten gezeigten Schema."

        return """
        Sie sind ein medizinischer Tagebuch-Assistent für Eltern eines Kindes in der AIEOP-BFM ALL 2017 Behandlung. Ihre einzige Aufgabe ist es, den freien Text der Eltern in strukturierte Felder zu überführen.

        \(header)

        REGELN:
        - Erfinden Sie NIEMALS Werte, die nicht im Text stehen. Wenn etwas nicht erwähnt wird, lassen Sie das Feld weg oder setzen Sie es auf null.
        - Geben Sie für jedes ausgefüllte Feld eine Konfidenz zwischen 0.0 und 1.0 an: 1.0 = explizit im Text genannt, 0.5 = wahrscheinlich aber unsicher, < 0.3 = sehr unsicher.
        - Geben Sie KEINE medizinischen Einschätzungen, Empfehlungen oder Diagnosen ab. Sie strukturieren nur, was die Eltern gesagt haben.

        KONTEXT (zur Plausibilitätsprüfung, NICHT ins JSON kopieren):
        - Aktuelle Phase: \(phaseLabel)
        - Tag in dieser Phase: \(dayInPhase)
        - Datum des Eintrags: \(dateString)

        SCHEMA (alle Felder optional — weglassen wenn nicht erwähnt):
        {
          "visitType": { "value": "ambulant" | "stationaer" | "notfall" | "telefonisch" | "zuhause", "confidence": 0.0-1.0 },
          "doctorName": { "value": "<Name>", "confidence": 0.0-1.0 },
          "drugsMentioned": { "value": [{ "name": "<INN>", "germanLabel": "<wie genannt>", "doseDescription": "<frei>", "administeredAt": null }], "confidence": 0.0-1.0 },
          "labValues": { "value": [{ "parameter": "<WBC|ANC|Hb|PLT|...>", "germanLabel": "<dt. Bezeichnung>", "value": <Zahl>, "unit": "<Einheit>", "referenceMin": null, "referenceMax": null, "measuredAt": "\(dateString)", "source": "text" }], "confidence": 0.0-1.0 },
          "proceduresMentioned": { "value": ["<Prozedur 1>", "..."], "confidence": 0.0-1.0 },
          "decisions": { "value": ["<Entscheidung des Teams 1>", "..."], "confidence": 0.0-1.0 },
          "parentObservations": { "value": ["<Beobachtung der Eltern 1>", "..."], "confidence": 0.0-1.0 },
          "openQuestions": { "value": ["<offene Frage 1>", "..."], "confidence": 0.0-1.0 },
          "reactions": { "value": [{ "description": "<frei>", "suspectedCause": "<Medikament/Prozedur oder null>", "parentSeverity": "leicht" | "mittel" | "schwer" | null, "occurredAt": null }], "confidence": 0.0-1.0 },
          "summary": { "value": "<ein Satz auf Deutsch>", "confidence": 0.0-1.0 }
        }

        TEXT DER ELTERN:
        \(text)

        JSON:
        """
    }

    // MARK: - JSON parsing

    /// Extracts the first balanced `{ ... }` block from `raw` and decodes it
    /// as `ExtractedFields`. Tolerates surrounding prose / markdown fences.
    static func parseExtractedFields(from raw: String) throws -> ExtractedFields {
        guard let jsonString = firstJSONObject(in: raw) else {
            throw ExtractionError.modelReturnedNoJSON
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw ExtractionError.modelReturnedInvalidJSON("UTF-8 encoding failed")
        }
        do {
            return try JSONDecoder.extraction.decode(ExtractedFields.self, from: data)
        } catch {
            throw ExtractionError.modelReturnedInvalidJSON(error.localizedDescription)
        }
    }

    /// Find the first top-level balanced `{...}` block in a string. Handles
    /// markdown code fences and prose before/after. Returns `nil` if no
    /// balanced object is found.
    static func firstJSONObject(in raw: String) -> String? {
        let stripped = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")

        guard let startIdx = stripped.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escape = false
        var endIdx: String.Index?

        for idx in stripped[startIdx...].indices {
            let ch = stripped[idx]
            if escape { escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    endIdx = idx
                    break
                }
            }
        }
        guard let endIdx else { return nil }
        return String(stripped[startIdx...endIdx])
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "de_DE")
        return formatter
    }()
}
