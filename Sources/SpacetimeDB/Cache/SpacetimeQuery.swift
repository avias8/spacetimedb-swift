import Foundation
import Observation

#if canImport(SwiftUI)
import SwiftUI

/// A SwiftUI `DynamicProperty` wrapper that observes a SpacetimeDB `TableCache<T>` and optionally
/// filters and sorts its rows for declarative view rendering.
@MainActor
@propertyWrapper
public struct SpacetimeQuery<T: Decodable & Sendable>: DynamicProperty {
    private let tableCache: TableCache<T>
    private let filterPredicate: (@Sendable (T) -> Bool)?
    private let sortComparator: (@Sendable (T, T) -> Bool)?

    public init(
        tableName: String,
        in cache: ClientCache = SpacetimeClient.clientCache,
        filter: (@Sendable (T) -> Bool)? = nil,
        sort: (@Sendable (T, T) -> Bool)? = nil
    ) {
        self.tableCache = cache.getTableCache(tableName: tableName)
        self.filterPredicate = filter
        self.sortComparator = sort
    }

    public init(
        tableCache: TableCache<T>,
        filter: (@Sendable (T) -> Bool)? = nil,
        sort: (@Sendable (T, T) -> Bool)? = nil
    ) {
        self.tableCache = tableCache
        self.filterPredicate = filter
        self.sortComparator = sort
    }

    public var wrappedValue: [T] {
        var result = tableCache.rows
        if let filterPredicate {
            result = result.filter(filterPredicate)
        }
        if let sortComparator {
            result.sort(by: sortComparator)
        }
        return result
    }

    public var projectedValue: TableCache<T> {
        tableCache
    }
}
#endif
