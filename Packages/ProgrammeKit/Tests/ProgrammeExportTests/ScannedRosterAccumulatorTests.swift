import Foundation
import Testing

@testable import ProgrammeExport

@Suite("Live roster scan accumulation stays equal to the current item set")
struct ScannedRosterAccumulatorTests {

    @Test("Added items appear as newline-joined text")
    func addedItemsJoin() {
        var accumulator = ScannedRosterAccumulator()
        accumulator.setItems([
            (id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, transcript: "Ava Morgan"),
            (id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, transcript: "Lena Park"),
        ])
        #expect(accumulator.text == "Ava Morgan\nLena Park")
        #expect(accumulator.lineCount == 2)
        #expect(!accumulator.isEmpty)
    }

    @Test("Removed items disappear instead of lingering")
    func removedItemsDisappear() {
        var accumulator = ScannedRosterAccumulator()
        let kept = UUID()
        accumulator.setItems([(id: kept, transcript: "Ava Morgan"), (id: UUID(), transcript: "Lena Park")])
        accumulator.setItems([(id: kept, transcript: "Ava Morgan")])
        #expect(accumulator.text == "Ava Morgan")
        #expect(accumulator.lineCount == 1)
    }

    @Test("Updated transcripts replace the old text for the same item")
    func updatedTranscriptReplaces() {
        var accumulator = ScannedRosterAccumulator()
        let id = UUID()
        accumulator.setItems([(id: id, transcript: "Ava Morg")])
        accumulator.setItems([(id: id, transcript: "Ava Morgan")])
        #expect(accumulator.text == "Ava Morgan")
        #expect(accumulator.lineCount == 1)
    }

    @Test("Repeated callbacks never duplicate lines")
    func repeatedCallbacksDoNotDuplicate() {
        var accumulator = ScannedRosterAccumulator()
        let items = [(id: UUID(), transcript: "Ava Morgan"), (id: UUID(), transcript: "Lena Park")]
        accumulator.setItems(items)
        accumulator.setItems(items)
        accumulator.setItems(items)
        #expect(accumulator.text == "Ava Morgan\nLena Park")
        #expect(accumulator.lineCount == 2)
    }

    @Test("Duplicate ids in one callback collapse to a single line")
    func duplicateIDsCollapse() {
        var accumulator = ScannedRosterAccumulator()
        let id = UUID()
        accumulator.setItems([(id: id, transcript: "Ava Morgan"), (id: id, transcript: "Ava Morgan")])
        #expect(accumulator.text == "Ava Morgan")
        #expect(accumulator.lineCount == 1)
    }

    @Test("An empty set clears the text")
    func emptySetClears() {
        var accumulator = ScannedRosterAccumulator()
        accumulator.setItems([(id: UUID(), transcript: "Ava Morgan")])
        accumulator.setItems([])
        #expect(accumulator.text == "")
        #expect(accumulator.isEmpty)
    }

    @Test("The same callbacks always produce the same text")
    func sameCallbacksSameText() {
        let items = [(id: UUID(), transcript: "Ava Morgan"), (id: UUID(), transcript: "Lena Park")]
        var first = ScannedRosterAccumulator()
        first.setItems(items)
        var second = ScannedRosterAccumulator()
        second.setItems(items)
        #expect(first == second)
        #expect(first.text == second.text)
    }
}
