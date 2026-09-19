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
        #expect(config.isAutomatedRosterExtractionAllowed)
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
        #expect(decoded.isAutomatedRosterExtractionAllowed)
    }

    @Test("Full MDM payload decodes")
    func fullPayload() throws {
        let id = UUID()
        let json = """
            {"suggestedTeamID": "\(id.uuidString)", "defaultRulesName": "High School", \
            "defaultTrackingMode": "ourTeam", "allowCollaboration": true, \
            "allowAutomatedRosterExtraction": false}
            """
        let decoded = try JSONDecoder().decode(
            ManagedProgrammeConfiguration.self, from: json.data(using: .utf8)!)
        #expect(decoded.suggestedTeamID?.rawValue == id)
        #expect(decoded.defaultRulesName == "High School")
        #expect(decoded.defaultTrackingMode == .ourTeam)
        #expect(decoded.isCollaborationAllowed)
        #expect(!decoded.isAutomatedRosterExtractionAllowed)
    }

    @Test("Unknown rules preset fails loudly, naming the key")
    func unknownRulesPresetThrows() {
        let json = #"{"defaultRulesName": "Quidditch"}"#.data(using: .utf8)!
        do {
            _ = try JSONDecoder().decode(ManagedProgrammeConfiguration.self, from: json)
            Issue.record("Expected a validation error for an unknown rules preset")
        } catch let error as ManagedConfigurationValueError {
            #expect(error.kind == .unknownRulesPreset)
            #expect(error.message.contains("defaultRulesName"))
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("Unknown tracking mode fails loudly")
    func unknownTrackingModeThrows() {
        let json = #"{"defaultTrackingMode": "everyone"}"#.data(using: .utf8)!
        do {
            _ = try JSONDecoder().decode(ManagedProgrammeConfiguration.self, from: json)
            Issue.record("Expected a validation error for an unknown tracking mode")
        } catch let error as ManagedConfigurationValueError {
            #expect(error.kind == .unknownTrackingMode)
            #expect(error.message.contains("defaultTrackingMode"))
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("Malformed team ID fails loudly")
    func malformedTeamIDThrows() {
        let json = #"{"suggestedTeamID": "not-a-uuid"}"#.data(using: .utf8)!
        do {
            _ = try JSONDecoder().decode(ManagedProgrammeConfiguration.self, from: json)
            Issue.record("Expected a validation error for a malformed team ID")
        } catch let error as ManagedConfigurationValueError {
            #expect(error.kind == .malformedTeamID)
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("Wrong JSON type on a policy fails loudly")
    func policyTypeMismatchThrows() {
        let json = #"{"allowCollaboration": "yes"}"#.data(using: .utf8)!
        do {
            _ = try JSONDecoder().decode(ManagedProgrammeConfiguration.self, from: json)
            Issue.record("Expected a validation error for a mistyped policy")
        } catch let error as ManagedConfigurationValueError {
            #expect(error.kind == .typeMismatch)
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("Valid values from every supported preset decode")
    func allPresetNamesDecode() throws {
        for preset in MatchRules.presets {
            let json = #"{"defaultRulesName": "\#(preset.name)"}"#.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(
                ManagedProgrammeConfiguration.self, from: json)
            #expect(decoded.defaultRulesName == preset.name)
        }
        for mode in OpponentTrackingMode.allCases {
            let json = #"{"defaultTrackingMode": "\#(mode.rawValue)"}"#.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(
                ManagedProgrammeConfiguration.self, from: json)
            #expect(decoded.defaultTrackingMode == mode)
        }
    }
}
