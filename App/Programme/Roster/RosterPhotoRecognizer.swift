import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Photo/screenshot roster recognition.
///
/// A roster photo becomes plain text and flows into the same
/// `RosterImporter.preview` review step as CSV, paste, and live camera.
/// Recognition never writes anything: nothing reaches persistence until a
/// person confirms the mapping in `RosterImportView`.
///
/// The installed SDK has no table-structure document API (there is no
/// `RecognizeDocumentsRequest` in Vision), so this uses the accurate
/// `VNRecognizeTextRequest` and orders the recognized strings top-to-bottom
/// as a lines fallback. Table columns are therefore not preserved — the
/// review step's column mapping is where columns get fixed by a human.
enum RosterPhotoRecognizer {
    enum Failure: Error {
        /// The data is not a readable image at all.
        case unreadableImage
        /// A valid image, but Vision found no text in it.
        case noTextFound
        /// Vision itself failed (corrupt data, resource pressure, …).
        case recognitionFailed
    }

    /// Recognizes roster text in image data, returning lines in
    /// top-to-bottom reading order joined by newlines.
    static func recognizeText(in imageData: Data) async throws -> String {
        try await ProgrammeSignposts.measure("rosterRecognition") {
            try await recognize(in: imageData)
        }
    }

    private static func recognize(in imageData: Data) async throws -> String {
        guard
            let source = CGImageSourceCreateWithData(imageData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw Failure.unreadableImage
        }
        let orientation =
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            .flatMap { $0 as? [CFString: Any] }
            .flatMap { $0[kCGImagePropertyOrientation] as? UInt32 }
            .flatMap(CGImagePropertyOrientation.init(rawValue:))
            ?? .up

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw Failure.recognitionFailed
        }
        let paired: [(CGRect, String)] =
            (request.results ?? []).compactMap { observation in
                guard
                    let text = observation.topCandidates(1).first?.string
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                else { return nil }
                return (observation.boundingBox, text)
            }
        guard !paired.isEmpty else {
            // Observations without usable strings mean the same thing to a
            // scorer as no observations: there is nothing to review.
            throw Failure.noTextFound
        }
        return sortTopToBottom(paired).joined(separator: "\n")
    }

    /// Orders recognized strings the way a roster reads: top row first,
    /// left column first within a row. Vision's bounding boxes use a
    /// bottom-left origin, so higher rows have a larger maxY.
    private static func sortTopToBottom(_ paired: [(CGRect, String)]) -> [String] {
        // A row groups observations whose vertical centers sit within a
        // fraction of the tallest box — enough for phone photos of printed
        // tables without pretending to understand real columns.
        let rowTolerance = (paired.map(\.0.height).max() ?? 0.02) * 1.5 + 0.005
        return
            paired
            .sorted { left, right in
                let leftCenter = left.0.midY
                let rightCenter = right.0.midY
                if abs(leftCenter - rightCenter) > rowTolerance {
                    return leftCenter > rightCenter
                }
                return left.0.minX < right.0.minX
            }
            .map(\.1)
    }
}

extension RosterPhotoRecognizer.Failure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return
                "Programme couldn't open that photo. Nothing was changed — try a different image or type the rows instead."
        case .noTextFound:
            return
                "Programme couldn't find any readable text in that photo. Nothing was changed — try a clearer image."
        case .recognitionFailed:
            return
                "Programme couldn't read that photo. Nothing was changed — if it lives in iCloud, check the connection and try again."
        }
    }
}
