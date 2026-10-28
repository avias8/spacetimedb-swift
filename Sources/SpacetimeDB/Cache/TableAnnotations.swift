import Foundation

/// Defines a SpacetimeDB table descriptor connecting a row model to its table name, primary key, and indexes.
public protocol SpacetimeTableDescriptor: Sendable {
    associatedtype Row: Decodable & Sendable
    static var tableName: String { get }
    static func register(in cache: ClientCache) -> TableCache<Row>
}

public extension SpacetimeTableDescriptor {
    @discardableResult
    static func register(in cache: ClientCache = SpacetimeClient.clientCache) -> TableCache<Row> {
        cache.registerTable(tableName: tableName, rowType: Row.self)
        return cache.getTableCache(tableName: tableName)
    }

    static func query() -> TableQuery<Row> {
        TableQuery<Row>(tableName: tableName)
    }
}

/// Property wrapper declaring a struct property as the primary key of a SpacetimeDB table row.
///
/// When used on a row model conforming to `SpacetimePrimaryKeyRow`, `@SpacetimePrimaryKey`
/// transparently forwards its `wrappedValue` while documenting primary-key identity.
@propertyWrapper
public struct SpacetimePrimaryKey<Value: Hashable & Codable & Sendable>: Hashable, Codable, Sendable {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.wrappedValue = try container.decode(Value.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// Property wrapper declaring a struct property as uniquely indexed in a SpacetimeDB table row.
@propertyWrapper
public struct SpacetimeUniqueIndexed<Value: Hashable & Codable & Sendable>: Hashable, Codable, Sendable {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.wrappedValue = try container.decode(Value.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// Property wrapper declaring a struct property as B-Tree range-indexed in a SpacetimeDB table row.
@propertyWrapper
public struct SpacetimeBTreeIndexed<Value: Comparable & Hashable & Codable & Sendable>: Hashable, Codable, Sendable {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.wrappedValue = try container.decode(Value.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// Checks whether a local row type's expected BSATN fixed byte size or column list matches a remote table schema,
/// surfacing actionable diagnostics when schema drift occurs.
public enum SpacetimeSchemaValidator {
    public enum SchemaDriftError: Error, Equatable, LocalizedError {
        case missingColumns(table: String, missing: [String])
        case unexpectedColumns(table: String, unexpected: [String])
        case columnOrderMismatch(table: String, expected: [String], actual: [String])

        public var errorDescription: String? {
            switch self {
            case .missingColumns(let table, let missing):
                return "Schema drift detected for table '\(table)': missing columns \(missing.joined(separator: ", ")). Re-run `spacetime generate --lang swift`."
            case .unexpectedColumns(let table, let unexpected):
                return "Schema drift detected for table '\(table)': unexpected columns \(unexpected.joined(separator: ", ")). Re-run `spacetime generate --lang swift`."
            case .columnOrderMismatch(let table, let expected, let actual):
                return "Schema drift detected for table '\(table)': expected column order \(expected), got \(actual). Re-run `spacetime generate --lang swift`."
            }
        }
    }

    /// Validates that `expectedColumns` (from generated Swift bindings) exactly match `actualColumns` (from module schema).
    public static func validateColumns(
        table: String,
        expected expectedColumns: [String],
        actual actualColumns: [String]
    ) throws(SchemaDriftError) {
        let expectedSet = Set(expectedColumns)
        let actualSet = Set(actualColumns)
        let missing = expectedColumns.filter { !actualSet.contains($0) }
        if !missing.isEmpty {
            throw .missingColumns(table: table, missing: missing)
        }
        let unexpected = actualColumns.filter { !expectedSet.contains($0) }
        if !unexpected.isEmpty {
            throw .unexpectedColumns(table: table, unexpected: unexpected)
        }
        if expectedColumns != actualColumns {
            throw .columnOrderMismatch(table: table, expected: expectedColumns, actual: actualColumns)
        }
    }
}
