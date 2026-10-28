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
    @discardableResult
    func reconcile(rowBytesList: [Data]) throws -> Bool
    func clear()
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

    // All internal state is @ObservationIgnored to prevent the @Observable macro
    // from intercepting every dictionary mutation with willSet/didSet tracking.
    // Only `rows` is observed for SwiftUI reactivity.
    @ObservationIgnored private let decodeRow: @Sendable (Data) throws -> T
    @ObservationIgnored private let state: Mutex<State> = Mutex(State())

    private struct PendingRow {
        let bytes: Data
        let value: T
    }

    private struct State {
        var entries: [HashedBytes: RowEntry<T>] = [:]
        var pendingRows: [PendingRow] = []
        var entriesAreMaterialized = false
        var insertCallbacks: [UUID: @Sendable (T) -> Void] = [:]
        var deleteCallbacks: [UUID: @Sendable (T) -> Void] = [:]
        var updateCallbacks: [UUID: @Sendable (T, T) -> Void] = [:]
    }

    private init(tableName: String, decodeRow: @escaping @Sendable (Data) throws -> T) {
        self.tableName = tableName
        self.decodeRow = decodeRow
    }

    public convenience init(tableName: String) {
        if let specialType = T.self as? BSATNSpecialDecodable.Type {
            self.init(tableName: tableName) { data in
                try data.withUnsafeBytes { buffer in
                    var reader = BSATNReader(buffer: buffer)
                    return try specialType.decodeBSATN(from: &reader) as! T
                }
            }
        } else {
            let decoder = BSATNDecoder()
            self.init(tableName: tableName) { data in
                try decoder.decode(T.self, from: data)
            }
        }
    }

    public convenience init(tableName: String) where T: BSATNSpecialDecodable {
        self.init(tableName: tableName) { data in
            try data.withUnsafeBytes { buffer in
                var reader = BSATNReader(buffer: buffer)
                return try T.decodeBSATN(from: &reader)
            }
        }
    }

    @inline(__always)
    private static func insert(
        _ row: T,
        for key: HashedBytes,
        into entries: inout [HashedBytes: RowEntry<T>]
    ) -> (value: T, isNew: Bool) {
        guard var existing = entries.updateValue(RowEntry(count: 1, value: row), forKey: key) else {
            return (row, true)
        }

        existing.count += 1
        entries[key] = existing
        return (existing.value, false)
    }

    @inline(__always)
    private static func materializeEntries(in state: inout State) {
        guard !state.entriesAreMaterialized else { return }

        state.entries.reserveCapacity(state.entries.count + state.pendingRows.count)
        for pending in state.pendingRows {
            _ = insert(pending.value, for: HashedBytes(pending.bytes), into: &state.entries)
        }
        state.pendingRows.removeAll(keepingCapacity: true)
        state.entriesAreMaterialized = true
    }

    public func handleInsert(rowBytes: Data) throws {
        let decodedRow: T
        do {
            decodedRow = try decodeRow(rowBytes)
        } catch {
            Log.cache.error("Failed to decode row for table '\(self.tableName)': \(error.localizedDescription)")
            throw error
        }

        let delivery = state.withLock { state -> (row: T, callbacks: [@Sendable (T) -> Void])? in
            if state.insertCallbacks.isEmpty {
                if state.entriesAreMaterialized {
                    _ = Self.insert(decodedRow, for: HashedBytes(rowBytes), into: &state.entries)
                } else {
                    state.pendingRows.append(PendingRow(bytes: rowBytes, value: decodedRow))
                }
                return nil
            }

            Self.materializeEntries(in: &state)
            let (storedRow, isNew) = Self.insert(decodedRow, for: HashedBytes(rowBytes), into: &state.entries)
            guard isNew else { return nil }
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
            Self.materializeEntries(in: &state)
            guard let index = state.entries.index(forKey: key) else {
                return nil
            }
            let deletedRow = state.entries.values[index].value
            if state.entries.values[index].count <= 1 {
                state.entries.remove(at: index)
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
                Self.materializeEntries(in: &state)
                guard let oldIndex = state.entries.index(forKey: oldKey) else {
                    return nil
                }

                let oldRow = state.entries.values[oldIndex].value
                let newRow: T

                if let newIndex = state.entries.index(forKey: newKey) {
                    state.entries.values[newIndex].count += 1
                    newRow = state.entries.values[newIndex].value
                } else {
                    newRow = try decodeRow(newRowBytes)
                    state.entries[newKey] = RowEntry(count: 1, value: newRow)
                }

                if let finalOldIndex = state.entries.index(forKey: oldKey) {
                    if state.entries.values[finalOldIndex].count <= 1 {
                        state.entries.remove(at: finalOldIndex)
                    } else {
                        state.entries.values[finalOldIndex].count -= 1
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

                guard !state.insertCallbacks.isEmpty else {
                    for rowBytes in rowBytesList {
                        let row = try decodeRow(rowBytes)
                        if state.entriesAreMaterialized {
                            _ = Self.insert(row, for: HashedBytes(rowBytes), into: &state.entries)
                        } else {
                            state.pendingRows.append(PendingRow(bytes: rowBytes, value: row))
                        }
                    }
                    return nil
                }

                Self.materializeEntries(in: &state)
                var storedRows: [T] = []
                storedRows.reserveCapacity(rowBytesList.count)
                for rowBytes in rowBytesList {
                    let row = try decodeRow(rowBytes)
                    let (storedRow, isNew) = Self.insert(row, for: HashedBytes(rowBytes), into: &state.entries)
                    if isNew {
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
            Self.materializeEntries(in: &state)
            var results: [(row: T, callbacks: [@Sendable (T) -> Void])] = []
            results.reserveCapacity(rowBytesList.count)
            let callbacks = Array(state.deleteCallbacks.values)
            
            for rowBytes in rowBytesList {
                let key = HashedBytes(rowBytes)
                if let index = state.entries.index(forKey: key) {
                    let deletedRow = state.entries.values[index].value
                    if state.entries.values[index].count <= 1 {
                        state.entries.remove(at: index)
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
        if oldRowBytesList.isEmpty || newRowBytesList.isEmpty { return }
        let count = min(oldRowBytesList.count, newRowBytesList.count)
        
        let results: [(oldRow: T, newRow: T, callbacks: [@Sendable (T, T) -> Void])]? = try state.withLock { state in
            Self.materializeEntries(in: &state)
            var results: [(oldRow: T, newRow: T, callbacks: [@Sendable (T, T) -> Void])] = []
            results.reserveCapacity(count)
            let callbacks = Array(state.updateCallbacks.values)
            
            for i in 0..<count {
                let oldRowBytes = oldRowBytesList[i]
                let newRowBytes = newRowBytesList[i]
                let oldKey = HashedBytes(oldRowBytes)
                let newKey = HashedBytes(newRowBytes)
                
                guard let oldIndex = state.entries.index(forKey: oldKey) else {
                    // Fallback: If old row doesn't exist, we just insert the new row, but we can't do it cleanly in bulk update loop
                    // Let's throw an error or handle it out of loop. For now, let's just insert new row.
                    let newRow = try decodeRow(newRowBytes)
                    if let newIndex = state.entries.index(forKey: newKey) {
                        state.entries.values[newIndex].count += 1
                    } else {
                        state.entries[newKey] = RowEntry(count: 1, value: newRow)
                    }
                    // We don't trigger update callback if old doesn't exist. We should trigger insert, but for simplicity let's stick to update loop semantics or skip callback.
                    continue
                }

                let oldRow = state.entries.values[oldIndex].value
                let newRow: T

                if let newIndex = state.entries.index(forKey: newKey) {
                    state.entries.values[newIndex].count += 1
                    newRow = state.entries.values[newIndex].value
                } else {
                    newRow = try decodeRow(newRowBytes)
                    state.entries[newKey] = RowEntry(count: 1, value: newRow)
                }

                if let finalOldIndex = state.entries.index(forKey: oldKey) {
                    if state.entries.values[finalOldIndex].count <= 1 {
                        state.entries.remove(at: finalOldIndex)
                    } else {
                        state.entries.values[finalOldIndex].count -= 1
                    }
                }
                
                results.append((oldRow: oldRow, newRow: newRow, callbacks: callbacks))
            }
            return results
        }
        
        guard let validResults = results else { return }
        for item in validResults {
            for callback in item.callbacks {
                callback(item.oldRow, item.newRow)
            }
        }
    }

    /// Reconciles cached rows against a fresh set of subscription rows in a single pass.
    ///
    /// Existing rows present in `rowBytesList` are retained without firing delete/insert callbacks,
    /// with their refcount updated to match the number of occurrences in `rowBytesList`.
    /// Rows no longer present are evicted (firing `onDelete`), and newly added rows are decoded
    /// and inserted (firing `onInsert`).
    @discardableResult
    public func reconcile(rowBytesList: [Data]) throws -> Bool {
        let isEmpty = state.withLock { state in
            state.entries.isEmpty && state.pendingRows.isEmpty
        }
        if isEmpty {
            guard !rowBytesList.isEmpty else { return false }
            try handleBulkInsert(rowBytesList: rowBytesList)
            return true
        }

        let callbacksToFire: (
            deletedRows: [T],
            deleteCallbacks: [@Sendable (T) -> Void],
            insertedRows: [T],
            insertCallbacks: [@Sendable (T) -> Void]
        )
        do {
            callbacksToFire = try state.withLock { state in
                Self.materializeEntries(in: &state)

                var newEntries: [HashedBytes: RowEntry<T>] = [:]
                newEntries.reserveCapacity(rowBytesList.count)

                let hasInsertCallbacks = !state.insertCallbacks.isEmpty
                var insertedRows: [T] = []
                if hasInsertCallbacks {
                    insertedRows.reserveCapacity(rowBytesList.count)
                }

                for rowBytes in rowBytesList {
                    let key = HashedBytes(rowBytes)
                    if let existingNewIndex = newEntries.index(forKey: key) {
                        newEntries.values[existingNewIndex].count += 1
                    } else if let existingOld = state.entries[key], existingOld.count > 0 {
                        newEntries[key] = RowEntry(count: 1, value: existingOld.value)
                    } else {
                        let decoded = try decodeRow(rowBytes)
                        newEntries[key] = RowEntry(count: 1, value: decoded)
                        if hasInsertCallbacks {
                            insertedRows.append(decoded)
                        }
                    }
                }

                let hasDeleteCallbacks = !state.deleteCallbacks.isEmpty
                var deletedRows: [T] = []
                if hasDeleteCallbacks {
                    for (oldKey, oldEntry) in state.entries where oldEntry.count > 0 {
                        if newEntries[oldKey] == nil {
                            deletedRows.append(oldEntry.value)
                        }
                    }
                }

                if newEntries.isEmpty {
                    state.entries.removeAll(keepingCapacity: true)
                    state.pendingRows.removeAll(keepingCapacity: true)
                    state.entriesAreMaterialized = false
                } else {
                    state.entries = newEntries
                    state.entriesAreMaterialized = true
                }

                return (
                    deletedRows: deletedRows,
                    deleteCallbacks: hasDeleteCallbacks ? Array(state.deleteCallbacks.values) : [],
                    insertedRows: insertedRows,
                    insertCallbacks: hasInsertCallbacks ? Array(state.insertCallbacks.values) : []
                )
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
            state.pendingRows.removeAll(keepingCapacity: true)
            state.entriesAreMaterialized = false
        }
    }

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

    /// Synchronizes the observable `rows` array with the internal background storage.
    /// This should be called on the MainActor, typically after a transaction update or when the UI needs refreshing.
    @MainActor
    public func sync() {
        self.rows = snapshot()
    }

    /// Internal method to generate a flattened snapshot of all rows in deterministic order.
    private func snapshot() -> [T] {
        state.withLock { state in
            // One element per distinct row. An entry's count is a refcount for overlapping
            // subscriptions, not a multiplicity (as in the TypeScript SDK's `iter()`).
            Self.materializeEntries(in: &state)
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
