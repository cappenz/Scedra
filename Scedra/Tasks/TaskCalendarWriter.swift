import Foundation

/// Writes the placed task onto Apple Calendar. CalendarStore is the real EventKit path.
@MainActor
protocol TaskCalendarWriter: AnyObject {
    func upsertTaskEvent(
        existingIdentifier: String?,
        title: String,
        start: Date,
        end: Date,
        location: String,
        notes: String
    ) async throws -> String

    func deleteTaskEvent(identifier: String) async throws
}

@MainActor
final class MemoryTaskCalendarWriter: TaskCalendarWriter {
    struct Upsert: Equatable {
        var existingIdentifier: String?
        var title: String
        var start: Date
        var end: Date
        var location: String
        var notes: String
        var identifier: String
    }

    var upserts: [Upsert] = []
    var deletedIdentifiers: [String] = []
    var nextIdentifier = "task-event-1"
    var shouldFailUpsert = false

    func upsertTaskEvent(
        existingIdentifier: String?,
        title: String,
        start: Date,
        end: Date,
        location: String,
        notes: String
    ) async throws -> String {
        if shouldFailUpsert {
            throw CalendarStoreError.saveFailed("test writer refused")
        }
        let identifier = existingIdentifier?.isEmpty == false ? existingIdentifier! : nextIdentifier
        upserts.append(
            Upsert(
                existingIdentifier: existingIdentifier,
                title: title,
                start: start,
                end: end,
                location: location,
                notes: notes,
                identifier: identifier
            )
        )
        return identifier
    }

    func deleteTaskEvent(identifier: String) async throws {
        deletedIdentifiers.append(identifier)
    }
}
