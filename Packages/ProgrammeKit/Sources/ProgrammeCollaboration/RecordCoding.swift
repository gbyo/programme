import Foundation

/// JSON coding for record payloads, local to the collaboration layer.
///
/// The collaboration module depends only on ProgrammeCore, so it cannot reuse
/// the persistence layer's coder. What matters is that encode and decode here
/// always pair: records are written and read back through these two helpers,
/// never half-encoded by hand.
enum RecordCoding {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }
}
