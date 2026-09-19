import Foundation
import ProgrammeCore
import XCTest

@testable import Programme

/// Calendar prefill describes the scheduled match: both teams with the
/// venue relationship, kickoff start, regulation-plus-estimate end, and
/// location/competition carried over only when present.
final class CalendarDraftTests: XCTestCase {
    func testTitleNamesBothTeamsWithVenueRelationship() {
        let draft = CalendarEventDraft(
            descriptor: ProgrammeSample.descriptor(opponent: "Dixie", venue: .away))
        XCTAssertTrue(draft.title.contains("Dixie"))
        XCTAssertTrue(draft.title.contains(" at "))
    }

    func testHomeVenueReadsAsVersus() {
        let draft = CalendarEventDraft(
            descriptor: ProgrammeSample.descriptor(opponent: "Dixie", venue: .home))
        XCTAssertTrue(draft.title.contains(" vs "))
    }

    func testBlockCoversRegulationPlusEstimate() {
        let descriptor = ProgrammeSample.descriptor()
        let draft = CalendarEventDraft(descriptor: descriptor)
        XCTAssertEqual(draft.startDate, descriptor.kickoff)
        let expected =
            TimeInterval(descriptor.rules.regulationLength)
            + CalendarEventDraft.estimatedExtraTime
        XCTAssertEqual(draft.endDate.timeIntervalSince(draft.startDate), expected)
        XCTAssertGreaterThan(expected, TimeInterval(descriptor.rules.regulationLength))
    }

    func testLocationAndCompetitionCarryOverWhenPresent() {
        var descriptor = ProgrammeSample.descriptor()
        descriptor.location = MatchLocation(
            name: "Abbeville High School", address: "701 Washington St", latitude: 34.1,
            longitude: -82.3)
        let draft = CalendarEventDraft(descriptor: descriptor)
        XCTAssertTrue(draft.location?.contains("Abbeville High School") == true)
        XCTAssertTrue(draft.location?.contains("701 Washington St") == true)
        XCTAssertTrue(draft.notes?.contains("Region 2-AA") == true)
    }

    func testMissingLocationAndCompetitionStayMissing() {
        var descriptor = ProgrammeSample.descriptor()
        descriptor.location = nil
        descriptor.competition = nil
        let draft = CalendarEventDraft(descriptor: descriptor)
        XCTAssertNil(draft.location)
        XCTAssertFalse(draft.notes?.contains("Region") == true)
    }
}
