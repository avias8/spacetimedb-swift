import Foundation
import Synchronization

/// Represents an optimistic local mutation applied to `ClientCache` before server confirmation.
public struct OptimisticRowChange: Sendable {
    public let tableName: String
    public let deletedRowBytesList: [Data]
    public let insertedRowBytesList: [Data]

    public init(
        tableName: String,
        deletedRowBytesList: [Data] = [],
        insertedRowBytesList: [Data] = []
    ) {
        self.tableName = tableName
        self.deletedRowBytesList = deletedRowBytesList
        self.insertedRowBytesList = insertedRowBytesList
    }

    public static func insert<T: Encodable>(tableName: String, row: T) throws -> OptimisticRowChange {
        let encoded = try BSATNEncoder().encode(row)
        return OptimisticRowChange(tableName: tableName, deletedRowBytesList: [], insertedRowBytesList: [encoded])
    }

    public static func delete<T: Encodable>(tableName: String, row: T) throws -> OptimisticRowChange {
        let encoded = try BSATNEncoder().encode(row)
        return OptimisticRowChange(tableName: tableName, deletedRowBytesList: [encoded], insertedRowBytesList: [])
    }

    public static func update<T: Encodable>(tableName: String, oldRow: T, newRow: T) throws -> OptimisticRowChange {
        let encoder = BSATNEncoder()
        let oldEncoded = try encoder.encode(oldRow)
        let newEncoded = try encoder.encode(newRow)
        return OptimisticRowChange(
            tableName: tableName,
            deletedRowBytesList: [oldEncoded],
            insertedRowBytesList: [newEncoded]
        )
    }
}

/// Binary snapshot container used by `ClientCache.saveSnapshot(to:)` and `ClientCache.loadSnapshot(from:)`.
private struct ClientCacheSnapshotFile: Codable {
    struct TableEntry: Codable {
        let tableName: String
        let rows: [Data]
    }
    let version: UInt32
    let tables: [TableEntry]
}

/// Holds the local state of all SpacetimeDB tables, routing updates from the WebSocket down to each table.
public final class ClientCache: Sendable {
    private struct State {
        var tables: [String: any SpacetimeTableCacheProtocol] = [:]
        var optimisticMutationsByRequestId: [RequestId: [OptimisticRowChange]] = [:]
        var pendingSyncTableNames: Set<String> = []
        var isSyncScheduled = false
    }

    private let state: Mutex<State> = Mutex(State())

    public var registeredTableNames: [String] {
        state.withLock { state in
            Array(state.tables.keys)
        }
    }

    public init() {}

    /// Registers a new table cache for a given table name.
    public func registerTable<T: Decodable & Sendable>(tableName: String, rowType: T.Type) {
        state.withLock { state in
            if let existing = state.tables[tableName] {
                if existing is TableCache<T> {
                    // Idempotent re-registration: keep the existing cache instance so
                    // any replicated rows already loaded are preserved.
                    return
                }
                fatalError("Table \(tableName) already registered with a different row type.")
            }
            let cache = TableCache<T>(tableName: tableName)
            state.tables[tableName] = cache
        }
    }

    /// Registers a generated table while preserving static BSATN decoder dispatch.
    public func registerTable<T: Decodable & Sendable & BSATNSpecialDecodable>(
        tableName: String,
        rowType: T.Type
    ) {
        state.withLock { state in
            if let existing = state.tables[tableName] {
                if existing is TableCache<T> {
                    return
                }
                fatalError("Table \(tableName) already registered with a different row type.")
            }
            let cache = TableCache<T>(tableName: tableName)
            state.tables[tableName] = cache
        }
    }

    /// Registers a new table cache for a given table name.
    public func registerTable<T>(name: String, cache: TableCache<T>) {
        state.withLock { state in
            if state.tables[name] != nil {
                // Preserve the first registration to avoid replacing a live cache.
                return
            }
            state.tables[name] = cache
        }
    }

    public func getTable(name: String) -> (any SpacetimeTableCacheProtocol)? {
        state.withLock { state in
            state.tables[name]
        }
    }

    public func getTableCache<T: Decodable & Sendable>(tableName: String) -> TableCache<T> {
        guard let table = state.withLock({ state in
            state.tables[tableName] as? TableCache<T>
        }) else {
            fatalError("Table \(tableName) not registered or of wrong type.")
        }
        return table
    }

    /// Clears just these tables' rows, keeping their registrations (a fresh subscription's
    /// rows replace them).
    public func clear(tables names: Set<String>) {
        let tables = state.withLock { state in names.compactMap { state.tables[$0] } }
        for table in tables {
            table.clear()
        }
        scheduleObservableSync(for: names)
    }

    /// Clears all replicated rows while preserving generated table registrations.
    public func clear() {
        let tablesSnapshot = state.withLock { state -> [String: any SpacetimeTableCacheProtocol] in
            state.optimisticMutationsByRequestId.removeAll()
            return state.tables
        }

        for table in tablesSnapshot.values {
            table.clear()
        }

        scheduleObservableSync(for: Set(tablesSnapshot.keys))
    }

    /// Evicts all rows tracked under `querySetId` across every registered table.
    ///
    /// Used when an unsubscribe completes without server-provided dropped rows (`sendDroppedRows == false`)
    /// or when a subscription fails via `SubscriptionError`.
    public func evictQuerySet(_ querySetId: QuerySetId) {
        let tablesSnapshot = state.withLock { state in
            state.tables
        }
        var modifiedTables = Set<String>()
        for (tableName, tableCache) in tablesSnapshot {
            if tableCache.evictQuerySet(querySetId) {
                modifiedTables.insert(tableName)
            }
        }
        scheduleObservableSync(for: modifiedTables)
    }

    /// Reconciles cached rows against a set of replayed `QueryRows` payloads in a single pass.
    ///
    /// - Parameters:
    ///   - queryRowsList: Initial row snapshots from one or more applied subscriptions.
    ///   - replacingTables: Tables whose existing cached rows should be replaced (diffed) by the
    ///     incoming rows. When `nil`, all registered tables are reconciled (including tables absent
    ///     from `queryRowsList`, whose stale rows are evicted).
    public func reconcile(queryRowsList: [QueryRows], replacingTables: Set<String>? = nil) {
        let querySets = queryRowsList.map { (querySetId: Optional<QuerySetId>.none, rows: $0) }
        reconcile(querySets: querySets, replacingTables: replacingTables)
    }

    /// Reconciles cached rows against a set of `(querySetId, QueryRows)` payloads in a single pass.
    public func reconcile(
        querySets: [(querySetId: QuerySetId?, rows: QueryRows)],
        replacingTables: Set<String>? = nil
    ) {
        let tablesSnapshot = state.withLock { state in
            state.tables
        }

        let tablesToReplace = replacingTables ?? Set(tablesSnapshot.keys)
        var incomingByTable: [String: [(querySetId: QuerySetId?, rowBytesList: [Data])]] = [:]

        for (querySetId, queryRows) in querySets {
            for tableRows in queryRows.tables {
                let tableName = tableRows.table.rawValue
                let extracted = extractRows(from: tableRows.rows)
                incomingByTable[tableName, default: []].append((querySetId: querySetId, rowBytesList: extracted))
            }
        }

        var modifiedTables = Set<String>()
        let allTargetTables = tablesToReplace.union(incomingByTable.keys)

        for tableName in allTargetTables {
            guard let tableCache = tablesSnapshot[tableName] else {
                continue
            }
            let tableQuerySets = incomingByTable[tableName] ?? []
            if tablesToReplace.contains(tableName) {
                do {
                    if try tableCache.reconcile(querySets: tableQuerySets) {
                        modifiedTables.insert(tableName)
                    }
                } catch {
                    Log.cache.error("Failed to reconcile rows for table '\(tableName)': \(error.localizedDescription)")
                }
            } else {
                for (querySetId, rowBytesList) in tableQuerySets where !rowBytesList.isEmpty {
                    do {
                        try tableCache.applyQuerySetTransition(
                            querySetId: querySetId,
                            deleteRowBytesList: [],
                            insertRowBytesList: rowBytesList
                        )
                        modifiedTables.insert(tableName)
                    } catch {
                        Log.cache.error("Failed to bulk insert rows for table '\(tableName)': \(error.localizedDescription)")
                    }
                }
            }
        }

        scheduleObservableSync(for: modifiedTables)
    }

    /// Processes a TransactionUpdate payload from the network.
    public func applyTransactionUpdate(_ update: TransactionUpdate) {
        var modifiedTables = Set<String>()

        let tablesSnapshot = state.withLock { state in
            state.tables
        }

        for querySet in update.querySets {
            let querySetId = querySet.querySetId
            for tableUpdate in querySet.tables {
                let tableName = tableUpdate.tableName.rawValue
                guard let tableCache = tablesSnapshot[tableName] else {
                    continue
                }

                modifiedTables.insert(tableName)

                for rowUpdate in tableUpdate.rows {
                    switch rowUpdate {
                    case .persistentTable(let persistent):
                        let deleteRows = self.extractRows(from: persistent.deletes)
                        let insertRows = self.extractRows(from: persistent.inserts)
                        do {
                            try tableCache.applyQuerySetTransition(
                                querySetId: querySetId,
                                deleteRowBytesList: deleteRows,
                                insertRowBytesList: insertRows
                            )
                        } catch {
                            Log.cache.error("Failed to apply querySet transition for table '\(tableName)': \(error.localizedDescription)")
                        }
                    case .eventTable:
                        break
                    }
                }
            }
        }

        scheduleObservableSync(for: modifiedTables)
    }

    // MARK: - Optimistic Mutations

    /// Applies optimistic row changes immediately and records them under `requestId` so they can be
    /// reconciled when the reducer's `ReducerResult` arrives (or rolled back if it fails or disconnects).
    public func applyOptimisticChanges(requestId: RequestId, changes: [OptimisticRowChange]) {
        guard !changes.isEmpty else { return }

        let tablesSnapshot = state.withLock { state -> [String: any SpacetimeTableCacheProtocol] in
            state.optimisticMutationsByRequestId[requestId] = changes
            return state.tables
        }

        var modifiedTables = Set<String>()
        for change in changes {
            guard let tableCache = tablesSnapshot[change.tableName] else { continue }
            do {
                try tableCache.applyQuerySetTransition(
                    querySetId: nil,
                    deleteRowBytesList: change.deletedRowBytesList,
                    insertRowBytesList: change.insertedRowBytesList
                )
                modifiedTables.insert(change.tableName)
            } catch {
                Log.cache.error("Failed to apply optimistic change for table '\(change.tableName)': \(error.localizedDescription)")
            }
        }
        scheduleObservableSync(for: modifiedTables)
    }

    /// Reverts the optimistic changes recorded for `requestId`.
    ///
    /// Called before applying an authoritative `ReducerResult.ok` transaction update or when a reducer
    /// returns `.err` / `.internalError` or disconnects.
    public func revertOptimisticChanges(for requestId: RequestId) {
        let (changes, tablesSnapshot) = state.withLock { state -> ([OptimisticRowChange]?, [String: any SpacetimeTableCacheProtocol]) in
            let removed = state.optimisticMutationsByRequestId.removeValue(forKey: requestId)
            return (removed, state.tables)
        }
        guard let changes, !changes.isEmpty else { return }

        var modifiedTables = Set<String>()
        for change in changes.reversed() {
            guard let tableCache = tablesSnapshot[change.tableName] else { continue }
            do {
                try tableCache.applyQuerySetTransition(
                    querySetId: nil,
                    deleteRowBytesList: change.insertedRowBytesList,
                    insertRowBytesList: change.deletedRowBytesList
                )
                modifiedTables.insert(change.tableName)
            } catch {
                Log.cache.error("Failed to revert optimistic change for table '\(change.tableName)': \(error.localizedDescription)")
            }
        }
        scheduleObservableSync(for: modifiedTables)
    }

    /// Reverts all in-flight optimistic mutations (for example, on socket disconnect).
    public func revertAllOptimisticChanges() {
        let requestIds = state.withLock { state in
            Array(state.optimisticMutationsByRequestId.keys)
        }
        for requestId in requestIds {
            revertOptimisticChanges(for: requestId)
        }
    }

    // MARK: - Offline Snapshot Persistence

    /// Saves a BSATN-encoded snapshot of all registered tables' current rows to `url`.
    public func saveSnapshot(to url: URL) throws {
        let data = try encodeSnapshotData()
        try data.write(to: url, options: .atomic)
    }

    /// Loads a BSATN-encoded snapshot from `url` and restores rows into all matching registered tables.
    public func loadSnapshot(from url: URL) throws {
        let data = try Data(contentsOf: url)
        try decodeSnapshotData(data)
    }

    /// Encodes all registered tables' current rows into a BSATN binary blob.
    public func encodeSnapshotData() throws -> Data {
        let tablesSnapshot = state.withLock { state in
            state.tables
        }
        let entries = tablesSnapshot.keys.sorted().compactMap { name -> ClientCacheSnapshotFile.TableEntry? in
            guard let table = tablesSnapshot[name] else { return nil }
            return ClientCacheSnapshotFile.TableEntry(tableName: name, rows: table.snapshotRowBytesList())
        }
        let snapshot = ClientCacheSnapshotFile(version: 1, tables: entries)
        return try BSATNEncoder().encode(snapshot)
    }

    /// Restores rows into registered tables from a BSATN binary blob produced by `encodeSnapshotData()`.
    public func decodeSnapshotData(_ data: Data) throws {
        let snapshot = try BSATNDecoder().decode(ClientCacheSnapshotFile.self, from: data)
        let tablesSnapshot = state.withLock { state in
            state.tables
        }
        var modifiedTables = Set<String>()
        for entry in snapshot.tables {
            guard let table = tablesSnapshot[entry.tableName] else { continue }
            try table.restoreSnapshot(rowBytesList: entry.rows)
            modifiedTables.insert(entry.tableName)
        }
        scheduleObservableSync(for: modifiedTables)
    }

    private func scheduleObservableSync(for tableNames: Set<String>) {
        guard !tableNames.isEmpty else { return }
        let shouldSchedule = state.withLock { state -> Bool in
            state.pendingSyncTableNames.formUnion(tableNames)
            guard !state.isSyncScheduled else { return false }
            state.isSyncScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        Task { @MainActor [weak self] in
            self?.drainObservableSync()
        }
    }

    @MainActor
    private func drainObservableSync() {
        let tablesToSync: [any ThreadSafeSyncable] = state.withLock { state in
            let names = state.pendingSyncTableNames
            state.pendingSyncTableNames.removeAll(keepingCapacity: true)
            return names.compactMap { state.tables[$0] as? any ThreadSafeSyncable }
        }

        for table in tablesToSync {
            table.sync()
        }

        let shouldReschedule = state.withLock { state -> Bool in
            guard !state.pendingSyncTableNames.isEmpty else {
                state.isSyncScheduled = false
                return false
            }
            return true
        }
        guard shouldReschedule else { return }

        Task { @MainActor [weak self] in
            self?.drainObservableSync()
        }
    }

    private func extractRows(from rowList: BsatnRowList) -> [Data] {
        let sizeHint = rowList.sizeHint
        let data = rowList.rowsData
        var rows: [Data] = []

        switch sizeHint {
        case .fixedSize(let size):
            let rowSize = Int(size)
            if rowSize == 0 { return rows }

            var offset = 0
            while offset < data.count {
                let end = min(offset + rowSize, data.count)
                rows.append(data[offset..<end])
                offset += rowSize
            }

        case .rowOffsets(let offsets):
            for i in 0..<offsets.count {
                let start = Int(offsets[i])
                let end = (i + 1 < offsets.count) ? Int(offsets[i + 1]) : data.count
                rows.append(data[start..<end])
            }
        }

        return rows
    }
}

/// Helper protocol to allow ClientCache to call sync() without knowing the concrete type T
private protocol ThreadSafeSyncable: Sendable {
    @MainActor func sync()
}

extension TableCache: ThreadSafeSyncable {}
