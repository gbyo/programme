import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Programme

/// Photo roster recognition never writes anything; these tests pin the
/// failure contract (distinct, human-readable, non-destructive errors) using
/// generated images so no photo-library asset is needed.
final class RosterPhotoRecognizerTests: XCTestCase {
    func testUnreadableDataThrowsUnreadableImage() async {
        do {
            _ = try await RosterPhotoRecognizer.recognizeText(in: Data([0x00, 0x01, 0x02]))
            XCTFail("Expected Failure.unreadableImage for non-image data.")
        } catch let failure as RosterPhotoRecognizer.Failure {
            XCTAssertEqual(failure, .unreadableImage)
        } catch {
            XCTFail("Unexpected error type: \(error).")
        }
    }

    func testBlankImageThrowsNoTextFound() async throws {
        let data = try XCTUnwrap(makeBlankPNG())
        do {
            _ = try await RosterPhotoRecognizer.recognizeText(in: data)
            XCTFail("Expected Failure.noTextFound for a blank image.")
        } catch let failure as RosterPhotoRecognizer.Failure {
            XCTAssertEqual(failure, .noTextFound)
        } catch {
            XCTFail("Unexpected error type: \(error).")
        }
    }

    func testFailureCopyIsDistinctAndNonDestructive() {
        let descriptions = [
            RosterPhotoRecognizer.Failure.unreadableImage,
            .noTextFound,
            .recognitionFailed,
        ].map { $0.errorDescription }
        XCTAssertEqual(descriptions.compactMap(\.self).count, 3)
        XCTAssertEqual(Set(descriptions.compactMap(\.self)).count, 3)
        for description in descriptions.compactMap(\.self) {
            XCTAssertTrue(
                description.contains("Nothing was changed"),
                "Photo recognition failures must say nothing changed: \(description)"
            )
        }
    }

    /// A solid-white PNG recognizers accept as a valid image with no text.
    private func makeBlankPNG() throws -> Data {
        let size = 200
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
