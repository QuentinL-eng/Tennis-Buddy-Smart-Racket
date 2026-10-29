import Foundation
import SwiftData

/// Long-term notes about one player, as the coach tools see them. Reads and writes stay on the main actor.
@MainActor
struct CoachMemory {
    static let maxNoteLength = 240
    static let maxNotesPerPlayer = 200
    /// Muse may add at most this many notes per answer, so a confused model can't flood the list.
    static let maxSavesPerAnswer = 2

    let notes: () throws -> [CoachNote]
    let save: (_ text: String, _ category: CoachNote.Category) throws -> CoachNote

    /// Notes for `playerID` in the app's store. New notes are linked to `sessionID`.
    static func store(_ context: ModelContext, playerID: UUID, sessionID: UUID?) -> CoachMemory {
        CoachMemory(
            notes: {
                try context.fetch(FetchDescriptor<CoachNote>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
                    .filter { $0.playerID == playerID }
            },
            save: { text, category in
                let note = CoachNote(playerID: playerID, text: text, category: category, source: "coach", sessionID: sessionID)
                context.insert(note)
                try context.save()
                return note
            })
    }

    /// In-memory notes, for tests and previews.
    static func inMemory(_ initial: [CoachNote] = [], playerID: UUID = UUID()) -> CoachMemory {
        var list = initial
        return CoachMemory(notes: { list.sorted { $0.updatedAt > $1.updatedAt } }, save: { text, category in
            let note = CoachNote(playerID: playerID, text: text, category: category, source: "coach")
            list.append(note)
            return note
        })
    }
}
