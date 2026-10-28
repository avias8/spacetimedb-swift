import Foundation
import Synchronization

/// Protocol for SpacetimeDB row models that expose a primary key.
///
/// Conforming row types enable primary-key aware update pairing in `TableCache<T>`,
/// ensuring `onUpdate(oldRow, newRow)` fires cleanly even when multiple rows update
/// in the same transaction or during reconnect subscription reconciliation.
public protocol SpacetimePrimaryKeyRow: Sendable {
    associatedtype PrimaryKey: Hashable & Sendable
    var primaryKey: PrimaryKey { get }
}

/// Internal protocol allowing `TableCache<T>` to maintain secondary indexes synchronously as rows change.
protocol TableSecondaryIndex: AnyObject, Sendable {
    associatedtype Row
    func insert(_ row: Row, key: HashedBytes)
    func remove(_ row: Row, key: HashedBytes)
    func update(oldRow: Row, oldKey: HashedBytes, newRow: Row, newKey: HashedBytes)
    func clear()
    func rebuild(from entries: [HashedBytes: RowEntry<Row>])
}

/// Type-erased wrapper so `TableCache<T>` can store heterogeneous `UniqueIndex<T, K>` and `BTreeIndex<T, K>` instances.
final class AnyTableSecondaryIndex<T>: Sendable {
    private let _insert: @Sendable (T, HashedBytes) -> Void
    private let _remove: @Sendable (T, HashedBytes) -> Void
    private let _update: @Sendable (T, HashedBytes, T, HashedBytes) -> Void
    private let _clear: @Sendable () -> Void
    private let _rebuild: @Sendable ([HashedBytes: RowEntry<T>]) -> Void

    init<I: TableSecondaryIndex>(_ index: I) where I.Row == T {
        self._insert = { row, key in index.insert(row, key: key) }
        self._remove = { row, key in index.remove(row, key: key) }
        self._update = { oldRow, oldKey, newRow, newKey in
            index.update(oldRow: oldRow, oldKey: oldKey, newRow: newRow, newKey: newKey)
        }
        self._clear = { index.clear() }
        self._rebuild = { entries in index.rebuild(from: entries) }
    }

    func insert(_ row: T, key: HashedBytes) {
        _insert(row, key)
    }

    func remove(_ row: T, key: HashedBytes) {
        _remove(row, key)
    }

    func update(oldRow: T, oldKey: HashedBytes, newRow: T, newKey: HashedBytes) {
        _update(oldRow, oldKey, newRow, newKey)
    }

    func clear() {
        _clear()
    }

    func rebuild(from entries: [HashedBytes: RowEntry<T>]) {
        _rebuild(entries)
    }
}

/// Thread-safe $O(1)$ unique key index attached to a `TableCache<T>`.
public final class UniqueIndex<T: Sendable, Key: Hashable & Sendable>: TableSecondaryIndex, Sendable {
    public typealias Row = T

    private let extractKey: @Sendable (T) -> Key
    private let storage: Mutex<[Key: (hashedBytes: HashedBytes, row: T)]> = Mutex([:])

    public init(keyPath: KeyPath<T, Key> & Sendable) {
        self.extractKey = { row in row[keyPath: keyPath] }
    }

    public init(extractKey: @escaping @Sendable (T) -> Key) {
        self.extractKey = extractKey
    }

    /// Looks up the row matching `key` in $O(1)$ time.
    public func find(_ key: Key) -> T? {
        storage.withLock { $0[key]?.row }
    }

    /// Returns whether a row with `key` is currently present in the index.
    public func contains(_ key: Key) -> Bool {
        storage.withLock { $0[key] != nil }
    }

    /// All indexed keys currently in the cache.
    public var keys: [Key] {
        storage.withLock { Array($0.keys) }
    }

    func insert(_ row: T, key: HashedBytes) {
        let indexKey = extractKey(row)
        storage.withLock { map in
            map[indexKey] = (hashedBytes: key, row: row)
        }
    }

    func remove(_ row: T, key: HashedBytes) {
        let indexKey = extractKey(row)
        storage.withLock { map in
            if let existing = map[indexKey], existing.hashedBytes == key {
                map.removeValue(forKey: indexKey)
            }
        }
    }

    func update(oldRow: T, oldKey: HashedBytes, newRow: T, newKey: HashedBytes) {
        let oldIndexKey = extractKey(oldRow)
        let newIndexKey = extractKey(newRow)
        storage.withLock { map in
            if oldIndexKey != newIndexKey, let existing = map[oldIndexKey], existing.hashedBytes == oldKey {
                map.removeValue(forKey: oldIndexKey)
            }
            map[newIndexKey] = (hashedBytes: newKey, row: newRow)
        }
    }

    func clear() {
        storage.withLock { $0.removeAll(keepingCapacity: true) }
    }

    func rebuild(from entries: [HashedBytes: RowEntry<T>]) {
        storage.withLock { map in
            map.removeAll(keepingCapacity: true)
            map.reserveCapacity(entries.count)
            for (hashedBytes, entry) in entries where entry.count > 0 {
                let indexKey = extractKey(entry.value)
                map[indexKey] = (hashedBytes: hashedBytes, row: entry.value)
            }
        }
    }
}

/// Thread-safe sorted index attached to a `TableCache<T>` supporting $O(1)$ equality and $O(\log N + K)$ range queries.
public final class BTreeIndex<T: Sendable, Key: Comparable & Hashable & Sendable>: TableSecondaryIndex, Sendable {
    public typealias Row = T

    private struct State {
        var sortedKeys: [Key] = []
        var buckets: [Key: [HashedBytes: T]] = [:]
    }

    private let extractKey: @Sendable (T) -> Key
    private let state: Mutex<State> = Mutex(State())

    public init(keyPath: KeyPath<T, Key> & Sendable) {
        self.extractKey = { row in row[keyPath: keyPath] }
    }

    public init(extractKey: @escaping @Sendable (T) -> Key) {
        self.extractKey = extractKey
    }

    /// Returns all rows whose indexed key equals `key`.
    public func filter(equal key: Key) -> [T] {
        state.withLock { state in
            guard let bucket = state.buckets[key] else { return [] }
            return Array(bucket.values)
        }
    }

    /// Returns all rows whose indexed key falls within `range` in ascending key order.
    public func filter(range: ClosedRange<Key>) -> [T] {
        state.withLock { state in
            let lower = Self.lowerBound(for: range.lowerBound, in: state.sortedKeys)
            let upper = Self.upperBound(for: range.upperBound, in: state.sortedKeys)
            guard lower < upper else { return [] }
            var results: [T] = []
            for idx in lower..<upper {
                let k = state.sortedKeys[idx]
                if let bucket = state.buckets[k] {
                    results.append(contentsOf: bucket.values)
                }
            }
            return results
        }
    }

    /// Returns all rows whose indexed key falls within `range` in ascending key order.
    public func filter(range: Range<Key>) -> [T] {
        guard !range.isEmpty else { return [] }
        return state.withLock { state in
            let lower = Self.lowerBound(for: range.lowerBound, in: state.sortedKeys)
            let upper = Self.lowerBound(for: range.upperBound, in: state.sortedKeys)
            guard lower < upper else { return [] }
            var results: [T] = []
            for idx in lower..<upper {
                let k = state.sortedKeys[idx]
                if let bucket = state.buckets[k] {
                    results.append(contentsOf: bucket.values)
                }
            }
            return results
        }
    }

    /// Returns all rows whose indexed key falls within `range` (`key >= lowerBound`) in ascending key order.
    public func filter(range: PartialRangeFrom<Key>) -> [T] {
        state.withLock { state in
            let lower = Self.lowerBound(for: range.lowerBound, in: state.sortedKeys)
            guard lower < state.sortedKeys.count else { return [] }
            var results: [T] = []
            for idx in lower..<state.sortedKeys.count {
                let k = state.sortedKeys[idx]
                if let bucket = state.buckets[k] {
                    results.append(contentsOf: bucket.values)
                }
            }
            return results
        }
    }

    /// Returns all rows whose indexed key falls within `range` (`key <= upperBound`) in ascending key order.
    public func filter(range: PartialRangeThrough<Key>) -> [T] {
        state.withLock { state in
            let upper = Self.upperBound(for: range.upperBound, in: state.sortedKeys)
            guard upper > 0 else { return [] }
            var results: [T] = []
            for idx in 0..<upper {
                let k = state.sortedKeys[idx]
                if let bucket = state.buckets[k] {
                    results.append(contentsOf: bucket.values)
                }
            }
            return results
        }
    }

    /// Returns all rows whose indexed key falls within `range` (`key < upperBound`) in ascending key order.
    public func filter(range: PartialRangeUpTo<Key>) -> [T] {
        state.withLock { state in
            let upper = Self.lowerBound(for: range.upperBound, in: state.sortedKeys)
            guard upper > 0 else { return [] }
            var results: [T] = []
            for idx in 0..<upper {
                let k = state.sortedKeys[idx]
                if let bucket = state.buckets[k] {
                    results.append(contentsOf: bucket.values)
                }
            }
            return results
        }
    }

    func insert(_ row: T, key: HashedBytes) {
        let indexKey = extractKey(row)
        state.withLock { state in
            Self.insertRow(row, hashedBytes: key, indexKey: indexKey, into: &state)
        }
    }

    func remove(_ row: T, key: HashedBytes) {
        let indexKey = extractKey(row)
        state.withLock { state in
            Self.removeRow(hashedBytes: key, indexKey: indexKey, from: &state)
        }
    }

    func update(oldRow: T, oldKey: HashedBytes, newRow: T, newKey: HashedBytes) {
        let oldIndexKey = extractKey(oldRow)
        let newIndexKey = extractKey(newRow)
        state.withLock { state in
            Self.removeRow(hashedBytes: oldKey, indexKey: oldIndexKey, from: &state)
            Self.insertRow(newRow, hashedBytes: newKey, indexKey: newIndexKey, into: &state)
        }
    }

    func clear() {
        state.withLock { state in
            state.sortedKeys.removeAll(keepingCapacity: true)
            state.buckets.removeAll(keepingCapacity: true)
        }
    }

    func rebuild(from entries: [HashedBytes: RowEntry<T>]) {
        state.withLock { state in
            state.sortedKeys.removeAll(keepingCapacity: true)
            state.buckets.removeAll(keepingCapacity: true)
            for (hashedBytes, entry) in entries where entry.count > 0 {
                let indexKey = extractKey(entry.value)
                state.buckets[indexKey, default: [:]][hashedBytes] = entry.value
            }
            state.sortedKeys = state.buckets.keys.sorted()
        }
    }

    private static func insertRow(_ row: T, hashedBytes: HashedBytes, indexKey: Key, into state: inout State) {
        if state.buckets[indexKey] != nil {
            state.buckets[indexKey]?[hashedBytes] = row
        } else {
            state.buckets[indexKey] = [hashedBytes: row]
            let insertIdx = lowerBound(for: indexKey, in: state.sortedKeys)
            state.sortedKeys.insert(indexKey, at: insertIdx)
        }
    }

    private static func removeRow(hashedBytes: HashedBytes, indexKey: Key, from state: inout State) {
        guard var bucket = state.buckets[indexKey] else { return }
        bucket.removeValue(forKey: hashedBytes)
        if bucket.isEmpty {
            state.buckets.removeValue(forKey: indexKey)
            let idx = lowerBound(for: indexKey, in: state.sortedKeys)
            if idx < state.sortedKeys.count && state.sortedKeys[idx] == indexKey {
                state.sortedKeys.remove(at: idx)
            }
        } else {
            state.buckets[indexKey] = bucket
        }
    }

    /// First index where `sortedKeys[index] >= target`.
    private static func lowerBound(for target: Key, in sortedKeys: [Key]) -> Int {
        var low = 0
        var high = sortedKeys.count
        while low < high {
            let mid = low + (high - low) / 2
            if sortedKeys[mid] < target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// First index where `sortedKeys[index] > target`.
    private static func upperBound(for target: Key, in sortedKeys: [Key]) -> Int {
        var low = 0
        var high = sortedKeys.count
        while low < high {
            let mid = low + (high - low) / 2
            if sortedKeys[mid] <= target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
