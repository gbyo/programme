import Foundation
import XCTest

@testable import Programme
@testable import ProgrammeCore
@testable import ProgrammePersistence

/// Team defaults provenance and selection migration, without MDM or UI:
/// untouched suggestions must never reach storage, explicit choices
/// (even ones equal to a suggestion) must, and pre-provenance selections
/// must survive the upgrade as explicit.
///
/// Fixtures are locals (never `self`) because the MainActor hop each test
/// performs requires Sendable captures.
final class TeamDefaultsProvenanceTests: XCTestCase {
    private static func stored(_ field: String, teamID: TeamID) -> String? {
        UserDefaults.standard.string(
            forKey: "programme.team.\(teamID.rawValue.uuidString).\(field)")
    }

    private func managedSuggestion() -> ManagedProgrammeConfiguration {
        ManagedProgrammeConfiguration(
            defaultRulesName: MatchRules.college.name, defaultTrackingMode: .bothTeams)
    }

    func testUntouchedSuggestionIsNeverPersisted() async {
        let teamID = TeamID(UUID())
        let managed = managedSuggestion()
        await MainActor.run {
            let loaded = TeamMatchDefaults.load(teamID: teamID, managed: managed)
            XCTAssertEqual(loaded.rulesName, MatchRules.college.name)
            TeamMatchDefaults.save(
                teamID: teamID, profileID: loaded.profileID, rulesName: loaded.rulesName,
                tracking: loaded.tracking, loaded: loaded)
            XCTAssertNil(Self.stored("rulesPreset", teamID: teamID))
            XCTAssertNil(Self.stored("opponentTracking", teamID: teamID))
            XCTAssertNil(Self.stored("statProfile", teamID: teamID))
        }
    }

    func testExplicitChoiceEqualToSuggestionIsPersisted() async {
        let teamID = TeamID(UUID())
        let managed = managedSuggestion()
        await MainActor.run {
            var loaded = TeamMatchDefaults.load(teamID: teamID, managed: managed)
            // The user explicitly picks the suggested value: a real override.
            TeamMatchDefaults.save(
                teamID: teamID, profileID: loaded.profileID, rulesName: MatchRules.college.name,
                tracking: .bothTeams, loaded: (loaded.profileID, "High School", .ourTeam))
            XCTAssertEqual(Self.stored("rulesPreset", teamID: teamID), MatchRules.college.name)
            loaded = TeamMatchDefaults.load(teamID: teamID, managed: managed)
            XCTAssertEqual(loaded.rulesName, MatchRules.college.name)
        }
    }

    func testToggleAwayAndBackPersistsTheReturnTrip() async {
        let teamID = TeamID(UUID())
        await MainActor.run {
            let first = TeamMatchDefaults.load(teamID: teamID, managed: .unmanaged)
            TeamMatchDefaults.save(
                teamID: teamID, profileID: first.profileID, rulesName: MatchRules.college.name,
                tracking: first.tracking, loaded: first)
            let second = TeamMatchDefaults.LoadedDefaults(
                profileID: first.profileID, rulesName: MatchRules.college.name,
                tracking: first.tracking)
            TeamMatchDefaults.save(
                teamID: teamID, profileID: first.profileID,
                rulesName: MatchRules.highSchool.name, tracking: first.tracking, loaded: second)
            XCTAssertEqual(Self.stored("rulesPreset", teamID: teamID), MatchRules.highSchool.name)
        }
    }

    func testStoredUserValueWinsOverLaterSuggestion() async {
        let teamID = TeamID(UUID())
        let managed = managedSuggestion()
        await MainActor.run {
            var loaded = TeamMatchDefaults.load(teamID: teamID, managed: .unmanaged)
            TeamMatchDefaults.save(
                teamID: teamID, profileID: loaded.profileID,
                rulesName: MatchRules.professional.name, tracking: loaded.tracking,
                loaded: loaded)
            loaded = TeamMatchDefaults.load(teamID: teamID, managed: managed)
            XCTAssertEqual(loaded.rulesName, MatchRules.professional.name)
        }
    }

    func testLegacySelectionMigratesToExplicit() async {
        await MainActor.run {
            let defaults = UserDefaults.standard
            let idKey = TeamWorkspace.selectedTeamKey
            let flagKey = TeamWorkspace.explicitSelectionKey
            let savedID = defaults.string(forKey: idKey)
            let savedFlag = defaults.object(forKey: flagKey)
            defer {
                if let savedID {
                    defaults.set(savedID, forKey: idKey)
                } else {
                    defaults.removeObject(forKey: idKey)
                }
                if let savedFlag {
                    defaults.set(savedFlag, forKey: flagKey)
                } else {
                    defaults.removeObject(forKey: flagKey)
                }
            }
            // Legacy state: an ID persisted before flags existed.
            let legacy = TeamID(UUID())
            defaults.set(legacy.rawValue.uuidString, forKey: idKey)
            defaults.removeObject(forKey: flagKey)
            TeamWorkspace.migrateSelectionProvenance()
            XCTAssertEqual(
                TeamWorkspace.restoredExplicitSelection(
                    from: [
                        TeamIdentity(
                            id: legacy, name: "Legacy", shortName: "LEG")
                    ]),
                legacy)
            // Second run is a no-op for already-flagged storage.
            defaults.set(false, forKey: flagKey)
            TeamWorkspace.migrateSelectionProvenance()
            XCTAssertFalse(defaults.bool(forKey: flagKey))
        }
    }

    func testBecomingAvailableFiresOnlyOnEntry() async {
        await MainActor.run {
            XCTAssertTrue(
                CloudKitAccountMonitor.becameAvailable(previous: .unknown, current: .available))
            XCTAssertTrue(
                CloudKitAccountMonitor.becameAvailable(previous: .noAccount, current: .available))
            XCTAssertFalse(
                CloudKitAccountMonitor.becameAvailable(previous: .available, current: .available))
            XCTAssertFalse(
                CloudKitAccountMonitor.becameAvailable(previous: .available, current: .noAccount))
            XCTAssertFalse(
                CloudKitAccountMonitor.becameAvailable(
                    previous: .unknown, current: .temporarilyUnavailable))
        }
    }
}
