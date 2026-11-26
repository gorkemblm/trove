import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads the text in an image with Apple's Vision framework. Everything runs on this Mac;
/// Trove has no network access.
enum TextRecognizer {
    /// Turkish and English first; Vision also detects the language itself.
    private static let preferredLanguages = ["tr-TR", "en-US"]

    /// The text in the image, one line per line Vision found. Empty when there is none.
    /// Nil when the data is not an image Vision can read.
    static func recognize(_ data: Data) -> String? {
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
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
