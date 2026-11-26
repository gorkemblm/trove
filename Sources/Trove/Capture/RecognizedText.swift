import CoreGraphics
import Foundation

/// The text Vision read in an image: one entry per line, with where the line is in the image.
/// Stored as JSON (`recognizedLayout`), encrypted with the rest of the database.
struct RecognizedText: Codable, Equatable, Sendable {
    struct Line: Codable, Equatable, Sendable {
        var text: String
        /// The line's box, as fractions of the image size, from the top-left corner.
        var x: Double
        var y: Double
        var w: Double
        var h: Double

        var box: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    }

    var lines: [Line]

    /// All lines, one per line: what search indexes and "Copy All Text" copies.
    var plainText: String { lines.map(\.text).joined(separator: "\n") }

    var json: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// From the stored JSON. Text read before boxes were stored becomes lines without boxes.
    static func load(layout: String?, text: String?) -> RecognizedText? {
        if let layout, let data = layout.data(using: .utf8), let decoded = try? JSONDecoder().decode(Self.self, from: data) {
            return decoded.lines.isEmpty ? nil : decoded
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return RecognizedText(lines: text.split(separator: "\n").map { Line(text: String($0), x: 0, y: 0, w: 0, h: 0) })
    }

    // MARK: - Matching a search

    /// The words of a search, as search uses them.
    static func terms(of query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Where the term is in the text, ignoring case, accents and Turkish letters (`searchFolded`):
    /// "Yılmaz" is found in "Ayse Yilmaz". Folding keeps one character per character, so a place
    /// in the folded text is the same place in the original.
    private static func ranges(of term: String, in text: String) -> [Range<String.Index>] {
        let original = Array(text.indices)
        let folded = text.map { String($0).searchFolded }
        let needle = term.searchFolded
        guard !needle.isEmpty, folded.allSatisfy({ $0.count == 1 }) else { return [] }
        let haystack = folded.joined()
        var found: [Range<String.Index>] = []
        var start = haystack.startIndex
        while start < haystack.endIndex, let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
            let lower = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            let upper = haystack.distance(from: haystack.startIndex, to: range.upperBound)
            found.append(original[lower]..<(upper < original.count ? original[upper] : text.endIndex))
            start = range.upperBound
        }
        return found
    }

    /// Lines that contain any of the words.
    func lines(matching terms: [String]) -> [Line] {
        guard !terms.isEmpty else { return [] }
        return lines.filter { line in terms.contains { !Self.ranges(of: $0, in: line.text).isEmpty } }
    }

    /// Boxes around each found word, as fractions of the image size. Vision gives a box per
    /// line; a word's part of it follows its place in the line, which fits printed text well.
    func highlights(for terms: [String]) -> [CGRect] {
        var boxes: [CGRect] = []
        for line in lines where line.w > 0 {
            let count = Double(max(line.text.count, 1))
            for term in terms {
                for range in Self.ranges(of: term, in: line.text) {
                    let start = Double(line.text.distance(from: line.text.startIndex, to: range.lowerBound))
                    let length = Double(line.text.distance(from: range.lowerBound, to: range.upperBound))
                    boxes.append(CGRect(x: line.x + line.w * start / count, y: line.y,
                                        width: line.w * length / count, height: line.h))
                }
            }
        }
        return boxes
    }

    /// "…paid on time, invoice 2026-114, due…": the words around the first match, for the list.
    static func snippet(of text: String, terms: [String], radius: Int = 28) -> String? {
        let flat = text.replacingOccurrences(of: "\n", with: " · ")
        guard let range = terms.lazy.compactMap({ ranges(of: $0, in: flat).first }).first else { return nil }
        let start = flat.index(range.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        let middle = flat[start..<end].trimmingCharacters(in: .whitespaces)
        return (start > flat.startIndex ? "…" : "") + middle + (end < flat.endIndex ? "…" : "")
    }

    /// The parts of `text` that match, for bold or coloured runs.
    static func matchRanges(in text: String, terms: [String]) -> [Range<String.Index>] {
        terms.flatMap { ranges(of: $0, in: text) }
    }
}
