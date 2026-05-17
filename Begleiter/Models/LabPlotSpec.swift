import Foundation

/// What the parent's natural-language request gets parsed into — the wire
/// shape both `LabPlotParser.heuristic` and `LabPlotParser.gemma` produce
/// and what `LabPlotResolver` + `LabPlotResultView` consume.
///
/// Parameter short-hands like "Blutbild" / "CBC" / "Leberwerte" are
/// expanded by the parser before this struct is built — the resolver and
/// renderer always see a concrete list of canonical short codes (matches
/// `LabSeries.parameter`, e.g. "WBC", "ANC", "HB", "PLT").
///
/// `Codable` so the Gemma path can deserialize directly. Manual encoding
/// for `Window` keeps the JSON tag-friendly: `{"kind": "phase", …}` —
/// easier for the model to emit and for tests to assert on than Swift's
/// auto-synth associated-value form.
nonisolated struct LabPlotSpec: Codable, Hashable, Sendable {
    /// Single-line German title for the chart card. Filled by the parser
    /// (heuristic: assembled from parameter shorthand + window labels;
    /// Gemma: emitted directly).
    let title: String

    /// Canonical short codes, e.g. `["WBC", "ANC", "HB", "PLT"]`.
    /// Order is the order the renderer uses (rows of the side-by-side
    /// grid, or order of overlay charts).
    let parameters: [String]

    /// One or more time windows to display. The renderer's behaviour
    /// depends on `layout`: side-by-side puts each window in its own
    /// column; overlay stacks them on one chart per parameter.
    let windows: [Window]

    /// How to arrange `parameters × windows` visually.
    let layout: Layout

    enum Layout: String, Codable, Hashable, Sendable {
        /// Grid: rows = parameters, columns = windows. One small chart
        /// per cell. Default when two windows are detected.
        case sideBySideByParameter
        /// One chart per parameter; all windows overlaid on a normalised
        /// "day-in-window" x-axis with different colours. Better for
        /// trend-shape comparison.
        case overlayWindowsPerParameter

        /// Tolerant decoder: accepts canonical camelCase, snake_case, and
        /// common aliases the model emits (`side_by_side`, `overlay`,
        /// `grid`, `stacked`, …). Unknown values default to
        /// `.sideBySideByParameter` rather than throwing — the rendering
        /// layout is a presentation hint, not a correctness invariant.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            let folded = raw
                .lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            switch folded {
            case "sidebysidebyparameter", "sidebyside", "grid", "columns",
                 "sidebysidebywindows", "sidebysideparameter":
                self = .sideBySideByParameter
            case "overlaywindowsperparameter", "overlay", "overlaywindows",
                 "stacked", "overlayperparameter":
                self = .overlayWindowsPerParameter
            default:
                self = .sideBySideByParameter
            }
        }
    }

    /// One time window. Stays abstract so `LabPlotResolver` can turn
    /// `.phase` into an actual `DateInterval` using `ChildState`'s
    /// completed-phase history.
    enum Window: Codable, Hashable, Sendable {
        /// Phase-relative window: day `fromDay` … `toDay` (1-indexed,
        /// inclusive) of a named phase. e.g. `.phase("inductionIA", 1, 14)`
        /// = first two weeks of Induction IA.
        case phase(phase: String, fromDay: Int, toDay: Int, label: String?)

        /// Window relative to now: last N days, ending now.
        case relativeDays(daysBack: Int, label: String?)

        /// Absolute window. Used by the Gemma path when the parent
        /// mentions specific months/dates. The heuristic doesn't emit
        /// this case in v1.
        case absolute(from: Date, to: Date, label: String?)
    }
}

// MARK: - Tagged-JSON Codable for `Window`

extension LabPlotSpec.Window {
    private enum CodingKeys: String, CodingKey {
        case kind, type
        case phase
        case fromDay, from_day, startDay, start_day
        case toDay, to_day, endDay, end_day
        case label, window
        case daysBack, days_back, days
        case from, to
        case start, end
    }

    private enum Kind: String {
        case phase, relativeDays, absolute
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .phase(let phase, let fromDay, let toDay, let label):
            try c.encode(Kind.phase.rawValue, forKey: .kind)
            try c.encode(phase, forKey: .phase)
            try c.encode(fromDay, forKey: .fromDay)
            try c.encode(toDay, forKey: .toDay)
            try c.encodeIfPresent(label, forKey: .label)
        case .relativeDays(let daysBack, let label):
            try c.encode(Kind.relativeDays.rawValue, forKey: .kind)
            try c.encode(daysBack, forKey: .daysBack)
            try c.encodeIfPresent(label, forKey: .label)
        case .absolute(let from, let to, let label):
            try c.encode(Kind.absolute.rawValue, forKey: .kind)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encodeIfPresent(label, forKey: .label)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let rawKind: String = (try? c.decode(String.self, forKey: .kind))
            ?? (try? c.decode(String.self, forKey: .type))
            ?? ""
        let kind = Self.normalizeKind(rawKind)

        let label = (try? c.decode(String.self, forKey: .label))
            ?? (try? c.decode(String.self, forKey: .window))

        switch kind {
        case .phase:
            let phase = try c.decode(String.self, forKey: .phase)
            let fromDay = Self.firstInt(in: c, keys: [.fromDay, .from_day, .startDay, .start_day]) ?? 1
            let toDay = Self.firstInt(in: c, keys: [.toDay, .to_day, .endDay, .end_day]) ?? fromDay
            self = .phase(phase: phase, fromDay: fromDay, toDay: toDay, label: label)

        case .relativeDays:
            if let n = Self.firstInt(in: c, keys: [.daysBack, .days_back, .days]) {
                self = .relativeDays(daysBack: n, label: label)
            } else if let derived = Self.daysBack(fromString: label)
                ?? Self.daysBack(fromString: (try? c.decode(String.self, forKey: .window))) {
                self = .relativeDays(daysBack: derived, label: label)
            } else {
                self = .relativeDays(daysBack: 7, label: label)
            }

        case .absolute:
            let from = (try? c.decode(Date.self, forKey: .from))
                ?? (try? c.decode(Date.self, forKey: .start))
            let to = (try? c.decode(Date.self, forKey: .to))
                ?? (try? c.decode(Date.self, forKey: .end))
            guard let from, let to else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath,
                          debugDescription: "absolute window missing from/to dates"))
            }
            self = .absolute(from: from, to: to, label: label)
        }
    }

    /// Map raw model output for the `kind` discriminator onto the
    /// canonical enum. Defaults to `.phase` when missing — the prompt
    /// emphasises phase windows, so this matches the most common shape.
    private static func normalizeKind(_ raw: String) -> Kind {
        let folded = raw
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch folded {
        case "phase", "phasewindow", "phasewindowdays": return .phase
        case "relativedays", "relative", "relativetonow", "lastdays": return .relativeDays
        case "absolute", "absolutedates", "absolutewindow", "daterange": return .absolute
        default: return .phase
        }
    }

    /// First decodable Int among the given keys, or nil. Tolerates the
    /// model emitting either `fromDay` or `from_day` etc.
    private static func firstInt(in c: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let v = try? c.decode(Int.self, forKey: key) { return v }
        }
        return nil
    }

    /// Best-effort daysBack extraction from a label like `"last 30 days"`,
    /// `"letzte 2 Wochen"`, `"last_month"`. Returns nil if nothing
    /// parses out.
    private static func daysBack(fromString s: String?) -> Int? {
        guard let s = s?.lowercased() else { return nil }
        if let match = s.range(of: #"(\d+)"#, options: .regularExpression),
           let n = Int(s[match]) {
            if s.contains("week") || s.contains("woche") { return n * 7 }
            if s.contains("month") || s.contains("monat") { return n * 30 }
            if s.contains("year") || s.contains("jahr") { return n * 365 }
            return n
        }
        if s.contains("week") || s.contains("woche") { return 7 }
        if s.contains("month") || s.contains("monat") { return 30 }
        if s.contains("year") || s.contains("jahr") { return 365 }
        return nil
    }
}

// MARK: - Resolved result + per-panel data

/// What `LabPlotResolver` produces from a spec + the current
/// `ChildState` + the journal entries. The renderer reads this directly.
nonisolated struct LabPlotResult: Hashable, Sendable {
    let spec: LabPlotSpec
    let panels: [LabPlotPanel]
    /// 1:1 with `spec.windows` — the absolute `DateInterval` each window
    /// resolved to. `nil` slot means the window referenced a phase the
    /// child hasn't entered yet; the matching `LabPlotWindowPoints`
    /// inside each panel will be empty and a
    /// `LabPlotWarning.phaseNotYetEntered` is set.
    let resolvedRanges: [DateInterval?]
    let warnings: [LabPlotWarning]
}

nonisolated struct LabPlotPanel: Identifiable, Hashable, Sendable {
    var id: String { parameter }
    let parameter: String         // canonical short code, e.g. "WBC"
    let germanLabel: String       // e.g. "Leukozyten"
    let unit: String              // e.g. "G/L"
    let referenceMin: Double?
    let referenceMax: Double?
    /// 1:1 with `spec.windows`. Same length even when a window had zero
    /// points — the renderer shows a placeholder cell in that case.
    let windows: [LabPlotWindowPoints]
}

nonisolated struct LabPlotWindowPoints: Hashable, Sendable {
    let label: String             // e.g. "Induktion IA, Tag 1–14"
    let dateRange: DateInterval?  // nil if the window couldn't resolve
    let points: [Point]

    /// Self-contained point type so `LabPlotResult` doesn't depend on
    /// SwiftUI's `LabValueChart.Point`. The renderer adapts these into
    /// chart points at draw time.
    nonisolated struct Point: Identifiable, Hashable, Sendable {
        let id: UUID
        let date: Date
        let value: Double
        /// Source `JournalEntry.entryId` so the renderer can deep-link
        /// to the originating entry if we wire that later.
        let sourceEntryId: UUID
    }
}

nonisolated enum LabPlotWarning: String, Hashable, Sendable {
    /// At least one (parameter, window) cell has zero points.
    case noPointsInWindow
    /// At least one window references a phase the child hasn't entered
    /// (not in `completedPhases` and not the current phase).
    case phaseNotYetEntered
    /// Parser saw a parameter short-hand it didn't recognise (e.g.
    /// "Knochenmarkwerte") and skipped it. The remaining parameters
    /// were still resolved.
    case parameterShorthandUnknown
}
