import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads the text in an image with Apple's Vision framework. Everything runs on this Mac;
/// Trove has no network access.
enum TextRecognizer {
    /// Turkish and English first; Vision also detects the language itself.
    private static let preferredLanguages = ["tr-TR", "en-US"]

    /// The lines Vision found, with their place in the image; no lines when there is no text.
    /// Nil when the data is not an image Vision can read.
    static func recognize(_ data: Data) -> RecognizedText? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let languages = preferredLanguages.filter(supported.contains)
        if !languages.isEmpty { request.recognitionLanguages = languages }
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { observation -> RecognizedText.Line? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox // Vision: fractions, from the bottom-left corner.
            return RecognizedText.Line(text: text, x: box.minX, y: 1 - box.maxY, w: box.width, h: box.height)
        }
        // Reading order: top to bottom, then left to right on the same line.
        return RecognizedText(lines: lines.sorted { abs($0.y - $1.y) > 0.01 ? $0.y < $1.y : $0.x < $1.x })
    }
}
