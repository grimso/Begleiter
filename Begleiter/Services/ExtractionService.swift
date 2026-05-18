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

        let raw1 = try await gemma.generate(
            prompt: prompt,
            parameters: extractionParameters(),
            surface: "extract.text"
        )
        extractionLog.debug("attempt=1 raw=\(raw1, privacy: .private)")
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
        let raw2 = try await gemma.generate(
            prompt: retryPrompt,
            parameters: extractionParameters(),
            surface: "extract.text.retry"
        )
        extractionLog.debug("attempt=2 raw=\(raw2, privacy: .private)")
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

        let prompt1 = Self.buildVisionPrompt(strictMode: false)
        let raw1 = try await visionGemma.generate(
            prompt: prompt1,
            imageURLs: imageURLs,
            parameters: extractionParameters(),
            surface: "extract.vision"
        )
        extractionLog.debug("vision.attempt=1 raw=\(raw1, privacy: .private)")
        if let fields = try? Self.parseVisionFields(from: raw1, visitDate: visitDate) {
            let labCount = fields.labValues?.value.count ?? 0
            extractionLog.info("vision.attempt=1 parsed OK, labs=\(labCount, privacy: .public)")
            return ExtractionResult(fields: fields, rawResponse: raw1, attempt: 1)
        }

        extractionLog.warning("vision.attempt=1 parse failed, retrying in strict mode")
        let prompt2 = Self.buildVisionPrompt(strictMode: true)
        let raw2 = try await visionGemma.generate(
            prompt: prompt2,
            imageURLs: imageURLs,
            parameters: extractionParameters(),
            surface: "extract.vision.retry"
        )
        extractionLog.debug("vision.attempt=2 raw=\(raw2, privacy: .private)")
        let fields = try Self.parseVisionFields(from: raw2, visitDate: visitDate)
        let labCount = fields.labValues?.value.count ?? 0
        extractionLog.info("vision.attempt=2 parsed OK, labs=\(labCount, privacy: .public)")
        return ExtractionResult(fields: fields, rawResponse: raw2, attempt: 2)
    }

    /// Focused CBC extraction against OCR'd Sysmex text. Bypasses the
    /// omnibus 10-field prompt — produces only `labValues`. Used by the
    /// "Befund auslesen" capture shortcut: the user picks a Befund photo,
    /// Apple Vision OCRs it, and this method asks Gemma 4 to map the OCR
    /// text into a `blood_count` JSON array.
    ///
    /// Same two-attempt retry as the other paths (loose → strict). The
    /// vision-side parser (`parseVisionFields`) handles the shared
    /// `blood_count` schema and stamps each entry with `visitDate` +
    /// `source = .befundPhoto`.
    func extractLabValuesOnly(
        ocrText: String,
        visitDate: Date
    ) async throws -> ExtractionResult {
        let trimmed = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExtractionError.emptyInput }

        extractionLog.info("extractLabValuesOnly: ocrText=\(trimmed.count, privacy: .public) chars")

        let prompt1 = Self.buildLabsOnlyPrompt(ocrText: trimmed, strictMode: false)
        let raw1 = try await gemma.generate(
            prompt: prompt1,
            parameters: extractionParameters(),
            surface: "extract.labsOnly"
        )
        extractionLog.debug("labsOnly.attempt=1 raw=\(raw1, privacy: .private)")
        if let fields = try? Self.parseVisionFields(from: raw1, visitDate: visitDate) {
            let labCount = fields.labValues?.value.count ?? 0
            extractionLog.info("labsOnly.attempt=1 parsed OK, labs=\(labCount, privacy: .public)")
            return ExtractionResult(fields: fields, rawResponse: raw1, attempt: 1)
        }

        extractionLog.warning("labsOnly.attempt=1 parse failed, retrying in strict mode")
        let prompt2 = Self.buildLabsOnlyPrompt(ocrText: trimmed, strictMode: true)
        let raw2 = try await gemma.generate(
            prompt: prompt2,
            parameters: extractionParameters(),
            surface: "extract.labsOnly.retry"
        )
        extractionLog.debug("labsOnly.attempt=2 raw=\(raw2, privacy: .private)")
        let fields = try Self.parseVisionFields(from: raw2, visitDate: visitDate)
        let labCount = fields.labValues?.value.count ?? 0
        extractionLog.info("labsOnly.attempt=2 parsed OK, labs=\(labCount, privacy: .public)")
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
            ? "Strict mode: respond with valid JSON only. No markdown, no prose. Start with { and end with }."
            : "Return JSON only, following the schema below."

        // Optional Befund block — only included when OCR text is present.
        // The lab-extraction rule is conditional on this block existing,
        // so absent input doesn't force Gemma to invent lab values.
        let befundBlock: String
        let labRule: String
        if let ocrText, !ocrText.isEmpty {
            befundBlock = """


                BEFUND (OCR / PDF text):
                ```
                \(ocrText)
                ```
                """
            labRule = "- If the BEFUND block contains lab values, extract ALL clearly readable values into `labValues` (parameter, value, unit). Multiple values are the rule, not the exception."
        } else {
            befundBlock = ""
            labRule = "- Capture only lab values explicitly stated in the parent text."
        }

        return """
        You extract structured facts from a parent's German journal entry about a child in AIEOP-BFM ALL 2017 treatment.

        \(header)

        Rules:
        - Never invent values. If something isn't mentioned, OMIT the field entirely. Never emit "value": null or "value": [].
        - Each field carries both "value" and "confidence" (0.0–1.0; 1.0 means explicitly stated).
        - No advice, diagnosis, dose calculation, or interpretation — only structure what's in the source.
        - Copy names and medical terms verbatim from the source ("Vincristin", "Asparaginase", "Notaufnahme"). Do not anglicise.
        - All free-text values inside the JSON are German.
        \(labRule)

        Context (for sanity-check, do not copy into JSON):
        - phase: \(phaseLabel)
        - dayInPhase: \(dayInPhase)
        - date: \(dateString)

        Schema (every field optional — omit if not mentioned):
        {
          "visitType": { "value": "ambulant|stationaer|notfall|telefonisch|zuhause", "confidence": 0.0-1.0 },
          "doctorName": { "value": "<name>", "confidence": 0.0-1.0 },
          "drugsMentioned": { "value": [{ "name": "<INN>", "germanLabel": "<as written>", "doseDescription": "<free text>", "administeredAt": null }], "confidence": 0.0-1.0 },
          "labValues": { "value": [{ "parameter": "<short code, e.g. WBC, ANC, Hb, HGB, PLT, CRP, ALT, AST, Na, K, Glucose>", "germanLabel": "<German label or same as parameter>", "value": <number>, "unit": "<unit>", "measuredAt": "\(dateString)", "source": "text" }], "confidence": 0.0-1.0 },
          "proceduresMentioned": { "value": ["<procedure>"], "confidence": 0.0-1.0 },
          "decisions": { "value": ["<team decision>"], "confidence": 0.0-1.0 },
          "parentObservations": { "value": ["<parent observation>"], "confidence": 0.0-1.0 },
          "openQuestions": { "value": ["<open question>"], "confidence": 0.0-1.0 },
          "reactions": { "value": [{ "description": "<free text>", "suspectedCause": "<drug/procedure or null>", "parentSeverity": "leicht|mittel|schwer|null", "occurredAt": null }], "confidence": 0.0-1.0 },
          "summary": { "value": "<one German sentence>", "confidence": 0.0-1.0 }
        }

        Input (parent text, German):
        \(text.isEmpty ? "(no parent text — Befund block follows)" : text)\(befundBlock)

        JSON:
        """
    }

    /// Prompt for the `.directMultimodal` path. Focused CBC-extraction prompt
    /// derived from the prompt-engineering sweep in `kaggle_gemma4-prompts`
    /// (`research/REPORT_prompt_engineering.md`): on 33 real Sysmex XN-L
    /// prints, **#7 `explicit_dual_value_handling`** combined the highest
    /// parse rate (1.00 on cropped, 0.97 on raw) with 0.65–0.82 parameter
    /// recall — vs the prior all-in-one nested-confidence schema which
    /// plateaus around 0.43 because the dual-value rows (NEUT/LYMPH/MONO…)
    /// drop silently.
    ///
    /// Trade-off vs the text path: this prompt asks ONLY for the blood
    /// count, so other ExtractedFields (drugs, observations, summary, …)
    /// are not populated in `.directMultimodal`. Real Befund photos are
    /// lab reports — the prose fields belong on the OCR-then-text path.
    /// `parseVisionFields(from:visitDate:)` maps the `blood_count` array
    /// onto `ExtractedFields.labValues` so the rest of the pipeline
    /// (timeline, plots, briefing) sees the same shape it always has.
    ///
    /// We do NOT inline the image inside the prompt string — mlx-swift's
    /// `ChatSession.respond(to:images:)` attaches the image(s) to the
    /// user turn via the model's chat template.
    static func buildVisionPrompt(strictMode: Bool) -> String {
        let header = strictMode
            ? "Strict mode: respond with valid JSON only. No markdown, no prose. Start with { and end with }."
            : "Return only the JSON object. No markdown fences, no commentary."

        return """
        Extract Sysmex blood count data from the attached lab report image into JSON.

        \(header)

        CRITICAL: some rows contain TWO measurements — an absolute count AND a percentage. These must become TWO separate JSON entries:
        - absolute entry → parameter name + "#" suffix
        - percentage entry → parameter name + "%" suffix

        Example — a row reading:   NEUT  0.38 * [10^3/uL]  20.9 * [%]
        becomes:
          {"parameter": "NEUT#", "value": 0.38, "unit": "10^3/uL", "flag": "abnormal"},
          {"parameter": "NEUT%", "value": 20.9, "unit": "%", "flag": "abnormal"}

        This applies to: NEUT, LYMPH, MONO, EO, BASO, IG, and RET.
        All other rows are single-value.

        Schema:
        {
          "blood_count": [
            {"parameter": "<name>", "value": <number>, "unit": "<unit>", "flag": "<low|abnormal>"}
          ]
        }

        Flag markers: "-" after the value → "flag": "low". "*" after the value → "flag": "abnormal". No marker → omit the "flag" field.
        Values are numeric, not strings. Units appear in square brackets.
        Never invent values. If a value is unreadable, omit that entry entirely.
        Return only the JSON.
        """
    }

    /// Text-side counterpart to `buildVisionPrompt` — runs against OCR'd
    /// Sysmex text rather than an attached image. Same prompt #7 structure
    /// (`explicit_dual_value_handling`) and same `blood_count` schema, so
    /// the same `parseVisionFields` parser handles both paths. Used by the
    /// "Befund auslesen" shortcut, which already runs Apple Vision OCR in
    /// the photo sheet before reaching this prompt.
    ///
    /// The `-`/`*` flag markers and `[unit]` brackets survive OCR cleanly
    /// on Sysmex prints, so the same dual-value rule applies.
    static func buildLabsOnlyPrompt(ocrText: String, strictMode: Bool) -> String {
        let header = strictMode
            ? "Strict mode: respond with valid JSON only. No markdown, no prose. Start with { and end with }."
            : "Return only the JSON object. No markdown fences, no commentary."

        return """
        Extract Sysmex blood count data from the OCR text below into JSON.

        \(header)

        CRITICAL: some rows contain TWO measurements — an absolute count AND a percentage. These must become TWO separate JSON entries:
        - absolute entry → parameter name + "#" suffix
        - percentage entry → parameter name + "%" suffix

        Example — a row reading:   NEUT  0.38 * [10^3/uL]  20.9 * [%]
        becomes:
          {"parameter": "NEUT#", "value": 0.38, "unit": "10^3/uL", "flag": "abnormal"},
          {"parameter": "NEUT%", "value": 20.9, "unit": "%", "flag": "abnormal"}

        This applies to: NEUT, LYMPH, MONO, EO, BASO, IG, and RET.
        All other rows are single-value.

        Schema:
        {
          "blood_count": [
            {"parameter": "<name>", "value": <number>, "unit": "<unit>", "flag": "<low|abnormal>"}
          ]
        }

        Flag markers: "-" after the value → "flag": "low". "*" after the value → "flag": "abnormal". No marker → omit the "flag" field.
        Values are numeric, not strings. Units appear in square brackets.
        Never invent values. If a value is unreadable, omit that entry entirely.
        Return only the JSON.

        OCR TEXT:
        ```
        \(ocrText)
        ```
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

    /// Parse the vision-path output — the CBC-only schema emitted by
    /// `buildVisionPrompt`: `{"blood_count": [{parameter, value, unit, flag?}]}`.
    /// Maps each entry to a `LabValue` stamped with `visitDate` and
    /// `source = .befundPhoto`, then wraps as `ExtractedFields` with only
    /// `labValues` populated (the focused prompt doesn't ask for the other
    /// fields — see `buildVisionPrompt` doc comment).
    ///
    /// Tolerant on the units side (defaults to ""), strict on `parameter`
    /// and numeric `value` (entries with missing/null value are dropped —
    /// the rest of the array still surfaces).
    static func parseVisionFields(from raw: String, visitDate: Date) throws -> ExtractedFields {
        guard let jsonString = firstJSONObject(in: raw) else {
            throw ExtractionError.modelReturnedNoJSON
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw ExtractionError.modelReturnedInvalidJSON("UTF-8 encoding failed")
        }

        struct VisionPayload: Decodable {
            struct Item: Decodable {
                let parameter: String
                let value: Double?
                let unit: String?
                let flag: String?
            }
            let blood_count: [Item]
        }

        let payload: VisionPayload
        do {
            payload = try JSONDecoder().decode(VisionPayload.self, from: data)
        } catch {
            throw ExtractionError.modelReturnedInvalidJSON(error.localizedDescription)
        }

        let labs: [LabValue] = payload.blood_count.compactMap { item in
            guard let value = item.value else { return nil }
            return LabValue(
                parameter: item.parameter,
                germanLabel: item.parameter,
                value: value,
                unit: item.unit ?? "",
                measuredAt: visitDate,
                source: .befundPhoto
            )
        }

        guard !labs.isEmpty else {
            throw ExtractionError.modelReturnedInvalidJSON("blood_count empty after dropping unreadable entries")
        }

        return ExtractedFields(
            labValues: ConfidenceField(value: labs, confidence: 0.9)
        )
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
