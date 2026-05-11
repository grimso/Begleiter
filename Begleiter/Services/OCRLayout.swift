import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif

/// Reconstructs reading-order text from layout-rich OCR inputs.
///
/// **Why this exists:** PDFKit's `PDFPage.string` returns text in
/// document-stream order, which for column-oriented forms (like a CBC
/// printout with `parameter <whitespace> value` rows) often collapses
/// to "all parameter names, then all values" or otherwise loses the
/// row structure. Vision OCR's `observations` are mostly top-to-bottom
/// but within similar y values the left/right order isn't guaranteed.
///
/// In either case, Gemma can't reliably map parameter names to values
/// without spatial structure. This helper clusters items into rows by
/// y midpoint and sorts each row left-to-right, producing tab-
/// separated rows that mirror what the parent sees on the page.
enum OCRLayout {

    // MARK: - Vision observations

    #if canImport(Vision)
    /// Reconstruct text from Vision `VNRecognizedTextObservation`s.
    /// Coordinate system: Vision uses normalised [0,1] coords with
    /// origin at lower-left, y increasing upward.
    static func reconstruct(observations: [VNRecognizedTextObservation]) -> String {
        let items: [LayoutItem] = observations.compactMap { obs in
            guard let cand = obs.topCandidates(1).first else { return nil }
            return LayoutItem(text: cand.string, bbox: obs.boundingBox, ascending: false)
        }
        return reconstructLines(items: items, separator: "\t")
    }
    #endif

    // MARK: - PDFKit characters

    #if canImport(PDFKit)
    /// Reconstruct text from a `PDFPage`'s character bounds. PDFKit's
    /// page-space coords have origin at lower-left, y increasing upward
    /// (same orientation as Vision).
    static func reconstruct(pdfPage: PDFPage) -> String {
        guard let pageString = pdfPage.string, !pageString.isEmpty else { return "" }

        // 1. Build character items with bounds. Skip control chars and
        //    pure whitespace; we'll re-insert spaces between non-adjacent
        //    runs based on x-gap below.
        var items: [LayoutItem] = []
        for (i, char) in pageString.enumerated() {
            let bounds = pdfPage.characterBounds(at: i)
            // PDFKit returns CGRect.zero for non-rendered control chars.
            if bounds == .zero { continue }
            items.append(LayoutItem(text: String(char), bbox: bounds, ascending: false))
        }
        guard !items.isEmpty else { return "" }

        // 2. Cluster characters into lines by y, then within each line
        //    sort left-to-right and reconstruct strings with whitespace
        //    inserted at large x-gaps (column boundaries).
        let lineHeight = medianHeight(of: items)
        let tolerance = max(2.0, lineHeight * 0.5)
        let lines = clusterIntoLines(items: items, tolerance: tolerance, ascending: false)

        return lines.map { line in
            // Sort left-to-right by minX.
            let sorted = line.sorted { $0.bbox.minX < $1.bbox.minX }

            // Walk characters; insert " " when the x-gap exceeds half a
            // line-height, and "\t" when it exceeds a full line-height
            // (column boundary heuristic).
            var lineStr = ""
            var prev: LayoutItem?
            for c in sorted {
                if let prev {
                    let gap = c.bbox.minX - prev.bbox.maxX
                    if gap > lineHeight * 1.2 {
                        lineStr.append("\t")
                    } else if gap > lineHeight * 0.2 {
                        lineStr.append(" ")
                    }
                }
                if !c.text.first!.isWhitespace {
                    lineStr.append(c.text)
                }
                prev = c
            }
            return lineStr.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
    #endif

    // MARK: - Shared row-clustering core

    private struct LayoutItem {
        let text: String
        let bbox: CGRect
        /// `true` if the y-axis ascends going down (top = lowest y),
        /// `false` if it ascends going up (top = highest y). PDFKit and
        /// Vision both use ascending-up, so this is `false` for our
        /// callers, but we keep the option for future image-coord cases.
        let ascending: Bool
    }

    /// Cluster items into lines by similar y midpoint, then return the
    /// lines ordered top-to-bottom.
    private static func clusterIntoLines(
        items: [LayoutItem],
        tolerance: CGFloat,
        ascending: Bool
    ) -> [[LayoutItem]] {
        // Sort top-to-bottom first. With Vision/PDFKit coords (origin
        // lower-left), top = highest midY.
        let sorted = items.sorted { lhs, rhs in
            ascending ? lhs.bbox.midY < rhs.bbox.midY : lhs.bbox.midY > rhs.bbox.midY
        }

        var lines: [[LayoutItem]] = []
        for item in sorted {
            if let last = lines.last, !last.isEmpty {
                let lastY = last.map(\.bbox.midY).reduce(0, +) / CGFloat(last.count)
                if abs(lastY - item.bbox.midY) < tolerance {
                    lines[lines.count - 1].append(item)
                    continue
                }
            }
            lines.append([item])
        }
        return lines
    }

    /// Reconstruct one tab-separated string per line. Used by the
    /// Vision path where each item is already a recognised word/phrase.
    private static func reconstructLines(items: [LayoutItem], separator: String) -> String {
        guard !items.isEmpty else { return "" }
        let lineHeight = medianHeight(of: items)
        let tolerance = max(0.005, lineHeight * 0.5)
        let lines = clusterIntoLines(items: items, tolerance: tolerance, ascending: false)
        return lines.map { line in
            line.sorted { $0.bbox.minX < $1.bbox.minX }
                .map(\.text)
                .joined(separator: separator)
        }
        .joined(separator: "\n")
    }

    private static func medianHeight(of items: [LayoutItem]) -> CGFloat {
        let heights = items.map(\.bbox.height).filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return 0 }
        return heights[heights.count / 2]
    }
}
