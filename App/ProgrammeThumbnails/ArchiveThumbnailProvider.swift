import Foundation
import QuickLookThumbnailing
import UIKit

/// File-icon thumbnail for `.programme` archives.
///
/// The file is read memory-mapped behind a conservative size cap, but only
/// the archive manifest (team name, match count, export date) is ever
/// materialized: rosters, events and attachments stay encoded, so no player
/// PII can reach the thumbnail. No SwiftData, no CloudKit, no package
/// dependencies — Foundation, UIKit drawing and QuickLookThumbnailing only.
/// Anything unexpected (unreadable file, wrong format, missing manifest)
/// returns an error and draws nothing rather than a wrong thumbnail.
final class ArchiveThumbnailProvider: QLThumbnailProvider {
    /// Archives are small JSON documents; anything far larger is malformed.
    private static let maximumArchiveBytes = 4 * 1_024 * 1_024

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
            // The template contract: draw exactly the requested maximum.
            let size = request.maximumSize
            let reply = QLThumbnailReply(
                contextSize: size,
                currentContextDrawing: {
                    Self.draw(summary: summary, size: size)
                })
            handler(reply, nil)
        }
    }

    private static func summarize(fileURL: URL) throws -> Summary {
        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= maximumArchiveBytes else {
            throw ThumbnailError.archiveTooLarge
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
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

    /// Draws into exactly the requested size. The card is a centered
    /// square on the smaller dimension; every metric scales from it, so a
    /// small list-icon request gets a legible mark, never an over-size
    /// context. Semantic colors adapt to light/dark thumbnails.
    private static func draw(summary: Summary, size: CGSize) -> Bool {
        guard let context = UIGraphicsGetCurrentContext() else { return false }
        guard size.width > 0, size.height > 0 else { return false }
        let rect = CGRect(origin: .zero, size: size)
        let unit = min(size.width, size.height)

        // Card.
        let background = UIColor.systemBackground
        let accent = UIColor.systemGreen
        context.setFillColor(background.cgColor)
        context.fill(rect)
        let card = CGRect(
            x: (size.width - unit) / 2 + unit * 0.06,
            y: (size.height - unit) / 2 + unit * 0.06,
            width: unit * 0.88,
            height: unit * 0.88)
        accent.withAlphaComponent(0.16).setFill()
        UIBezierPath(roundedRect: card, cornerRadius: unit * 0.12).fill()

        // Stripe.
        let stripe = CGRect(
            x: card.minX, y: card.minY, width: unit * 0.05,
            height: card.height)
        accent.setFill()
        UIBezierPath(
            roundedRect: stripe,
            cornerRadius: unit * 0.025
        ).fill()

        // Lines: team, match count, date. Manifest facts only.
        let padding = card.minX + unit * 0.08
        let teamFont = UIFont.systemFont(
            ofSize: unit * 0.13, weight: .semibold)
        let detailFont = UIFont.systemFont(ofSize: unit * 0.09)
        let teamColor = UIColor.label
        let detailColor = UIColor.secondaryLabel

        let team = summary.teamName as NSString
        let teamHeight = teamFont.lineHeight
        team.draw(
            at: CGPoint(x: padding, y: card.minY + card.height * 0.24),
            withAttributes: [.font: teamFont, .foregroundColor: teamColor])

        let matches =
            "\(summary.matchCount) match\(summary.matchCount == 1 ? "" : "es")"
            as NSString
        matches.draw(
            at: CGPoint(x: padding, y: card.minY + card.height * 0.24 + teamHeight + 2),
            withAttributes: [.font: detailFont, .foregroundColor: detailColor])

        if let createdAt = summary.createdAt {
            let formatted =
                DateFormatter.localizedString(
                    from: createdAt, dateStyle: .medium, timeStyle: .none) as NSString
            formatted.draw(
                at: CGPoint(
                    x: padding,
                    y: card.minY + card.height * 0.24 + teamHeight + 2 + detailFont.lineHeight
                        + 1),
                withAttributes: [.font: detailFont, .foregroundColor: detailColor])
        }
        return true
    }
}

private enum ThumbnailError: Error {
    case notAProgrammeArchive
    case archiveTooLarge
}
