import Foundation

#if canImport(ManagedApp)
    import ManagedApp
#endif

/// Optional MDM-delivered configuration for managed school deployments.
///
/// Every field is optional and the whole payload is optional: an unmanaged
/// device behaves exactly as before, and MDM is never required. There is no
/// Organization model — this is a flat suggestion/policy overlay, never a
/// new authority over match truth.
///
/// Managed values are validated on decode: an unknown rules preset, tracking
/// mode or malformed team ID throws ``ManagedConfigurationValueError`` so
/// administrators see an actionable error instead of a silently ignored key.
/// (The App layer reports these through ManagedApp's
/// `ManagedAppConfigurationDecodingError` model.)
///
/// MDM payload keys (all optional) — see docs/MANAGED_CONFIGURATION.md:
/// - `suggestedTeamID`: UUID string of the team to select when the device
///   has no stored team selection. Never overrides an explicit selection.
/// - `defaultRulesName`: rules preset name for teams without a stored default.
/// - `defaultTrackingMode`: `OpponentTrackingMode` raw value for teams
///   without a stored default.
/// - `allowCollaboration`: `false` blocks sharing with other people.
/// - `allowAutomatedRosterExtraction`: `false` hides camera-scan, photo and
///   model-assisted roster import. File, paste and manual entry always remain.
public struct ManagedProgrammeConfiguration: Decodable, Hashable, Sendable {
    public var suggestedTeamID: TeamID?
    public var defaultRulesName: String?
    public var defaultTrackingMode: OpponentTrackingMode?
    public var allowCollaboration: Bool?
    public var allowAutomatedRosterExtraction: Bool?

    public init(
        suggestedTeamID: TeamID? = nil,
        defaultRulesName: String? = nil,
        defaultTrackingMode: OpponentTrackingMode? = nil,
        allowCollaboration: Bool? = nil,
        allowAutomatedRosterExtraction: Bool? = nil
    ) {
        self.suggestedTeamID = suggestedTeamID
        self.defaultRulesName = defaultRulesName
        self.defaultTrackingMode = defaultTrackingMode
        self.allowCollaboration = allowCollaboration
        self.allowAutomatedRosterExtraction = allowAutomatedRosterExtraction
    }

    private enum CodingKeys: String, CodingKey {
        case suggestedTeamID
        case defaultRulesName
        case defaultTrackingMode
        case allowCollaboration
        case allowAutomatedRosterExtraction
        /// Pre-rename key. Still honored so deployed profiles that disable
        /// roster automation keep working; the new key wins when both are
        /// present. See docs/MANAGED_CONFIGURATION.md.
        case allowRosterRecognition
    }

    /// Validates supplied values so a misconfigured profile fails loudly.
    /// Type mismatches on the Boolean policies surface through the same
    /// error with the offending key named.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let rawTeamID = try Self.decodeIfPresentString(
            container, key: .suggestedTeamID)
        {
            guard let uuid = UUID(uuidString: rawTeamID) else {
                throw ManagedConfigurationValueError(
                    kind: .malformedTeamID,
                    message:
                        "suggestedTeamID must be a UUID string naming a team on this device.")
            }
            suggestedTeamID = TeamID(uuid)
        } else {
            suggestedTeamID = nil
        }
        if let name = try Self.decodeIfPresentString(container, key: .defaultRulesName) {
            let supported = MatchRules.presets.map(\.name)
            guard supported.contains(name) else {
                throw ManagedConfigurationValueError(
                    kind: .unknownRulesPreset,
                    message:
                        "defaultRulesName '\(name)' is not a known rules preset. Supported values: \(supported.joined(separator: ", "))."
                )
            }
            defaultRulesName = name
        } else {
            defaultRulesName = nil
        }
        if let rawMode = try Self.decodeIfPresentString(
            container, key: .defaultTrackingMode)
        {
            guard let mode = OpponentTrackingMode(rawValue: rawMode) else {
                throw ManagedConfigurationValueError(
                    kind: .unknownTrackingMode,
                    message:
                        "defaultTrackingMode '\(rawMode)' is not supported. Supported values: \(OpponentTrackingMode.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            defaultTrackingMode = mode
        } else {
            defaultTrackingMode = nil
        }
        do {
            allowCollaboration = try container.decodeIfPresent(Bool.self, forKey: .allowCollaboration)
            let current = try container.decodeIfPresent(
                Bool.self, forKey: .allowAutomatedRosterExtraction)
            let legacy = try container.decodeIfPresent(
                Bool.self, forKey: .allowRosterRecognition)
            allowAutomatedRosterExtraction = current ?? legacy
        } catch {
            throw ManagedConfigurationValueError(
                kind: .typeMismatch,
                message:
                    "allowCollaboration, allowAutomatedRosterExtraction and allowRosterRecognition must be booleans. \(error.localizedDescription)"
            )
        }
    }

    private static func decodeIfPresentString(
        _ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys
    ) throws -> String? {
        do {
            return try container.decodeIfPresent(String.self, forKey: key)
        } catch {
            throw ManagedConfigurationValueError(
                kind: .typeMismatch,
                message: "\(key.stringValue) must be a string. \(error.localizedDescription)"
            )
        }
    }

    /// Unmanaged device: no suggestions, everything allowed.
    public static var unmanaged: Self { Self() }

    public var isCollaborationAllowed: Bool { allowCollaboration ?? true }
    public var isAutomatedRosterExtractionAllowed: Bool {
        allowAutomatedRosterExtraction ?? true
    }

    /// The suggestion, resolved against the teams actually on device.
    /// Returns nil when there is no suggestion or it names an unknown team.
    public func suggestedTeam(from teamIDs: [TeamID]) -> TeamID? {
        guard let suggestedTeamID, teamIDs.contains(suggestedTeamID) else { return nil }
        return suggestedTeamID
    }
}

/// A managed value that fails validation. Carries the offending kind and an
/// administrator-actionable message; it never echoes device data. The App
/// layer bridges this to ManagedApp's `ManagedAppConfigurationDecodingError`
/// so the failure is actionable in managed-device consoles.
public struct ManagedConfigurationValueError: Codable, Hashable, Sendable, Error {
    public enum Kind: String, Codable, Hashable, Sendable {
        case malformedTeamID
        case unknownRulesPreset
        case unknownTrackingMode
        case typeMismatch
    }

    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

#if canImport(ManagedApp)
    /// Same-module bridge from Programme's validation failures to ManagedApp's
    /// `ManagedAppConfigurationDecodingError` model, so misconfigured profiles
    /// surface as actionable errors in managed-device consoles. Declared here —
    /// rather than as an App-layer retroactive conformance — and compiled only
    /// where ManagedApp exists (notably not on watchOS). The code statics are
    /// plain integers naming the codespace; value problems (unknown preset, bad
    /// UUID) read as corrupt data and wrong JSON types as mismatches, mirroring
    /// `DecodingError`'s own taxonomy.
    @available(iOS 18.4, macOS 27, visionOS 2.4, *)
    extension ManagedConfigurationValueError: ManagedAppConfigurationDecodingError {
        public var code: ManagedAppConfigurationDecodingErrorCode {
            get {
                let raw: Int
                switch kind {
                case .malformedTeamID, .unknownRulesPreset, .unknownTrackingMode:
                    raw = ManagedAppConfigurationDecodingErrorCode.dataCorrupted
                case .typeMismatch:
                    raw = ManagedAppConfigurationDecodingErrorCode.typeMismatch
                }
                // Apple's own code constants are definitionally valid raw values.
                return ManagedAppConfigurationDecodingErrorCode(rawValue: raw)!
            }
            set {
                // The system only reads this error; the setter exists for
                // protocol conformance. Recover what the codes distinguish.
                let mismatchCode = ManagedAppConfigurationDecodingErrorCode.typeMismatch
                kind = newValue.rawValue == mismatchCode ? .typeMismatch : .unknownRulesPreset
            }
        }
    }
#endif
