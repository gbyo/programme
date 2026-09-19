import Foundation
import Testing

@testable import ProgrammeCore

@Suite("Managed configuration stays optional and never overrides the user")
struct ManagedConfigurationTests {
    @Test("Empty payload means unmanaged: no suggestion, everything allowed")
    func unmanagedDefaults() {
        let config = ManagedProgrammeConfiguration.unmanaged
        #expect(config.suggestedTeam(from: [TeamID()]) == nil)
        #expect(config.isCollaborationAllowed)
        #expect(config.isRosterRecognitionAllowed)
        #expect(config.defaultRulesName == nil)
        #expect(config.defaultTrackingMode == nil)
    }

    @Test("Suggestion resolves only against teams on device")
    func suggestionResolution() throws {
        let wanted = TeamID()
        let other = TeamID()
        let config = ManagedProgrammeConfiguration(suggestedTeamID: wanted)
        #expect(config.suggestedTeam(from: [other, wanted]) == wanted)
        #expect(config.suggestedTeam(from: [other]) == nil)
        #expect(config.suggestedTeam(from: []) == nil)
    }

    @Test("Explicit false disallows; absent allows")
    func allowFlags() throws {
        let decoded = try JSONDecoder().decode(
            ManagedProgrammeConfiguration.self,
            from: #"{"allowCollaboration": false}"#.data(using: .utf8)!)
        #expect(!decoded.isCollaborationAllowed)
        #expect(decoded.isRosterRecognitionAllowed)
    }

    @Test("Full MDM payload decodes")
    func fullPayload() throws {
        let id = UUID()
        let json = """
            {"suggestedTeamID": "\(id.uuidString)", "defaultRulesName": "High School", \
            "defaultTrackingMode": "ourTeam", "allowCollaboration": true, \
            "allowRosterRecognition": false}
            """
        let decoded = try JSONDecoder().decode(
            ManagedProgrammeConfiguration.self, from: json.data(using: .utf8)!)
        #expect(decoded.suggestedTeamID?.rawValue == id)
        #expect(decoded.defaultRulesName == "High School")
        #expect(decoded.defaultTrackingMode == .ourTeam)
        #expect(decoded.isCollaborationAllowed)
        #expect(!decoded.isRosterRecognitionAllowed)
    }
}
