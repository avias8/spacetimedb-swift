import Foundation
import Observation
import Synchronization

public protocol SpacetimeTableCacheProtocol: AnyObject, Sendable {
    var tableName: String { get }
    func handleInsert(rowBytes: Data) throws
    func handleDelete(rowBytes: Data) throws
    func handleUpdate(oldRowBytes: Data, newRowBytes: Data) throws
    func handleBulkInsert(rowBytesList: [Data]) throws
    func handleBulkDelete(rowBytesList: [Data]) throws
    func handleBulkUpdate(oldRowBytesList: [Data], newRowBytesList: [Data]) throws
    func applyQuerySetTransition(querySetId: QuerySetId?, deleteRowBytesList: [Data], insertRowBytesList: [Data]) throws
    @discardableResult
    func reconcile(rowBytesList: [Data]) throws -> Bool
    @discardableResult
    func reconcile(querySets: [(querySetId: QuerySetId?, rowBytesList: [Data])]) throws -> Bool
    @discardableResult
    func evictQuerySet(_ querySetId: QuerySetId) -> Bool
    func clear()
    func snapshotRowBytesList() -> [Data]
    func restoreSnapshot(rowBytesList: [Data]) throws
}

public extension SpacetimeTableCacheProtocol {
    func applyQuerySetTransition(querySetId: QuerySetId?, deleteRowBytesList: [Data], insertRowBytesList: [Data]) throws {
        let pairedCount = min(deleteRowBytesList.count, insertRowBytesList.count)
        if pairedCount > 0 {
            try handleBulkUpdate(
                oldRowBytesList: Array(deleteRowBytesList[..<pairedCount]),
                newRowBytesList: Array(insertRowBytesList[..<pairedCount])
            )
        }
        if deleteRowBytesList.count > pairedCount {
            try handleBulkDelete(rowBytesList: Array(deleteRowBytesList[pairedCount...]))
        }
        if insertRowBytesList.count > pairedCount {
            try handleBulkInsert(rowBytesList: Array(insertRowBytesList[pairedCount...]))
        }
    }

    @discardableResult
    func reconcile(querySets: [(querySetId: QuerySetId?, rowBytesList: [Data])]) throws -> Bool {
        let combined = querySets.flatMap(\.rowBytesList)
        return try reconcile(rowBytesList: combined)
    }

    @discardableResult
    func evictQuerySet(_ querySetId: QuerySetId) -> Bool {
        false
    }

    func snapshotRowBytesList() -> [Data] {
        []
    }

    func restoreSnapshot(rowBytesList: [Data]) throws {
        clear()
        try handleBulkInsert(rowBytesList: rowBytesList)
    }
}

public final class TableDeltaHandle: Sendable {
    private let cancelAction: @Sendable () -> Void
    private let cancelledState: Mutex<Bool> = Mutex(false)

    init(cancelAction: @escaping @Sendable () -> Void) {
        self.cancelAction = cancelAction
    }

    public func cancel() {
        let shouldCancel = cancelledState.withLock { isCancelled in
            guard !isCancelled else { return false }
            isCancelled = true
            return true
        }

        if shouldCancel {
            cancelAction()
        }
    }
}

// MARK: - HashedBytes

/// A Data wrapper that pre-computes its hash on construction.
/// Dictionary lookups hash 8 bytes (the cached Int) instead of N row bytes.
struct HashedBytes: Hashable, Sendable {
    let data: Data
    private let _hash: Int

    init(_ data: Data) {
        self.data = data
        self._hash = data.hashValue // Native SipHash, much faster
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(_hash)
    }

    static func == (lhs: HashedBytes, rhs: HashedBytes) -> Bool {
        lhs._hash == rhs._hash && lhs.data == rhs.data
    }
}

// MARK: - RowEntry

/// Merged storage: count + decoded value in a single dictionary entry.
/// Eliminates the second dictionary lookup per insert/delete.
struct RowEntry<T> {
    var count: Int
    var value: T
}

// MARK: - TableCache

/// A reactive, thread-safe cache containing the local replica array of persistent rows for a given SpacetimeDB table
@Observable
public final class TableCache<T: Decodable & Sendable>: SpacetimeTableCacheProtocol, Sendable {
    public let tableName: String

    // For SwiftUI observability via @Observable
    // This is only updated on the MainActor when requested or via sync()
    @MainActor
    public private(set) var rows: [T] = []

    private struct PrimaryKeyBox: Hashable, @unchecked Sendable {
        let base: AnyHashable

        init(_ base: AnyHashable) {
            self.base = base
        }
    }

    // All internal state is @ObservationIgnored to prevent the @Observable macro
    // from intercepting every dictionary mutation with willSet/didSet tracking.
    // Only `rows` is observed for SwiftUI reactivity.
    @ObservationIgnored private let decodeRow: @Sendable (Data) throws -> T
    @ObservationIgnored private let extractPrimaryKey: (@Sendable (T) -> PrimaryKeyBox)?
    @ObservationIgnored private let state: Mutex<State> = Mutex(State())

    private struct PendingRow {
        let bytes: Data
        let value: T
    }

    private struct TransitionCallbacks {
        var deletedRows: [T] = []
        var deleteCallbacks: [@Sendable (T) -> Void] = []
        var updatedRows: [(oldRow: T, newRow: T)] = []
        var updateCallbacks: [@Sendable (T, T) -> Void] = []
        var insertedRows: [T] = []
        var insertCallbacks: [@Sendable (T) -> Void] = []
    }

    private struct State {
        var entries: [HashedBytes: RowEntry<T>] = [:]
        var primaryKeyToBytes: [PrimaryKeyBox: HashedBytes] = [:]
        var querySetCounts: [QuerySetId: [HashedBytes: Int]] = [:]
        var secondaryIndexes: [AnyTableSecondaryIndex<T>] = []
        var pendingRows: [PendingRow] = []
        var entriesAreMaterialized = false
        var insertCallbacks: [UUID: @Sendable (T) -> Void] = [:]
        var deleteCallbacks: [UUID: @Sendable (T) -> Void] = [:]
        var updateCallbacks: [UUID: @Sendable (T, T) -> Void] = [:]
    }

    private init(
        tableName: String,
        decodeRow: @escaping @Sendable (Data) throws -> T,
        extractPrimaryKey: (@Sendable (T) -> PrimaryKeyBox)? = nil
    ) {
        self.tableName = tableName
        self.decodeRow = decodeRow
        self.extractPrimaryKey = extractPrimaryKey
    }

    public convenience init(tableName: String) {
        let pkExtractor = Self.defaultPrimaryKeyExtractor()
        if let specialType = T.self as? BSATNSpecialDecodable.Type {
            self.init(
                tableName: tableName,
                decodeRow: { data in
                    try data.withUnsafeBytes { buffer in
                        var reader = BSATNReader(buffer: buffer)
                        return try specialType.decodeBSATN(from: &reader) as! T
                    }
                },
                extractPrimaryKey: pkExtractor
            )
        } else {
            let decoder = BSATNDecoder()
            self.init(
                tableName: tableName,
                decodeRow: { data in
                    try decoder.decode(T.self, from: data)
                },
                extractPrimaryKey: pkExtractor
            )
        }
    }

    public convenience init(tableName: String) where T: BSATNSpecialDecodable {
        let pkExtractor = Self.defaultPrimaryKeyExtractor()
        self.init(
            tableName: tableName,
            decodeRow: { data in
                try data.withUnsafeBytes { buffer in
                    var reader = BSATNReader(buffer: buffer)
                    return try T.decodeBSATN(from: &reader)
                }
            },
            extractPrimaryKey: pkExtractor
        )
    }

    private static func defaultPrimaryKeyExtractor() -> (@Sendable (T) -> PrimaryKeyBox)? {
        guard T.self is any SpacetimePrimaryKeyRow.Type else {
            return nil
        }
        return { row in
            func openPK<R: SpacetimePrimaryKeyRow>(_ r: R) -> PrimaryKeyBox {
                PrimaryKeyBox(AnyHashable(r.primaryKey))
            }
            let pkRow = row as! any SpacetimePrimaryKeyRow
            return _openExistential(pkRow, do: openPK)
        }
    }

    // MARK: - Secondary Indexes

    /// Creates and registers an $O(1)$ unique key index on `keyPath`, populated with any rows already in the cache.
    public func createUniqueIndex<Key: Hashable & Sendable>(
        keyPath: KeyPath<T, Key> & Sendable
    ) -> UniqueIndex<T, Key> {
        let index = UniqueIndex<T, Key>(keyPath: keyPath)
        registerSecondaryIndex(index)
        return index
    }

    /// Creates and registers an $O(1)$ unique key index using `extractKey`, populated with any rows already in the cache.
    public func createUniqueIndex<Key: Hashable & Sendable>(
        extractKey: @escaping @Sendable (T) -> Key
    ) -> UniqueIndex<T, Key> {
        let index = UniqueIndex<T, Key>(extractKey: extractKey)
        registerSecondaryIndex(index)
        return index
    }

    /// Creates and registers a sorted B-Tree index on `keyPath`, populated with any rows already in the cache.
    public func createBTreeIndex<Key: Comparable & Hashable & Sendable>(
        keyPath: KeyPath<T, Key> & Sendable
    ) -> BTreeIndex<T, Key> {
        let index = BTreeIndex<T, Key>(keyPath: keyPath)
        registerSecondaryIndex(index)
        return index
    }

    /// Creates and registers a sorted B-Tree index using `extractKey`, populated with any rows already in the cache.
    public func createBTreeIndex<Key: Comparable & Hashable & Sendable>(
        extractKey: @escaping @Sendable (T) -> Key
    ) -> BTreeIndex<T, Key> {
        let index = BTreeIndex<T, Key>(extractKey: extractKey)
        registerSecondaryIndex(index)
        return index
    }

    private func registerSecondaryIndex<I: TableSecondaryIndex>(_ index: I) where I.Row == T {
        let wrapper = AnyTableSecondaryIndex(index)
        state.withLock { state in
            materializeEntries(in: &state)
            wrapper.rebuild(from: state.entries)
            state.secondaryIndexes.append(wrapper)
        }
    }

    /// Looks up a row by its primary key in $O(1)$ time when `T` conforms to `SpacetimePrimaryKeyRow`.
    public func find(byPrimaryKey primaryKey: T.PrimaryKey) -> T? where T: SpacetimePrimaryKeyRow {
        let key = PrimaryKeyBox(AnyHashable(primaryKey))
        return state.withLock { state in
            materializeEntries(in: &state)
            guard let hashedBytes = state.primaryKeyToBytes[key],
                  let entry = state.entries[hashedBytes],
                  entry.count > 0 else {
                return nil
            }
            return entry.value
        }
    }

    // MARK: - Internal Helpers

    @inline(__always)
    private func insertEntry(
        _ row: T,
        for key: HashedBytes,
        into state: inout State
    ) -> (value: T, isNew: Bool) {
        if var existing = state.entries[key] {
            existing.count += 1
            state.entries[key] = existing
            return (existing.value, false)
        }
        state.entries[key] = RowEntry(count: 1, value: row)
        if let extractPrimaryKey {
            state.primaryKeyToBytes[extractPrimaryKey(row)] = key
        }
        for idx in state.secondaryIndexes {
            idx.insert(row, key: key)
        }
        return (row, true)
    }

    @inline(__always)
    private func incrementQuerySetCount(_ querySetId: QuerySetId?, key: HashedBytes, in state: inout State) {
        guard let querySetId else { return }
        state.querySetCounts[querySetId, default: [:]][key, default: 0] += 1
    }

    @inline(__always)
    private func decrementQuerySetCount(_ querySetId: QuerySetId?, key: HashedBytes, in state: inout State) {
        guard let querySetId, var map = state.querySetCounts[querySetId], let current = map[key] else { return }
        if current <= 1 {
            map.removeValue(forKey: key)
        } else {
            map[key] = current - 1
        }
        if map.isEmpty {
            state.querySetCounts.removeValue(forKey: querySetId)
        } else {
            state.querySetCounts[querySetId] = map
        }
    }

    @inline(__always)
    private func materializeEntries(in state: inout State) {
        guard !state.entriesAreMaterialized else { return }

        state.entries.reserveCapacity(state.entries.count + state.pendingRows.count)
        for pending in state.pendingRows {
            _ = insertEntry(pending.value, for: HashedBytes(pending.bytes), into: &state)
        }
        state.pendingRows.removeAll(keepingCapacity: true)
        state.entriesAreMaterialized = true
    }

    private func rebuildDerivedIndexes(in state: inout State) {
        if let extractPrimaryKey {
            state.primaryKeyToBytes.removeAll(keepingCapacity: true)
            state.primaryKeyToBytes.reserveCapacity(state.entries.count)
            for (key, entry) in state.entries where entry.count > 0 {
                state.primaryKeyToBytes[extractPrimaryKey(entry.value)] = key
            }
        }
        for idx in state.secondaryIndexes {
            idx.rebuild(from: state.entries)
        }
    }

    // MARK: - Mutation Operations

    public func handleInsert(rowBytes: Data) throws {
        let decodedRow: T
        do {
            decodedRow = try decodeRow(rowBytes)
        } catch {
            Log.cache.error("Failed to decode row for table '\(self.tableName)': \(error.localizedDescription)")
            throw error
        }

        let delivery = state.withLock { state -> (row: T, callbacks: [@Sendable (T) -> Void])? in
            if state.insertCallbacks.isEmpty && state.secondaryIndexes.isEmpty && extractPrimaryKey == nil {
                if state.entriesAreMaterialized {
                    _ = insertEntry(decodedRow, for: HashedBytes(rowBytes), into: &state)
                } else {
                    state.pendingRows.append(PendingRow(bytes: rowBytes, value: decodedRow))
                }
                return nil
            }

            materializeEntries(in: &state)
            let (storedRow, isNew) = insertEntry(decodedRow, for: HashedBytes(rowBytes), into: &state)
            guard isNew, !state.insertCallbacks.isEmpty else { return nil }
            return (row: storedRow, callbacks: Array(state.insertCallbacks.values))
        }

        guard let delivery else { return }
        for callback in delivery.callbacks {
            callback(delivery.row)
        }
    }

    public func handleDelete(rowBytes: Data) throws {
        let key = HashedBytes(rowBytes)
        let rowAndCallbacks = state.withLock { state -> (row: T, callbacks: [@Sendable (T) -> Void])? in
            materializeEntries(in: &state)
            guard let index = state.entries.index(forKey: key) else {
                return nil
            }
            let deletedRow = state.entries.values[index].value
            if state.entries.values[index].count <= 1 {
                state.entries.remove(at: index)
                if let extractPrimaryKey {
                    let pk = extractPrimaryKey(deletedRow)
                    if state.primaryKeyToBytes[pk] == key {
                        state.primaryKeyToBytes.removeValue(forKey: pk)
                    }
                }
                for idx in state.secondaryIndexes {
                    idx.remove(deletedRow, key: key)
                }
                guard !state.deleteCallbacks.isEmpty else { return nil }
                return (row: deletedRow, callbacks: Array(state.deleteCallbacks.values))
            } else {
                state.entries.values[index].count -= 1
                return nil
            }
        }

        guard let rowAndCallbacks else {
            return
        }

        for callback in rowAndCallbacks.callbacks {
            callback(rowAndCallbacks.row)
        }
    }

    public func handleUpdate(oldRowBytes: Data, newRowBytes: Data) throws {
        let oldKey = HashedBytes(oldRowBytes)
        let newKey = HashedBytes(newRowBytes)
        let rowAndCallbacks: (oldRow: T, newRow: T, callbacks: [@Sendable (T, T) -> Void])?
        do {
            rowAndCallbacks = try state.withLock { state in
                materializeEntries(in: &state)
                guard let oldIndex = state.entries.index(forKey: oldKey) else {
                    return nil
                }

                let oldRow = state.entries.values[oldIndex].value
                let newRow: T
                let isNewInsert: Bool

                if let newIndex = state.entries.index(forKey: newKey) {
                    state.entries.values[newIndex].count += 1
                    newRow = state.entries.values[newIndex].value
                    isNewInsert = false
                } else {
                    newRow = try decodeRow(newRowBytes)
                    state.entries[newKey] = RowEntry(count: 1, value: newRow)
                    isNewInsert = true
                }

                var oldRemoved = false
                if let finalOldIndex = state.entries.index(forKey: oldKey) {
                    if state.entries.values[finalOldIndex].count <= 1 {
                        state.entries.remove(at: finalOldIndex)
                        oldRemoved = true
                    } else {
                        state.entries.values[finalOldIndex].count -= 1
                    }
                }

                if let extractPrimaryKey {
                    if oldRemoved {
                        let oldPK = extractPrimaryKey(oldRow)
                        if state.primaryKeyToBytes[oldPK] == oldKey {
                            state.primaryKeyToBytes.removeValue(forKey: oldPK)
                        }
                    }
                    state.primaryKeyToBytes[extractPrimaryKey(newRow)] = newKey
                }

                if oldRemoved && isNewInsert {
                    for idx in state.secondaryIndexes {
                        idx.update(oldRow: oldRow, oldKey: oldKey, newRow: newRow, newKey: newKey)
                    }
                } else {
                    if oldRemoved {
                        for idx in state.secondaryIndexes {
                            idx.remove(oldRow, key: oldKey)
                        }
                    }
                    if isNewInsert {
                        for idx in state.secondaryIndexes {
                            idx.insert(newRow, key: newKey)
                        }
                    }
                }

                return (oldRow: oldRow, newRow: newRow, callbacks: Array(state.updateCallbacks.values))
            }
        } catch {
            Log.cache.error("Failed to decode row for table '\(self.tableName)': \(error.localizedDescription)")
            throw error
        }

        guard let rowAndCallbacks else {
            try handleInsert(rowBytes: newRowBytes)
            return
        }

        for callback in rowAndCallbacks.callbacks {
            callback(rowAndCallbacks.oldRow, rowAndCallbacks.newRow)
        }
    }

    public func handleBulkInsert(rowBytesList: [Data]) throws {
        if rowBytesList.isEmpty { return }

        let delivery: (rows: [T], callbacks: [@Sendable (T) -> Void])?
        do {
            delivery = try state.withLock { state in
                if state.entriesAreMaterialized {
                    state.entries.reserveCapacity(state.entries.count + rowBytesList.count)
                } else {
                    state.pendingRows.reserveCapacity(state.pendingRows.count + rowBytesList.count)
                }

                if state.insertCallbacks.isEmpty && state.secondaryIndexes.isEmpty && extractPrimaryKey == nil {
                    for rowBytes in rowBytesList {
                        let row = try decodeRow(rowBytes)
                        if state.entriesAreMaterialized {
                            _ = insertEntry(row, for: HashedBytes(rowBytes), into: &state)
                        } else {
                            state.pendingRows.append(PendingRow(bytes: rowBytes, value: row))
                        }
                    }
                    return nil
                }

                materializeEntries(in: &state)
                var storedRows: [T] = []
                if !state.insertCallbacks.isEmpty {
                    storedRows.reserveCapacity(rowBytesList.count)
                }
                for rowBytes in rowBytesList {
                    let row = try decodeRow(rowBytes)
                    let (storedRow, isNew) = insertEntry(row, for: HashedBytes(rowBytes), into: &state)
                    if isNew && !state.insertCallbacks.isEmpty {
                        storedRows.append(storedRow)
                    }
                }
                guard !storedRows.isEmpty else { return nil }
                return (rows: storedRows, callbacks: Array(state.insertCallbacks.values))
            }
        } catch {
            Log.cache.error("Failed to decode row for table '\(self.tableName)': \(error.localizedDescription)")
            throw error
        }

        guard let delivery else { return }
        for row in delivery.rows {
            for callback in delivery.callbacks {
                callback(row)
            }
        }
    }

    public func handleBulkDelete(rowBytesList: [Data]) throws {
        if rowBytesList.isEmpty { return }

        let rowsAndCallbacks: [(row: T, callbacks: [@Sendable (T) -> Void])] = state.withLock { state in
            materializeEntries(in: &state)
            var results: [(row: T, callbacks: [@Sendable (T) -> Void])] = []
            results.reserveCapacity(rowBytesList.count)
            let callbacks = Array(state.deleteCallbacks.values)

            for rowBytes in rowBytesList {
                let key = HashedBytes(rowBytes)
                if let index = state.entries.index(forKey: key) {
                    let deletedRow = state.entries.values[index].value
                    if state.entries.values[index].count <= 1 {
                        state.entries.remove(at: index)
                        if let extractPrimaryKey {
                            let pk = extractPrimaryKey(deletedRow)
                            if state.primaryKeyToBytes[pk] == key {
                                state.primaryKeyToBytes.removeValue(forKey: pk)
                            }
                        }
                        for idx in state.secondaryIndexes {
                            idx.remove(deletedRow, key: key)
                        }
                        if !callbacks.isEmpty {
                            results.append((row: deletedRow, callbacks: callbacks))
                        }
                    } else {
                        state.entries.values[index].count -= 1
                    }
                }
            }
            return results
        }

        for item in rowsAndCallbacks {
            for callback in item.callbacks {
                callback(item.row)
            }
        }
    }

    public func handleBulkUpdate(oldRowBytesList: [Data], newRowBytesList: [Data]) throws {
        try applyQuerySetTransition(
            querySetId: nil,
            deleteRowBytesList: oldRowBytesList,
            insertRowBytesList: newRowBytesList
        )
    }

    /// Applies a batch of deletes and inserts for a given `QuerySetId`, pairing updates by primary key
    /// when `T` conforms to `SpacetimePrimaryKeyRow` (or positionally otherwise).
    public func applyQuerySetTransition(
        querySetId: QuerySetId?,
        deleteRowBytesList: [Data],
        insertRowBytesList: [Data]
    ) throws {
        if deleteRowBytesList.isEmpty && insertRowBytesList.isEmpty { return }

        let callbacks: TransitionCallbacks
        do {
            callbacks = try state.withLock { state -> TransitionCallbacks in
                var out = TransitionCallbacks()

                // Fast path when there are no deletes, no callbacks, no indexes, no primary key, and no querySetId tracking
                if deleteRowBytesList.isEmpty
                    && querySetId == nil
                    && state.insertCallbacks.isEmpty
                    && state.secondaryIndexes.isEmpty
                    && extractPrimaryKey == nil
                {
                    if state.entriesAreMaterialized {
                        state.entries.reserveCapacity(state.entries.count + insertRowBytesList.count)
                        for rowBytes in insertRowBytesList {
                            let row = try decodeRow(rowBytes)
                            _ = insertEntry(row, for: HashedBytes(rowBytes), into: &state)
                        }
                    } else {
                        state.pendingRows.reserveCapacity(state.pendingRows.count + insertRowBytesList.count)
                        for rowBytes in insertRowBytesList {
                            let row = try decodeRow(rowBytes)
                            state.pendingRows.append(PendingRow(bytes: rowBytes, value: row))
                        }
                    }
                    return out
                }

                materializeEntries(in: &state)
                out.deleteCallbacks = Array(state.deleteCallbacks.values)
                out.updateCallbacks = Array(state.updateCallbacks.values)
                out.insertCallbacks = Array(state.insertCallbacks.values)

                if let extractPrimaryKey {
                    // Primary-key aware transition:
                    // 1. Process deletes and record any row whose refcount dropped to 0 by primary key.
                    var evictedByPK: [PrimaryKeyBox: (key: HashedBytes, row: T)] = [:]
                    for rowBytes in deleteRowBytesList {
                        let key = HashedBytes(rowBytes)
                        decrementQuerySetCount(querySetId, key: key, in: &state)
                        guard let idx = state.entries.index(forKey: key) else { continue }
                        let oldRow = state.entries.values[idx].value
                        if state.entries.values[idx].count <= 1 {
                            state.entries.remove(at: idx)
                            let pk = extractPrimaryKey(oldRow)
                            evictedByPK[pk] = (key: key, row: oldRow)
                        } else {
                            state.entries.values[idx].count -= 1
                        }
                    }

                    // 2. Process inserts and match against `evictedByPK` or existing `primaryKeyToBytes`.
                    for rowBytes in insertRowBytesList {
                        let key = HashedBytes(rowBytes)
                        incrementQuerySetCount(querySetId, key: key, in: &state)
                        if let existingIdx = state.entries.index(forKey: key) {
                            state.entries.values[existingIdx].count += 1
                            continue
                        }
                        let newRow = try decodeRow(rowBytes)
                        let pk = extractPrimaryKey(newRow)
                        state.entries[key] = RowEntry(count: 1, value: newRow)
                        state.primaryKeyToBytes[pk] = key

                        if let evicted = evictedByPK.removeValue(forKey: pk) {
                            for secIdx in state.secondaryIndexes {
                                secIdx.update(oldRow: evicted.row, oldKey: evicted.key, newRow: newRow, newKey: key)
                            }
                            if !out.updateCallbacks.isEmpty {
                                out.updatedRows.append((oldRow: evicted.row, newRow: newRow))
                            }
                        } else {
                            for secIdx in state.secondaryIndexes {
                                secIdx.insert(newRow, key: key)
                            }
                            if !out.insertCallbacks.isEmpty {
                                out.insertedRows.append(newRow)
                            }
                        }
                    }

                    // 3. Any remaining evicted rows were not replaced by an insert with the same PK.
                    for (pk, evicted) in evictedByPK {
                        if state.primaryKeyToBytes[pk] == evicted.key {
                            state.primaryKeyToBytes.removeValue(forKey: pk)
                        }
                        for secIdx in state.secondaryIndexes {
                            secIdx.remove(evicted.row, key: evicted.key)
                        }
                        if !out.deleteCallbacks.isEmpty {
                            out.deletedRows.append(evicted.row)
                        }
                    }
                    return out
                }

                // Positional pairing fallback for rows without SpacetimePrimaryKeyRow:
                let pairedCount = min(deleteRowBytesList.count, insertRowBytesList.count)
                for i in 0..<pairedCount {
                    let oldKey = HashedBytes(deleteRowBytesList[i])
                    let newKey = HashedBytes(insertRowBytesList[i])
                    decrementQuerySetCount(querySetId, key: oldKey, in: &state)
                    incrementQuerySetCount(querySetId, key: newKey, in: &state)

                    guard let oldIndex = state.entries.index(forKey: oldKey) else {
                        let newRow = try decodeRow(insertRowBytesList[i])
                        let (storedRow, isNew) = insertEntry(newRow, for: newKey, into: &state)
                        if isNew && !out.insertCallbacks.isEmpty {
                            out.insertedRows.append(storedRow)
                        }
                        continue
                    }

                    let oldRow = state.entries.values[oldIndex].value
                    let newRow: T
                    let isNewInsert: Bool

                    if let newIndex = state.entries.index(forKey: newKey) {
                        state.entries.values[newIndex].count += 1
                        newRow = state.entries.values[newIndex].value
                        isNewInsert = false
                    } else {
                        newRow = try decodeRow(insertRowBytesList[i])
                        state.entries[newKey] = RowEntry(count: 1, value: newRow)
                        isNewInsert = true
                    }

                    var oldRemoved = false
                    if let finalOldIndex = state.entries.index(forKey: oldKey) {
                        if state.entries.values[finalOldIndex].count <= 1 {
                            state.entries.remove(at: finalOldIndex)
                            oldRemoved = true
                        } else {
                            state.entries.values[finalOldIndex].count -= 1
                        }
                    }

                    if oldRemoved && isNewInsert {
                        for idx in state.secondaryIndexes {
                            idx.update(oldRow: oldRow, oldKey: oldKey, newRow: newRow, newKey: newKey)
                        }
                    } else {
                        if oldRemoved {
                            for idx in state.secondaryIndexes {
                                idx.remove(oldRow, key: oldKey)
                            }
                        }
                        if isNewInsert {
                            for idx in state.secondaryIndexes {
                                idx.insert(newRow, key: newKey)
                            }
                        }
                    }

                    if !out.updateCallbacks.isEmpty {
                        out.updatedRows.append((oldRow: oldRow, newRow: newRow))
                    }
                }

                if deleteRowBytesList.count > pairedCount {
                    for rowBytes in deleteRowBytesList[pairedCount...] {
                        let key = HashedBytes(rowBytes)
                        decrementQuerySetCount(querySetId, key: key, in: &state)
                        if let index = state.entries.index(forKey: key) {
                            let deletedRow = state.entries.values[index].value
                            if state.entries.values[index].count <= 1 {
                                state.entries.remove(at: index)
                                for idx in state.secondaryIndexes {
                                    idx.remove(deletedRow, key: key)
                                }
                                if !out.deleteCallbacks.isEmpty {
                                    out.deletedRows.append(deletedRow)
                                }
                            } else {
                                state.entries.values[index].count -= 1
                            }
                        }
                    }
                }

                if insertRowBytesList.count > pairedCount {
                    for rowBytes in insertRowBytesList[pairedCount...] {
                        let key = HashedBytes(rowBytes)
                        incrementQuerySetCount(querySetId, key: key, in: &state)
                        let row = try decodeRow(rowBytes)
                        let (storedRow, isNew) = insertEntry(row, for: key, into: &state)
                        if isNew && !out.insertCallbacks.isEmpty {
                            out.insertedRows.append(storedRow)
                        }
                    }
                }

                return out
            }
        } catch {
            Log.cache.error("Failed to decode row for table '\(self.tableName)': \(error.localizedDescription)")
            throw error
        }

        for row in callbacks.deletedRows {
            for cb in callbacks.deleteCallbacks { cb(row) }
        }
        for pair in callbacks.updatedRows {
            for cb in callbacks.updateCallbacks { cb(pair.oldRow, pair.newRow) }
        }
        for row in callbacks.insertedRows {
            for cb in callbacks.insertCallbacks { cb(row) }
        }
    }

    /// Evicts all rows contributed by `querySetId`, decrementing their refcounts and firing
    /// `onDelete` only for rows whose total refcount across all subscriptions reaches zero.
    @discardableResult
    public func evictQuerySet(_ querySetId: QuerySetId) -> Bool {
        let result = state.withLock { state -> (modified: Bool, deletedRows: [T], callbacks: [@Sendable (T) -> Void]) in
            guard let counts = state.querySetCounts.removeValue(forKey: querySetId), !counts.isEmpty else {
                return (false, [], [])
            }
            materializeEntries(in: &state)
            var modified = false
            var deletedRows: [T] = []
            let callbacks = Array(state.deleteCallbacks.values)

            for (key, dropCount) in counts where dropCount > 0 {
                guard let idx = state.entries.index(forKey: key) else { continue }
                modified = true
                let row = state.entries.values[idx].value
                if state.entries.values[idx].count <= dropCount {
                    state.entries.remove(at: idx)
                    if let extractPrimaryKey {
                        let pk = extractPrimaryKey(row)
                        if state.primaryKeyToBytes[pk] == key {
                            state.primaryKeyToBytes.removeValue(forKey: pk)
                        }
                    }
                    for secIdx in state.secondaryIndexes {
                        secIdx.remove(row, key: key)
                    }
                    if !callbacks.isEmpty {
                        deletedRows.append(row)
                    }
                } else {
                    state.entries.values[idx].count -= dropCount
                }
            }
            return (modified, deletedRows, callbacks)
        }

        for row in result.deletedRows {
            for cb in result.callbacks {
                cb(row)
            }
        }
        return result.modified
    }

    /// Reconciles cached rows against a fresh set of subscription rows in a single pass.
    @discardableResult
    public func reconcile(rowBytesList: [Data]) throws -> Bool {
        try reconcile(querySets: [(querySetId: nil, rowBytesList: rowBytesList)])
    }

    /// Reconciles cached rows against a set of `(querySetId, rowBytesList)` snapshots in a single pass.
    ///
    /// Existing rows with identical bytes are retained without firing delete/insert callbacks.
    /// When `T` conforms to `SpacetimePrimaryKeyRow`, rows whose primary key matches an evicted row
    /// with different bytes fire `onUpdate(oldRow, newRow)` instead of separate delete + insert callbacks.
    @discardableResult
    public func reconcile(querySets: [(querySetId: QuerySetId?, rowBytesList: [Data])]) throws -> Bool {
        let totalIncomingCount = querySets.reduce(0) { $0 + $1.rowBytesList.count }
        let isEmpty = state.withLock { state in
            state.entries.isEmpty && state.pendingRows.isEmpty
        }
        if isEmpty {
            guard totalIncomingCount > 0 else { return false }
            for (querySetId, rowBytesList) in querySets where !rowBytesList.isEmpty {
                try applyQuerySetTransition(
                    querySetId: querySetId,
                    deleteRowBytesList: [],
                    insertRowBytesList: rowBytesList
                )
            }
            return true
        }

        let callbacksToFire: TransitionCallbacks
        do {
            callbacksToFire = try state.withLock { state in
                materializeEntries(in: &state)

                var newEntries: [HashedBytes: RowEntry<T>] = [:]
                newEntries.reserveCapacity(totalIncomingCount)
                var newQuerySetCounts: [QuerySetId: [HashedBytes: Int]] = [:]

                var newlyDecodedEntries: [(key: HashedBytes, row: T)] = []

                for (querySetId, rowBytesList) in querySets {
                    for rowBytes in rowBytesList {
                        let key = HashedBytes(rowBytes)
                        if let querySetId {
                            newQuerySetCounts[querySetId, default: [:]][key, default: 0] += 1
                        }
                        if let existingNewIndex = newEntries.index(forKey: key) {
                            newEntries.values[existingNewIndex].count += 1
                        } else if let existingOld = state.entries[key], existingOld.count > 0 {
                            newEntries[key] = RowEntry(count: 1, value: existingOld.value)
                        } else {
                            let decoded = try decodeRow(rowBytes)
                            newEntries[key] = RowEntry(count: 1, value: decoded)
                            newlyDecodedEntries.append((key: key, row: decoded))
                        }
                    }
                }

                var out = TransitionCallbacks(
                    deleteCallbacks: Array(state.deleteCallbacks.values),
                    updateCallbacks: Array(state.updateCallbacks.values),
                    insertCallbacks: Array(state.insertCallbacks.values)
                )

                if let extractPrimaryKey {
                    var evictedByPK: [PrimaryKeyBox: T] = [:]
                    for (oldKey, oldEntry) in state.entries where oldEntry.count > 0 {
                        if newEntries[oldKey] == nil {
                            evictedByPK[extractPrimaryKey(oldEntry.value)] = oldEntry.value
                        }
                    }

                    for item in newlyDecodedEntries {
                        let pk = extractPrimaryKey(item.row)
                        if let oldRow = evictedByPK.removeValue(forKey: pk) {
                            if !out.updateCallbacks.isEmpty {
                                out.updatedRows.append((oldRow: oldRow, newRow: item.row))
                            }
                        } else if !out.insertCallbacks.isEmpty {
                            out.insertedRows.append(item.row)
                        }
                    }

                    if !out.deleteCallbacks.isEmpty {
                        out.deletedRows.append(contentsOf: evictedByPK.values)
                    }
                } else {
                    if !out.insertCallbacks.isEmpty {
                        out.insertedRows = newlyDecodedEntries.map(\.row)
                    }
                    if !out.deleteCallbacks.isEmpty {
                        for (oldKey, oldEntry) in state.entries where oldEntry.count > 0 {
                            if newEntries[oldKey] == nil {
                                out.deletedRows.append(oldEntry.value)
                            }
                        }
                    }
                }

                state.querySetCounts = newQuerySetCounts
                if newEntries.isEmpty {
                    state.entries.removeAll(keepingCapacity: true)
                    state.primaryKeyToBytes.removeAll(keepingCapacity: true)
                    state.pendingRows.removeAll(keepingCapacity: true)
                    state.entriesAreMaterialized = false
                    for idx in state.secondaryIndexes {
                        idx.clear()
                    }
                } else {
                    state.entries = newEntries
                    state.entriesAreMaterialized = true
                    rebuildDerivedIndexes(in: &state)
                }

                return out
            }
        } catch {
            Log.cache.error("Failed to decode row for table '\(self.tableName)': \(error.localizedDescription)")
            throw error
        }

        for row in callbacksToFire.deletedRows {
            for callback in callbacksToFire.deleteCallbacks {
                callback(row)
            }
        }
        for pair in callbacksToFire.updatedRows {
            for callback in callbacksToFire.updateCallbacks {
                callback(pair.oldRow, pair.newRow)
            }
        }
        for row in callbacksToFire.insertedRows {
            for callback in callbacksToFire.insertCallbacks {
                callback(row)
            }
        }
        return true
    }

    public func clear() {
        state.withLock { state in
            state.entries.removeAll(keepingCapacity: true)
            state.primaryKeyToBytes.removeAll(keepingCapacity: true)
            state.querySetCounts.removeAll(keepingCapacity: true)
            state.pendingRows.removeAll(keepingCapacity: true)
            state.entriesAreMaterialized = false
            for idx in state.secondaryIndexes {
                idx.clear()
            }
        }
    }

    // MARK: - Snapshot Persistence Support

    public func snapshotRowBytesList() -> [Data] {
        state.withLock { state in
            materializeEntries(in: &state)
            var result: [Data] = []
            result.reserveCapacity(state.entries.count)
            for (key, entry) in state.entries where entry.count > 0 {
                result.append(key.data)
            }
            return result
        }
    }

    public func restoreSnapshot(rowBytesList: [Data]) throws {
        _ = try reconcile(rowBytesList: rowBytesList)
    }

    // MARK: - Delta Callbacks & AsyncSequence Streams

    @discardableResult
    public func onInsert(_ callback: @escaping @Sendable (T) -> Void) -> TableDeltaHandle {
        let id = UUID()
        state.withLock { state in
            state.insertCallbacks[id] = callback
        }
        return TableDeltaHandle { [weak self] in
            guard let self else { return }
            _ = self.state.withLock { state in
                state.insertCallbacks.removeValue(forKey: id)
            }
        }
    }

    @discardableResult
    public func onDelete(_ callback: @escaping @Sendable (T) -> Void) -> TableDeltaHandle {
        let id = UUID()
        state.withLock { state in
            state.deleteCallbacks[id] = callback
        }
        return TableDeltaHandle { [weak self] in
            guard let self else { return }
            _ = self.state.withLock { state in
                state.deleteCallbacks.removeValue(forKey: id)
            }
        }
    }

    @discardableResult
    public func onUpdate(_ callback: @escaping @Sendable (T, T) -> Void) -> TableDeltaHandle {
        let id = UUID()
        state.withLock { state in
            state.updateCallbacks[id] = callback
        }
        return TableDeltaHandle { [weak self] in
            guard let self else { return }
            _ = self.state.withLock { state in
                state.updateCallbacks.removeValue(forKey: id)
            }
        }
    }

    /// An `AsyncStream` yielding newly inserted rows as they enter the cache.
    public var inserts: AsyncStream<T> {
        AsyncStream { continuation in
            let handle = self.onInsert { row in
                continuation.yield(row)
            }
            continuation.onTermination = { @Sendable _ in
                handle.cancel()
            }
        }
    }

    /// An `AsyncStream` yielding deleted rows as they are evicted from the cache.
    public var deletes: AsyncStream<T> {
        AsyncStream { continuation in
            let handle = self.onDelete { row in
                continuation.yield(row)
            }
            continuation.onTermination = { @Sendable _ in
                handle.cancel()
            }
        }
    }

    /// An `AsyncStream` yielding `(oldRow, newRow)` pairs as rows update in the cache.
    public var updates: AsyncStream<(oldRow: T, newRow: T)> {
        AsyncStream { continuation in
            let handle = self.onUpdate { oldRow, newRow in
                continuation.yield((oldRow: oldRow, newRow: newRow))
            }
            continuation.onTermination = { @Sendable _ in
                handle.cancel()
            }
        }
    }

    /// Synchronizes the observable `rows` array with the internal background storage.
    /// This should be called on the MainActor, typically after a transaction update or when the UI needs refreshing.
    @MainActor
    public func sync() {
        self.rows = snapshot()
    }

    /// Returns a thread-safe snapshot of all distinct rows currently in the cache.
    public func currentRows() -> [T] {
        snapshot()
    }

    /// Internal method to generate a flattened snapshot of all rows in deterministic order.
    private func snapshot() -> [T] {
        state.withLock { state in
            // One element per distinct row. An entry's count is a refcount for overlapping
            // subscriptions, not a multiplicity (as in the TypeScript SDK's `iter()`).
            materializeEntries(in: &state)
            var flattened: [T] = []
            flattened.reserveCapacity(state.entries.count)
            for entry in state.entries.values where entry.count > 0 {
                flattened.append(entry.value)
            }
            return flattened
        }
    }
}

extension TableCache: Decodable where T: Decodable {
    public convenience init(from decoder: Decoder) throws {
        fatalError("TableCache cannot be decoded; it is a managed container.")
    }
}
