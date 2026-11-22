import Foundation

/// A Codable value in one JSON file, written atomically. If the file exists but can't be read, the
/// store refuses to save, so a newer version's file or a damaged one is never overwritten.
public final class JSONStore<Value: Codable>: @unchecked Sendable {
    public let url: URL
    public private(set) var loadError: Error?

    public init(url: URL) {
        self.url = url
    }

    /// The stored value, nil if there's no file yet or it can't be read.
    public func load() -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let value = try Self.decoder.decode(Value.self, from: Data(contentsOf: url))
            loadError = nil
            return value
        } catch {
            loadError = error
            return nil
        }
    }

    public func save(_ value: Value) throws {
        if let loadError { throw StoreError.unreadable(url, loadError) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    public func remove() throws {
        if let loadError { throw StoreError.unreadable(url, loadError) }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum StoreError: LocalizedError {
    case unreadable(URL, Error)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url, let error):
            "\(url.lastPathComponent) couldn't be read, so it wasn't overwritten: \(error.localizedDescription)"
        }
    }
}
