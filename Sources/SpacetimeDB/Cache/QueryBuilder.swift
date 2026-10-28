import Foundation

/// A value that can be formatted as a safe SQL literal in a SpacetimeDB subscription query.
public protocol SpacetimeSQLValue: Sendable {
    var sqlLiteral: String { get }
}

extension String: SpacetimeSQLValue {
    public var sqlLiteral: String {
        let escaped = self.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }
}

extension Bool: SpacetimeSQLValue {
    public var sqlLiteral: String {
        self ? "true" : "false"
    }
}

extension Int: SpacetimeSQLValue { public var sqlLiteral: String { String(self) } }
extension Int8: SpacetimeSQLValue { public var sqlLiteral: String { String(self) } }
extension Int16: SpacetimeSQLValue { public var sqlLiteral: String { String(self) } }
extension Int32: SpacetimeSQLValue { public var sqlLiteral: String { String(self) } }
extension Int64: SpacetimeSQLValue { public var sqlLiteral: String { String(self) } }
extension UInt: SpacetimeSQLValue { public var sqlLiteral: String { String(self) } }
extension UInt8: SpacetimeSQLValue { public var sqlLiteral: String { String(self) } }
extension UInt16: SpacetimeSQLValue { public var sqlLiteral: String { String(self) } }
extension UInt32: SpacetimeSQLValue { public var sqlLiteral: String { String(self) } }
extension UInt64: SpacetimeSQLValue { public var sqlLiteral: String { String(self) } }

extension Float: SpacetimeSQLValue {
    public var sqlLiteral: String {
        isFinite ? String(self) : "0.0"
    }
}

extension Double: SpacetimeSQLValue {
    public var sqlLiteral: String {
        isFinite ? String(self) : "0.0"
    }
}

extension UInt128: SpacetimeSQLValue {
    public var sqlLiteral: String {
        String(self)
    }
}

extension Int128: SpacetimeSQLValue {
    public var sqlLiteral: String {
        String(self)
    }
}

/// Optional protocol that row models can conform to so `TableQuery<T>` can resolve Swift `PartialKeyPath<T>`
/// directly to database column names without requiring explicit column strings.
public protocol SpacetimeQueryableRow: Sendable {
    static var tableName: String { get }
    static func columnName(for keyPath: PartialKeyPath<Self>) -> String?
}

/// Represents a typed SQL `WHERE` predicate for a SpacetimeDB subscription query.
public struct SQLPredicate<Row>: Sendable {
    public let sql: String

    public init(rawSQL: String) {
        self.sql = rawSQL
    }

    public static func && (lhs: SQLPredicate<Row>, rhs: SQLPredicate<Row>) -> SQLPredicate<Row> {
        SQLPredicate(rawSQL: "(\(lhs.sql) AND \(rhs.sql))")
    }

    public static func || (lhs: SQLPredicate<Row>, rhs: SQLPredicate<Row>) -> SQLPredicate<Row> {
        SQLPredicate(rawSQL: "(\(lhs.sql) OR \(rhs.sql))")
    }

    public static prefix func ! (predicate: SQLPredicate<Row>) -> SQLPredicate<Row> {
        SQLPredicate(rawSQL: "NOT (\(predicate.sql))")
    }
}

/// Represents a typed SQL column reference on `Row`, constructible from a column name or a `KeyPath`.
public struct SQLColumn<Row, Value: SpacetimeSQLValue>: Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public init(_ keyPath: KeyPath<Row, Value>, columnName: String? = nil) {
        if let columnName {
            self.name = columnName
        } else if let queryableType = Row.self as? any SpacetimeQueryableRow.Type,
                  let resolved = Self.resolveColumn(keyPath: keyPath, queryableType: queryableType) {
            self.name = resolved
        } else {
            self.name = Self.fallbackColumnName(from: keyPath)
        }
    }

    private static func resolveColumn<Q: SpacetimeQueryableRow>(
        keyPath: AnyKeyPath,
        queryableType: Q.Type
    ) -> String? {
        guard let partial = keyPath as? PartialKeyPath<Q> else { return nil }
        return Q.columnName(for: partial)
    }

    static func fallbackColumnName(from keyPath: AnyKeyPath) -> String {
        let debug = String(describing: keyPath)
        if let dotIndex = debug.lastIndex(of: ".") {
            let prop = String(debug[debug.index(after: dotIndex)...])
            if !prop.isEmpty && prop != "<computed>" {
                return toSnakeCase(prop)
            }
        }
        return debug
    }

    static func toSnakeCase(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var result = ""
        result.reserveCapacity(input.count + 4)
        for (idx, char) in input.enumerated() {
            if char.isUppercase {
                if idx > 0 {
                    result.append("_")
                }
                result.append(char.lowercased())
            } else {
                result.append(char)
            }
        }
        return result
    }

    public func equals(_ value: Value) -> SQLPredicate<Row> {
        SQLPredicate(rawSQL: "\(name) = \(value.sqlLiteral)")
    }

    public func notEquals(_ value: Value) -> SQLPredicate<Row> {
        SQLPredicate(rawSQL: "\(name) != \(value.sqlLiteral)")
    }

    public func lessThan(_ value: Value) -> SQLPredicate<Row> {
        SQLPredicate(rawSQL: "\(name) < \(value.sqlLiteral)")
    }

    public func lessThanOrEqual(_ value: Value) -> SQLPredicate<Row> {
        SQLPredicate(rawSQL: "\(name) <= \(value.sqlLiteral)")
    }

    public func greaterThan(_ value: Value) -> SQLPredicate<Row> {
        SQLPredicate(rawSQL: "\(name) > \(value.sqlLiteral)")
    }

    public func greaterThanOrEqual(_ value: Value) -> SQLPredicate<Row> {
        SQLPredicate(rawSQL: "\(name) >= \(value.sqlLiteral)")
    }
}

public func == <Row, Value: SpacetimeSQLValue>(lhs: SQLColumn<Row, Value>, rhs: Value) -> SQLPredicate<Row> {
    lhs.equals(rhs)
}

public func != <Row, Value: SpacetimeSQLValue>(lhs: SQLColumn<Row, Value>, rhs: Value) -> SQLPredicate<Row> {
    lhs.notEquals(rhs)
}

public func < <Row, Value: SpacetimeSQLValue & Comparable>(lhs: SQLColumn<Row, Value>, rhs: Value) -> SQLPredicate<Row> {
    lhs.lessThan(rhs)
}

public func <= <Row, Value: SpacetimeSQLValue & Comparable>(lhs: SQLColumn<Row, Value>, rhs: Value) -> SQLPredicate<Row> {
    lhs.lessThanOrEqual(rhs)
}

public func > <Row, Value: SpacetimeSQLValue & Comparable>(lhs: SQLColumn<Row, Value>, rhs: Value) -> SQLPredicate<Row> {
    lhs.greaterThan(rhs)
}

public func >= <Row, Value: SpacetimeSQLValue & Comparable>(lhs: SQLColumn<Row, Value>, rhs: Value) -> SQLPredicate<Row> {
    lhs.greaterThanOrEqual(rhs)
}

/// A composable, type-safe SQL subscription query builder for a SpacetimeDB table `Row`.
public struct TableQuery<Row>: Sendable {
    public let tableName: String
    private var predicates: [SQLPredicate<Row>]

    public init(tableName: String) {
        self.tableName = tableName
        self.predicates = []
    }

    public init() where Row: SpacetimeQueryableRow {
        self.tableName = Row.tableName
        self.predicates = []
    }

    /// Adds a `WHERE` predicate to the query (combined with `AND` if predicates already exist).
    public func `where`(_ predicate: SQLPredicate<Row>) -> TableQuery<Row> {
        var copy = self
        copy.predicates.append(predicate)
        return copy
    }

    /// Adds an equality `WHERE` clause on `keyPath` (or explicit `column`).
    public func `where`<Value: SpacetimeSQLValue>(
        _ keyPath: KeyPath<Row, Value>,
        column: String? = nil,
        equals value: Value
    ) -> TableQuery<Row> {
        self.where(SQLColumn<Row, Value>(keyPath, columnName: column).equals(value))
    }

    /// Adds an inequality `WHERE` clause on `keyPath` (or explicit `column`).
    public func `where`<Value: SpacetimeSQLValue>(
        _ keyPath: KeyPath<Row, Value>,
        column: String? = nil,
        notEquals value: Value
    ) -> TableQuery<Row> {
        self.where(SQLColumn<Row, Value>(keyPath, columnName: column).notEquals(value))
    }

    /// Adds a `<` `WHERE` clause on `keyPath` (or explicit `column`).
    public func `where`<Value: SpacetimeSQLValue & Comparable>(
        _ keyPath: KeyPath<Row, Value>,
        column: String? = nil,
        lessThan value: Value
    ) -> TableQuery<Row> {
        self.where(SQLColumn<Row, Value>(keyPath, columnName: column).lessThan(value))
    }

    /// Adds a `<=` `WHERE` clause on `keyPath` (or explicit `column`).
    public func `where`<Value: SpacetimeSQLValue & Comparable>(
        _ keyPath: KeyPath<Row, Value>,
        column: String? = nil,
        lessThanOrEqual value: Value
    ) -> TableQuery<Row> {
        self.where(SQLColumn<Row, Value>(keyPath, columnName: column).lessThanOrEqual(value))
    }

    /// Adds a `>` `WHERE` clause on `keyPath` (or explicit `column`).
    public func `where`<Value: SpacetimeSQLValue & Comparable>(
        _ keyPath: KeyPath<Row, Value>,
        column: String? = nil,
        greaterThan value: Value
    ) -> TableQuery<Row> {
        self.where(SQLColumn<Row, Value>(keyPath, columnName: column).greaterThan(value))
    }

    /// Adds a `>=` `WHERE` clause on `keyPath` (or explicit `column`).
    public func `where`<Value: SpacetimeSQLValue & Comparable>(
        _ keyPath: KeyPath<Row, Value>,
        column: String? = nil,
        greaterThanOrEqual value: Value
    ) -> TableQuery<Row> {
        self.where(SQLColumn<Row, Value>(keyPath, columnName: column).greaterThanOrEqual(value))
    }

    /// Renders the SQL `SELECT * FROM ...` string for SpacetimeDB subscriptions.
    public var sql: String {
        guard !predicates.isEmpty else {
            return "SELECT * FROM \(tableName)"
        }
        let whereClause = predicates.map(\.sql).joined(separator: " AND ")
        return "SELECT * FROM \(tableName) WHERE \(whereClause)"
    }
}
