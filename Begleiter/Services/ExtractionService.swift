import Foundation
import MLXLMCommon
import OSLog

private let extractionLog = Logger(subsystem: "io.grimso.Begleiter", category: "gemma.extraction")

/// Per-call generation parameters for the extraction path.
/// - maxTokens: read from `AppSettings.extractionMaxTokens` (default 2500).
///   Real Befund PDFs run 15–25 lab values; combined with drugs /
///   observations / summary, full output exceeds 1500 tokens. 2500 gives
///   comfortable margin even for chemistry + CBC + coag panels. The
///   Settings screen lets users dial this between 512 and 4096.
/// - temperature: 0.3 — structured extraction wants deterministic output.
///   Not user-configurable; exposing it would risk parents accidentally
///   breaking the JSON-only contract Gemma honours at low temperature.
private func extractionParameters() -> GenerateParameters {
    GenerateParameters(maxTokens: AppSettings.extractionMaxTokens, temperature: 0.3)
}

/// Outcome of an extraction attempt: parsed structured fields plus the raw
/// string Gemma emitted (verbatim, with markdown fences if present), plus
/// which attempt won. Callers persist the raw response on the JournalEntry
/// so we can re-parse it later or use it as training data.
nonisolated struct ExtractionResult: Sendable {
    let fields: ExtractedFields
    let rawResponse: String
    let attempt: Int  // 1 = strict-mode-off, 2 = strict-mode-on retry
}

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
    private let visionGemma: GemmaVisionService

    /// Defaults to the app-wide shared services so we never load two
    /// copies of the model. The text and vision services are mutually
    /// exclusive in memory — see ``GemmaVisionService.loadModel`` and
    /// the symmetric call in ``GemmaService.loadModel``.
    init(
        gemma: GemmaService = .shared,
        visionGemma: GemmaVisionService = .shared
    ) {
        self.gemma = gemma
        self.visionGemma = visionGemma
    }

    /// Pass-through to both underlying services so the memory-warning
    /// handler can drop whichever model is currently resident.
    func unloadModel() async {
        await gemma.unload()
        await visionGemma.unload()
    }

    /// Extract structured fields from a German text journal entry.
    ///
    /// - Parameters:
    ///   - text: parent's raw German text. May be empty if the entry is
    ///     attachment-only (a Befund PDF with no typed prose).
    ///   - phase: current treatment phase (from `ChildState`).
    ///   - dayInPhase: day number within the phase.
    ///   - visitDate: the date the entry refers to.
    ///   - ocrText: OCR / PDFKit text from any Befund photos or PDFs
    ///     attached to this entry. Passed as a separate context block in
    ///     the prompt so Gemma is explicitly instructed to extract lab
    ///     values from a clinical printout, rather than treating it as
    ///     more "parent prose".
    /// - Returns: `ExtractionResult` carrying both parsed fields and the raw
    ///   Gemma response (the latter is persisted on the JournalEntry for
    ///   future re-parsing, A/B comparison, and LoRA training data).
    /// - Throws: `ExtractionError` if both attempts fail to yield usable
    ///   JSON.
    func extract(
        text: String,
        phase: Phase,
        dayInPhase: Int,
        visitDate: Date,
        ocrText: String? = nil,
        imageURLs: [URL] = []
    ) async throws -> ExtractionResult {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOCR = ocrText?.trimmingCharacters(in: .whitespacesAndNewlines)
        // At least one input source must be non-empty. Images alone are
        // a valid source in `.directMultimodal` mode (parent attaches a
        // Befund photo without typing anything).
        if trimmedText.isEmpty
            && (trimmedOCR?.isEmpty ?? true)
            && imageURLs.isEmpty {
            throw ExtractionError.emptyInput
        }

        // Lab-pipeline mode switch. The toggle lives in
        // `AppSettings.labPipelineMode` (Settings → Befund-Verarbeitung).
        // `.directMultimodal` engages only when we actually have image
        // URLs to pass in — if the user flipped the toggle but the
        // current entry is text-only, the text path is the right fallback.
        let mode = AppSettings.labPipelineMode
        let useVisionPath = (mode == .directMultimodal) && !imageURLs.isEmpty
        if mode == .directMultimodal && imageURLs.isEmpty {
            extractionLog.info("mode=directMultimodal but no images on entry; using text-only path")
        }

        if useVisionPath {
            return try await extractWithVision(
                text: trimmedText,
                phase: phase,
                dayInPhase: dayInPhase,
                visitDate: visitDate,
                imageURLs: imageURLs
            )
        }

        let prompt = Self.buildPrompt(
            text: trimmedText,
            ocrText: trimmedOCR,
            phase: phase,
            dayInPhase: dayInPhase,
            visitDate: visitDate,
            strictMode: false
        )

        extractionLog.info("extract: text=\(trimmedText.count, privacy: .public) chars, ocrText=\(trimmedOCR?.count ?? 0, privacy: .public) chars")

        let raw1 = try await gemma.generate(prompt: prompt, parameters: extractionParameters())
        extractionLog.debug("attempt=1 raw=\(raw1, privacy: .public)")
        if let fields = try? Self.parseExtractedFields(from: raw1) {
            let labCount = fields.labValues?.value.count ?? 0
            extractionLog.info("attempt=1 parsed OK, labs=\(labCount, privacy: .public)")
            return ExtractionResult(fields: fields, rawResponse: raw1, attempt: 1)
        }

        extractionLog.warning("attempt=1 parse failed, retrying in strict mode")
        let retryPrompt = Self.buildPrompt(
            text: trimmedText,
            ocrText: trimmedOCR,
            phase: phase,
            dayInPhase: dayInPhase,
            visitDate: visitDate,
            strictMode: true
        )
        let raw2 = try await gemma.generate(prompt: retryPrompt, parameters: extractionParameters())
        extractionLog.debug("attempt=2 raw=\(raw2, privacy: .public)")
        let fields = try Self.parseExtractedFields(from: raw2)
        let labCount = fields.labValues?.value.count ?? 0
        extractionLog.info("attempt=2 parsed OK, labs=\(labCount, privacy: .public)")
        return ExtractionResult(fields: fields, rawResponse: raw2, attempt: 2)
    }

    /// `.directMultimodal` extraction path. Feeds the Befund image(s)
    /// straight to Gemma 4 via the multimodal sibling service instead
    /// of pre-OCR-ing them. Mirrors the text path's two-attempt retry
    /// (loose → strict) so failure modes match what the rest of the
    /// app already understands.
    ///
    /// Returns the same `ExtractionResult` contract as the text path,
    /// so callers (queue, view models) need not branch on mode.
    private func extractWithVision(
        text: String,
        phase: Phase,
        dayInPhase: Int,
        visitDate: Date,
        imageURLs: [URL]
    ) async throws -> ExtractionResult {
        extractionLog.info(
            "extractWithVision: text=\(text.count, privacy: .public) chars, images=\(imageURLs.count, privacy: .public)"
        )

        let prompt1 = Self.buildVisionPrompt(
            text: text,
            phase: phase,
            dayInPhase: dayInPhase,
            visitDate: visitDate,
            imageCount: imageURLs.count,
            strictMode: false
        )
        let raw1 = try await visionGemma.generate(
            prompt: prompt1,
            imageURLs: imageURLs,
            parameters: extractionParameters()
        )
        extractionLog.debug("vision.attempt=1 raw=\(raw1, privacy: .public)")
        if let fields = try? Self.parseExtractedFields(from: raw1) {
            let labCount = fields.labValues?.value.count ?? 0
            extractionLog.info("vision.attempt=1 parsed OK, labs=\(labCount, privacy: .public)")
            return ExtractionResult(fields: fields, rawResponse: raw1, attempt: 1)
        }

        extractionLog.warning("vision.attempt=1 parse failed, retrying in strict mode")
        let prompt2 = Self.buildVisionPrompt(
            text: text,
            phase: phase,
            dayInPhase: dayInPhase,
            visitDate: visitDate,
            imageCount: imageURLs.count,
            strictMode: true
        )
        let raw2 = try await visionGemma.generate(
            prompt: prompt2,
            imageURLs: imageURLs,
            parameters: extractionParameters()
        )
        extractionLog.debug("vision.attempt=2 raw=\(raw2, privacy: .public)")
        let fields = try Self.parseExtractedFields(from: raw2)
        let labCount = fields.labValues?.value.count ?? 0
        extractionLog.info("vision.attempt=2 parsed OK, labs=\(labCount, privacy: .public)")
        return ExtractionResult(fields: fields, rawResponse: raw2, attempt: 2)
    }

    // MARK: - Prompt construction

    /// Constructs the full prompt sent to Gemma. Pure function for testability.
    static func buildPrompt(
        text: String,
        ocrText: String? = nil,
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

        // Optional Befund block — only included when OCR text is present.
        // The lab-extraction rule is conditional on this block existing,
        // so absent input doesn't force Gemma to invent lab values.
        let befundBlock: String
        let labRule: String
        if let ocrText, !ocrText.isEmpty {
            befundBlock = """


                BEFUND-INHALT (automatisch aus einem Foto oder PDF erkannt):
                ```
                \(ocrText)
                ```
                """
            labRule = "- Wenn der BEFUND-INHALT Laborwerte enthält, extrahieren Sie ALLE eindeutig erkennbaren Werte in `labValues` (Parameter, Wert, Einheit). Mehrere Werte sind die Regel, nicht die Ausnahme."
        } else {
            befundBlock = ""
            labRule = "- Erfassen Sie nur Laborwerte, die im Text der Eltern explizit genannt werden."
        }

        return """
        Sie sind ein medizinischer Tagebuch-Assistent für Eltern eines Kindes in der AIEOP-BFM ALL 2017 Behandlung. Ihre einzige Aufgabe ist es, den freien Text der Eltern in strukturierte Felder zu überführen.

        \(header)

        REGELN:
        - Erfinden Sie NIEMALS Werte, die nicht in den Eingaben stehen. Wenn etwas nicht erwähnt wird, **lassen Sie das ganze Feld komplett weg**. NIEMALS "value": null oder "value": [] verwenden — einfach das Feld nicht in das JSON aufnehmen.
        - Jedes Feld MUSS beide Schlüssel haben: "value" und "confidence" (eine Zahl zwischen 0.0 und 1.0).
        - Konfidenz-Skala: 1.0 = explizit genannt, 0.5 = wahrscheinlich aber unsicher, < 0.3 = sehr unsicher.
        - Geben Sie KEINE medizinischen Einschätzungen, Empfehlungen oder Diagnosen ab. Sie strukturieren nur, was die Eltern gesagt oder als Befund hochgeladen haben.
        - Schreiben Sie Eigennamen und medizinische Begriffe genau so wie im Originaltext (z.B. "Vincristin", nicht "Vindchristin"; "Notaufnahme", nicht "Botaufnahme").
        \(labRule)

        KONTEXT (zur Plausibilitätsprüfung, NICHT ins JSON kopieren):
        - Aktuelle Phase: \(phaseLabel)
        - Tag in dieser Phase: \(dayInPhase)
        - Datum des Eintrags: \(dateString)

        SCHEMA (alle Felder optional — weglassen wenn nicht erwähnt):
        {
          "visitType": { "value": "ambulant" | "stationaer" | "notfall" | "telefonisch" | "zuhause", "confidence": 0.0-1.0 },
          "doctorName": { "value": "<Name>", "confidence": 0.0-1.0 },
          "drugsMentioned": { "value": [{ "name": "<INN>", "germanLabel": "<wie genannt>", "doseDescription": "<frei>", "administeredAt": null }], "confidence": 0.0-1.0 },
          "labValues": { "value": [{ "parameter": "<beliebiger Laborparameter, z.B. WBC, RBC, ANC, Hb, HGB, HCT, PLT, MCV, MCH, MCHC, CRP, ALT, AST, Quick, INR, Na, K, Ca, Glucose, ...>", "germanLabel": "<dt. Bezeichnung oder gleich wie parameter>", "value": <Zahl>, "unit": "<Einheit>", "measuredAt": "\(dateString)", "source": "text" }], "confidence": 0.0-1.0 },
          "proceduresMentioned": { "value": ["<Prozedur 1>", "..."], "confidence": 0.0-1.0 },
          "decisions": { "value": ["<Entscheidung des Teams 1>", "..."], "confidence": 0.0-1.0 },
          "parentObservations": { "value": ["<Beobachtung der Eltern 1>", "..."], "confidence": 0.0-1.0 },
          "openQuestions": { "value": ["<offene Frage 1>", "..."], "confidence": 0.0-1.0 },
          "reactions": { "value": [{ "description": "<frei>", "suspectedCause": "<Medikament/Prozedur oder null>", "parentSeverity": "leicht" | "mittel" | "schwer" | null, "occurredAt": null }], "confidence": 0.0-1.0 },
          "summary": { "value": "<ein Satz auf Deutsch>", "confidence": 0.0-1.0 }
        }

        TEXT DER ELTERN:
        \(text.isEmpty ? "(kein eigener Text — Befund liegt unten bei)" : text)\(befundBlock)

        JSON:
        """
    }

    /// Prompt for the `.directMultimodal` path. Same JSON contract as
    /// the text path but the Befund context comes from an attached
    /// image (or images) rather than a pre-extracted OCR block.
    ///
    /// We do NOT inline the image inside the prompt string — mlx-swift's
    /// `ChatSession.respond(to:images:)` attaches the image(s) to the
    /// user turn via the model's chat template (`Gemma4MessageGenerator`
    /// emits `{"type": "image"}` content parts). The prompt's job is to
    /// (a) restate the schema and rules, and (b) tell the model to
    /// consult the attached image(s) for lab values.
    static func buildVisionPrompt(
        text: String,
        phase: Phase,
        dayInPhase: Int,
        visitDate: Date,
        imageCount: Int,
        strictMode: Bool
    ) -> String {
        let dateString = Self.dateFormatter.string(from: visitDate)
        let phaseLabel = phase.germanLabel

        let header = strictMode
            ? "WICHTIG: Antworten Sie AUSSCHLIESSLICH mit gültigem JSON. Kein Markdown, kein Text vor oder nach dem JSON, keine Erklärungen. Beginnen Sie direkt mit { und enden Sie mit }."
            : "Antworten Sie ausschließlich mit JSON nach dem unten gezeigten Schema."

        let imagePhrase = imageCount == 1
            ? "ein Befund-Foto"
            : "\(imageCount) Befund-Fotos"

        return """
        Sie sind ein medizinischer Tagebuch-Assistent für Eltern eines Kindes in der AIEOP-BFM ALL 2017 Behandlung. Ihre einzige Aufgabe ist es, den freien Text der Eltern UND den/die angehängten Befund \(imageCount == 1 ? "" : "e") in strukturierte Felder zu überführen.

        \(header)

        REGELN:
        - Im Anhang dieses Eintrags ist \(imagePhrase). Lesen Sie ALLE eindeutig erkennbaren Laborwerte direkt aus dem Bild ab (Parameter, Wert, Einheit). Mehrere Werte sind die Regel, nicht die Ausnahme.
        - Erfinden Sie NIEMALS Werte. Wenn ein Wert im Bild unleserlich ist, **lassen Sie das Feld komplett weg**. NIEMALS "value": null oder "value": [] verwenden — einfach das Feld nicht in das JSON aufnehmen.
        - Jedes Feld MUSS beide Schlüssel haben: "value" und "confidence" (eine Zahl zwischen 0.0 und 1.0).
        - Konfidenz-Skala: 1.0 = explizit und klar lesbar, 0.5 = wahrscheinlich aber unsicher (z.B. teilweise verdeckt), < 0.3 = sehr unsicher (z.B. handschriftlich, verwackelt).
        - Geben Sie KEINE medizinischen Einschätzungen, Empfehlungen oder Diagnosen ab. Sie strukturieren nur, was im Bild steht oder die Eltern gesagt haben.
        - Schreiben Sie Eigennamen und medizinische Begriffe genau so wie im Befund (z.B. "Vincristin", "Methotrexat", "Hb", "ANC").

        KONTEXT (zur Plausibilitätsprüfung, NICHT ins JSON kopieren):
        - Aktuelle Phase: \(phaseLabel)
        - Tag in dieser Phase: \(dayInPhase)
        - Datum des Eintrags: \(dateString)

        SCHEMA (alle Felder optional — weglassen wenn nicht erwähnt):
        {
          "visitType": { "value": "ambulant" | "stationaer" | "notfall" | "telefonisch" | "zuhause", "confidence": 0.0-1.0 },
          "doctorName": { "value": "<Name>", "confidence": 0.0-1.0 },
          "drugsMentioned": { "value": [{ "name": "<INN>", "germanLabel": "<wie genannt>", "doseDescription": "<frei>", "administeredAt": null }], "confidence": 0.0-1.0 },
          "labValues": { "value": [{ "parameter": "<WBC, RBC, ANC, Hb, HGB, HCT, PLT, MCV, MCH, MCHC, CRP, ALT, AST, Quick, INR, Na, K, Ca, Glucose, ...>", "germanLabel": "<dt. Bezeichnung oder gleich wie parameter>", "value": <Zahl>, "unit": "<Einheit>", "measuredAt": "\(dateString)", "source": "befund_photo" }], "confidence": 0.0-1.0 },
          "proceduresMentioned": { "value": ["<Prozedur 1>", "..."], "confidence": 0.0-1.0 },
          "decisions": { "value": ["<Entscheidung des Teams 1>", "..."], "confidence": 0.0-1.0 },
          "parentObservations": { "value": ["<Beobachtung der Eltern 1>", "..."], "confidence": 0.0-1.0 },
          "openQuestions": { "value": ["<offene Frage 1>", "..."], "confidence": 0.0-1.0 },
          "reactions": { "value": [{ "description": "<frei>", "suspectedCause": "<Medikament/Prozedur oder null>", "parentSeverity": "leicht" | "mittel" | "schwer" | null, "occurredAt": null }], "confidence": 0.0-1.0 },
          "summary": { "value": "<ein Satz auf Deutsch>", "confidence": 0.0-1.0 }
        }

        TEXT DER ELTERN:
        \(text.isEmpty ? "(kein eigener Text — siehe angehängtes Befund-Bild)" : text)

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
