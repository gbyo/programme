import Foundation

/// Optional MDM-delivered configuration for managed school deployments.
///
/// Every field is optional and the whole payload is optional: an unmanaged
/// device behaves exactly as before, and MDM is never required. There is no
/// Organization model — this is a flat suggestion/policy overlay, never a
/// new authority over match truth.
///
/// MDM payload keys (all optional):
/// - `suggestedTeamID`: UUID string of the team to select when the device
///   has no stored team selection. Never overrides an explicit selection.
/// - `defaultRulesName`: rules preset name for teams without a stored default.
/// - `defaultTrackingMode`: `OpponentTrackingMode` raw value for teams
///   without a stored default.
/// - `allowCollaboration`: `false` hides team sharing entry points.
/// - `allowRosterRecognition`: `false` hides camera-scan and photo roster
///   import. File, paste and manual entry always remain.
public struct ManagedProgrammeConfiguration: Decodable, Hashable, Sendable {
    public var suggestedTeamID: TeamID?
    public var defaultRulesName: String?
    public var defaultTrackingMode: OpponentTrackingMode?
    public var allowCollaboration: Bool?
    public var allowRosterRecognition: Bool?

    public init(
        suggestedTeamID: TeamID? = nil,
        defaultRulesName: String? = nil,
        defaultTrackingMode: OpponentTrackingMode? = nil,
        allowCollaboration: Bool? = nil,
        allowRosterRecognition: Bool? = nil
    ) {
        self.suggestedTeamID = suggestedTeamID
        self.defaultRulesName = defaultRulesName
        self.defaultTrackingMode = defaultTrackingMode
        self.allowCollaboration = allowCollaboration
        self.allowRosterRecognition = allowRosterRecognition
    }

    /// Unmanaged device: no suggestions, everything allowed.
    public static var unmanaged: Self { Self() }

    public var isCollaborationAllowed: Bool { allowCollaboration ?? true }
    public var isRosterRecognitionAllowed: Bool { allowRosterRecognition ?? true }

    /// The suggestion, resolved against the teams actually on device.
    /// Returns nil when there is no suggestion or it names an unknown team.
    public func suggestedTeam(from teamIDs: [TeamID]) -> TeamID? {
        guard let suggestedTeamID, teamIDs.contains(suggestedTeamID) else { return nil }
        return suggestedTeamID
    }
}
