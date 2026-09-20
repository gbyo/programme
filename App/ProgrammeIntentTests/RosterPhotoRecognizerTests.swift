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

    func testDownsamplingCapsLargeImageLongestSide() throws {
        let data = try XCTUnwrap(makeBlankPNG(width: 4000, height: 3000))
        let image = try XCTUnwrap(RosterPhotoRecognizer.downsampledImage(from: data))
        XCTAssertLessThanOrEqual(
            max(image.width, image.height),
            RosterPhotoRecognizer.maxWorkingPixelDimension
        )
        // Aspect ratio survives the thumbnail decode (4:3 stays 4:3).
        XCTAssertEqual(Double(image.width) / Double(image.height), 4.0 / 3.0, accuracy: 0.02)
    }

    func testDownsamplingDoesNotUpscaleSmallImages() throws {
        let data = try XCTUnwrap(makeBlankPNG())
        let image = try XCTUnwrap(RosterPhotoRecognizer.downsampledImage(from: data))
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 200)
    }

    func testOrientationTagSurvivesDownsamplingPath() throws {
        // EXIF 6 (.right): stored pixels stay untransformed and the tag
        // is what Vision receives, so it must round-trip unchanged.
        let data = try XCTUnwrap(makeBlankPNG(orientation: 6))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            XCTFail("Test image data should decode as an image source.")
            return
        }
        XCTAssertEqual(RosterPhotoRecognizer.sourceOrientation(source), .right)
        XCTAssertNotNil(RosterPhotoRecognizer.downsampledImage(from: source))
    }

    func testLargeBlankImageThrowsNoTextFound() async throws {
        // End to end through the thumbnail path: a large photo with no
        // text behaves exactly like a small blank one.
        let data = try XCTUnwrap(makeBlankPNG(width: 4000, height: 3000))
        do {
            _ = try await RosterPhotoRecognizer.recognizeText(in: data)
            XCTFail("Expected Failure.noTextFound for a large blank image.")
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
    private func makeBlankPNG(width: Int = 200, height: Int = 200, orientation: UInt32? = nil) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            ))
        var properties: [CFString: Any]? {
            guard let orientation else { return nil }
            return [kCGImagePropertyOrientation: orientation]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
