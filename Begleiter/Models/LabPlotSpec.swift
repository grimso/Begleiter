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
        case kind, phase, fromDay, toDay, label, daysBack, from, to
    }

    private enum Kind: String, Codable {
        case phase, relativeDays, absolute
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .phase(let phase, let fromDay, let toDay, let label):
            try c.encode(Kind.phase, forKey: .kind)
            try c.encode(phase, forKey: .phase)
            try c.encode(fromDay, forKey: .fromDay)
            try c.encode(toDay, forKey: .toDay)
            try c.encodeIfPresent(label, forKey: .label)
        case .relativeDays(let daysBack, let label):
            try c.encode(Kind.relativeDays, forKey: .kind)
            try c.encode(daysBack, forKey: .daysBack)
            try c.encodeIfPresent(label, forKey: .label)
        case .absolute(let from, let to, let label):
            try c.encode(Kind.absolute, forKey: .kind)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encodeIfPresent(label, forKey: .label)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let label = try c.decodeIfPresent(String.self, forKey: .label)
        switch kind {
        case .phase:
            self = .phase(
                phase:   try c.decode(String.self, forKey: .phase),
                fromDay: try c.decode(Int.self, forKey: .fromDay),
                toDay:   try c.decode(Int.self, forKey: .toDay),
                label:   label
            )
        case .relativeDays:
            self = .relativeDays(
                daysBack: try c.decode(Int.self, forKey: .daysBack),
                label:    label
            )
        case .absolute:
            self = .absolute(
                from:  try c.decode(Date.self, forKey: .from),
                to:    try c.decode(Date.self, forKey: .to),
                label: label
            )
        }
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
