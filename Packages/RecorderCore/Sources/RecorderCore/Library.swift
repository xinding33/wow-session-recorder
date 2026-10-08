import Foundation

/// The on-disk list of activities (`library.json` next to the footage).
public struct Library: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var activities: [Activity] = []

    public init(activities: [Activity] = []) {
        self.activities = activities
    }

    public static func load(from url: URL) throws -> Library {
        guard FileManager.default.fileExists(atPath: url.path) else { return Library() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Library.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Inserts or replaces activities by id, preserving user-owned fields like favorites.
    public mutating func upsert(_ updates: [Activity]) {
        for var update in updates {
            if let index = activities.firstIndex(where: { $0.id == update.id }) {
                update.isFavorite = activities[index].isFavorite
                update.notes = activities[index].notes
                activities[index] = update
            } else {
                activities.append(update)
            }
        }
    }
}
