import Foundation
import QuickLookThumbnailing
import UIKit

/// File-icon thumbnail for `.programme` archives.
///
/// Reads only the archive manifest (team name, match count, export date):
/// rosters, events and attachments are never opened, so no player PII can
/// reach the thumbnail. No SwiftData, no CloudKit, no package dependencies —
/// Foundation, UIKit drawing and QuickLookThumbnailing only. Anything
/// unexpected (unreadable file, wrong format, missing manifest) returns an
/// error and draws nothing rather than a wrong thumbnail.
final class ArchiveThumbnailProvider: QLThumbnailProvider {
    /// The only archive fields the thumbnail may ever read.
    private struct ManifestFile: Decodable {
        struct Manifest: Decodable {
            var format: String?
            var teamName: String?
            var matchCount: Int?
            var createdAt: Date?
        }
        var manifest: Manifest?
    }

    private struct Summary {
        var teamName: String
        var matchCount: Int
        var createdAt: Date?
    }

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let result = Result { try Self.summarize(fileURL: request.fileURL) }
        switch result {
        case .failure(let error):
            handler(nil, error)
        case .success(let summary):
            let size = Self.drawingSize(for: request.maximumSize)
            let reply = QLThumbnailReply(
                contextSize: size,
                currentContextDrawing: {
                    Self.draw(summary: summary, size: size)
                })
            handler(reply, nil)
        }
    }

    private static func summarize(fileURL: URL) throws -> Summary {
        let data = try Data(contentsOf: fileURL)
        // Matches ProgrammeArchiveCoder: archives encode dates as ISO8601.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(ManifestFile.self, from: data)
        guard let manifest = file.manifest,
            manifest.format == "org.programme.archive",
            let teamName = manifest.teamName, !teamName.isEmpty
        else {
            throw ThumbnailError.notAProgrammeArchive
        }
        return Summary(
            teamName: teamName, matchCount: manifest.matchCount ?? 0,
            createdAt: manifest.createdAt)
    }

    private static func drawingSize(for maximum: CGSize) -> CGSize {
        let side = max(64, min(maximum.width, maximum.height, 512))
        return CGSize(width: side, height: side)
    }

    private static func draw(summary: Summary, size: CGSize) -> Bool {
        guard let context = UIGraphicsGetCurrentContext() else { return false }
        let rect = CGRect(origin: .zero, size: size)

        // Card.
        let background = UIColor.systemBackground
        let accent = UIColor.systemGreen
        context.setFillColor(background.cgColor)
        context.fill(rect)
        let inset = size.width * 0.06
        let card = rect.insetBy(dx: inset, dy: inset)
        accent.withAlphaComponent(0.16).setFill()
        UIBezierPath(roundedRect: card, cornerRadius: size.width * 0.12).fill()

        // Stripe.
        let stripe = CGRect(
            x: card.minX, y: card.minY, width: size.width * 0.05,
            height: card.height)
        accent.setFill()
        UIBezierPath(
            roundedRect: stripe,
            cornerRadius: size.width * 0.025
        ).fill()

        // Lines: team, match count, date. Manifest facts only.
        let padding = size.width * 0.14
        let teamFont = UIFont.systemFont(
            ofSize: size.width * 0.13, weight: .semibold)
        let detailFont = UIFont.systemFont(ofSize: size.width * 0.09)
        let teamColor = UIColor.label
        let detailColor = UIColor.secondaryLabel

        let team = summary.teamName as NSString
        let teamHeight = teamFont.lineHeight
        team.draw(
            at: CGPoint(x: padding, y: size.height * 0.30),
            withAttributes: [.font: teamFont, .foregroundColor: teamColor])

        let matches =
            "\(summary.matchCount) match\(summary.matchCount == 1 ? "" : "es")"
            as NSString
        matches.draw(
            at: CGPoint(x: padding, y: size.height * 0.30 + teamHeight + 2),
            withAttributes: [.font: detailFont, .foregroundColor: detailColor])

        if let createdAt = summary.createdAt {
            let formatted =
                DateFormatter.localizedString(
                    from: createdAt, dateStyle: .medium, timeStyle: .none) as NSString
            formatted.draw(
                at: CGPoint(
                    x: padding,
                    y: size.height * 0.30 + teamHeight + 2 + detailFont.lineHeight + 1),
                withAttributes: [.font: detailFont, .foregroundColor: detailColor])
        }
        return true
    }
}

private enum ThumbnailError: Error {
    case notAProgrammeArchive
}
