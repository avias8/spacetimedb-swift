import XCTest
@testable import SpacetimeDB

final class CacheTests: XCTestCase {
    
    struct Person: Codable, Identifiable, Equatable, Sendable {
        var id: UInt32
        var name: String
    }
    
    @MainActor
    func testClientCacheRouting() throws {
        let clientCache = ClientCache()
        let personCache = TableCache<Person>(tableName: "Person")
        clientCache.registerTable(name: "Person", cache: personCache)
        
        let encoder = BSATNEncoder()
        let personBytes = try encoder.encode(Person(id: 42, name: "Alice"))
        
        // Build a v2 TransactionUpdate payload with one QuerySetUpdate / table row insert.
        var rawPayload = Data()
        rawPayload.append(1 as UInt32) // query_sets count
        rawPayload.append(1 as UInt32) // query_set_id
        rawPayload.append(1 as UInt32) // tables count

        rawPayload.append(try encoder.encode("Person")) // table_name
        rawPayload.append(1 as UInt32) // rows count
        rawPayload.append(0 as UInt8) // TableUpdateRows::PersistentTable

        rawPayload.append(0 as UInt8) // inserts.size_hint FixedSize
        rawPayload.append(UInt16(personBytes.count)) // insert row size
        rawPayload.append(UInt32(personBytes.count)) // inserts rowsData length
        rawPayload.append(personBytes)

        rawPayload.append(0 as UInt8) // deletes.size_hint FixedSize
        rawPayload.append(0 as UInt16) // delete row size
        rawPayload.append(0 as UInt32) // deletes rowsData length
        
        let decoder = BSATNDecoder()
        let transactionUpdate = try decoder.decode(TransactionUpdate.self, from: rawPayload)

        clientCache.applyTransactionUpdate(transactionUpdate)
        personCache.sync()

        XCTAssertEqual(personCache.rows.count, 1)
        XCTAssertEqual(personCache.rows[0].id, 42)
        XCTAssertEqual(personCache.rows[0].name, "Alice")
    }

    @MainActor
    func testRegisterTableIsIdempotentForSameType() throws {
        let clientCache = ClientCache()
        clientCache.registerTable(tableName: "Person", rowType: Person.self)

        let firstCache: TableCache<Person> = clientCache.getTableCache(tableName: "Person")
        let rowBytes = try BSATNEncoder().encode(Person(id: 7, name: "Bob"))
        try firstCache.handleInsert(rowBytes: rowBytes)

        // Re-registering the same table/type must keep the existing cache instance.
        clientCache.registerTable(tableName: "Person", rowType: Person.self)

        let secondCache: TableCache<Person> = clientCache.getTableCache(tableName: "Person")
        XCTAssertTrue(firstCache === secondCache)
        secondCache.sync()
        XCTAssertEqual(secondCache.rows.count, 1)
        XCTAssertEqual(secondCache.rows[0].id, 7)
        XCTAssertEqual(secondCache.rows[0].name, "Bob")
    }

    @MainActor
    func testTableDeltaCallbacksAndDeregister() throws {
        let cache = TableCache<Person>(tableName: "Person")
        let encoder = BSATNEncoder()

        let oldRow = Person(id: 1, name: "Alice")
        let newRow = Person(id: 1, name: "Alicia")
        let oldBytes = try encoder.encode(oldRow)
        let newBytes = try encoder.encode(newRow)

        let inserts = LockIsolated<[Person]>([])
        let deletes = LockIsolated<[Person]>([])
        let updates = LockIsolated<[(Person, Person)]>([])

        let insertHandle = cache.onInsert { person in inserts.withValue { $0.append(person) } }
        let deleteHandle = cache.onDelete { person in deletes.withValue { $0.append(person) } }
        let updateHandle = cache.onUpdate { old, new in
            updates.withValue { $0.append((old, new)) }
        }

        try cache.handleInsert(rowBytes: oldBytes)
        try cache.handleUpdate(oldRowBytes: oldBytes, newRowBytes: newBytes)
        try cache.handleDelete(rowBytes: newBytes)

        XCTAssertEqual(inserts.value, [oldRow])
        XCTAssertEqual(deletes.value, [newRow])
        XCTAssertEqual(updates.value.count, 1)
        XCTAssertEqual(updates.value[0].0, oldRow)
        XCTAssertEqual(updates.value[0].1, newRow)

        insertHandle.cancel()
        deleteHandle.cancel()
        updateHandle.cancel()

        try cache.handleInsert(rowBytes: oldBytes)
        XCTAssertEqual(inserts.value, [oldRow])
        XCTAssertEqual(deletes.value, [newRow])
        XCTAssertEqual(updates.value.count, 1)
    }

    @MainActor
    func testOverlappingInsertsAreRefcountedNotRepeated() throws {
        let cache = TableCache<Person>(tableName: "Person")
        let encoder = BSATNEncoder()
        let alice = Person(id: 1, name: "Alice")
        let bob = Person(id: 2, name: "Bob")
        let aliceBytes = try encoder.encode(alice)
        let bobBytes = try encoder.encode(bob)

        // Two overlapping subscriptions both deliver Alice: she is listed once, held twice.
        try cache.handleBulkInsert(rowBytesList: [aliceBytes, aliceBytes, bobBytes])
        cache.sync()
        XCTAssertEqual(cache.rows.count, 2)
        XCTAssertEqual(cache.rows.filter { $0 == alice }.count, 1)
        XCTAssertEqual(cache.rows.filter { $0 == bob }.count, 1)

        try cache.handleDelete(rowBytes: aliceBytes)
        cache.sync()
        XCTAssertEqual(cache.rows.count, 2)
        XCTAssertEqual(cache.rows.filter { $0 == alice }.count, 1)
        XCTAssertEqual(cache.rows.filter { $0 == bob }.count, 1)

        try cache.handleDelete(rowBytes: aliceBytes)
        cache.sync()
        XCTAssertEqual(cache.rows, [bob])
    }

    @MainActor
    func testClearTablesClearsOnlyThoseTables() throws {
        let clientCache = ClientCache()
        let people = TableCache<Person>(tableName: "Person")
        let others = TableCache<Person>(tableName: "Other")
        clientCache.registerTable(name: "Person", cache: people)
        clientCache.registerTable(name: "Other", cache: others)
        let encoder = BSATNEncoder()
        try people.handleInsert(rowBytes: encoder.encode(Person(id: 1, name: "Stale")))
        try others.handleInsert(rowBytes: encoder.encode(Person(id: 2, name: "Kept")))

        clientCache.clear(tables: ["Person", "Missing"])
        people.sync()
        others.sync()

        XCTAssertEqual(people.rows, [])
        XCTAssertEqual(others.rows, [Person(id: 2, name: "Kept")])
        XCTAssertTrue(clientCache.registeredTableNames.contains("Person"))
    }

    @MainActor
    func testReconcileDiffsCachedRowsAndSkipsIdenticalCallbacks() throws {
        let clientCache = ClientCache()
        let people = TableCache<Person>(tableName: "Person")
        let uncovered = TableCache<Person>(tableName: "Uncovered")
        clientCache.registerTable(name: "Person", cache: people)
        clientCache.registerTable(name: "Uncovered", cache: uncovered)

        let encoder = BSATNEncoder()
        let ada = Person(id: 1, name: "Ada")
        let oldRoom = Person(id: 2, name: "Lobby")
        let newRoom = Person(id: 2, name: "Dealing")
        let bo = Person(id: 3, name: "Bo")
        let staleUncovered = Person(id: 99, name: "Ghost")

        let adaBytes = try encoder.encode(ada)
        let oldRoomBytes = try encoder.encode(oldRoom)
        let newRoomBytes = try encoder.encode(newRoom)
        let boBytes = try encoder.encode(bo)
        let staleUncoveredBytes = try encoder.encode(staleUncovered)

        try people.handleBulkInsert(rowBytesList: [adaBytes, oldRoomBytes])
        try uncovered.handleInsert(rowBytes: staleUncoveredBytes)
        people.sync()
        uncovered.sync()

        let inserts = LockIsolated<[Person]>([])
        let deletes = LockIsolated<[Person]>([])
        let insertHandle = people.onInsert { person in inserts.withValue { $0.append(person) } }
        let deleteHandle = people.onDelete { person in deletes.withValue { $0.append(person) } }
        defer {
            insertHandle.cancel()
            deleteHandle.cancel()
        }

        // Reconnect replays two overlapping subscriptions on Person (Ada in both, NewRoom in sub1, Bo in sub2)
        // and no subscriptions covering Uncovered.
        let sub1 = QueryRows(tables: [
            SingleTableRows(table: RawIdentifier(rawValue: "Person"), rows: makeRowList(rows: [adaBytes, newRoomBytes]))
        ])
        let sub2 = QueryRows(tables: [
            SingleTableRows(table: RawIdentifier(rawValue: "Person"), rows: makeRowList(rows: [adaBytes, boBytes]))
        ])

        clientCache.reconcile(queryRowsList: [sub1, sub2])
        people.sync()
        uncovered.sync()

        XCTAssertEqual(Set(people.rows.map(\.name)), Set(["Ada", "Dealing", "Bo"]))
        XCTAssertEqual(people.rows.count, 3)
        // Unchanged row (Ada) must not fire delete or insert; OldRoom fires delete; NewRoom and Bo fire insert.
        XCTAssertEqual(deletes.value, [oldRoom])
        XCTAssertEqual(Set(inserts.value.map(\.name)), Set(["Dealing", "Bo"]))
        // Table not covered by any replayed subscription is also cleared of ghost rows.
        XCTAssertEqual(uncovered.rows, [])

        // Ada has refcount == 2 from the two overlapping replayed subscriptions, so she survives one delete.
        try people.handleDelete(rowBytes: adaBytes)
        people.sync()
        XCTAssertTrue(people.rows.contains(ada))
        XCTAssertEqual(deletes.value, [oldRoom])

        try people.handleDelete(rowBytes: adaBytes)
        people.sync()
        XCTAssertFalse(people.rows.contains(ada))
        XCTAssertEqual(deletes.value, [oldRoom, ada])
    }

    @MainActor
    func testClearReturnsCacheToDeferredInsertMode() throws {
        let cache = TableCache<Person>(tableName: "Person")
        let encoder = BSATNEncoder()
        let first = try encoder.encode(Person(id: 1, name: "First"))
        let second = Person(id: 2, name: "Second")

        try cache.handleInsert(rowBytes: first)
        try cache.handleDelete(rowBytes: first)
        cache.clear()
        try cache.handleInsert(rowBytes: encoder.encode(second))
        cache.sync()

        XCTAssertEqual(cache.rows, [second])
    }

    @MainActor
    func testClientCachePairsDeleteInsertAsUpdateCallback() throws {
        let clientCache = ClientCache()
        let personCache = TableCache<Person>(tableName: "Person")
        clientCache.registerTable(name: "Person", cache: personCache)

        let encoder = BSATNEncoder()
        let oldRow = Person(id: 42, name: "Alice")
        let newRow = Person(id: 42, name: "Alicia")
        let oldBytes = try encoder.encode(oldRow)
        let newBytes = try encoder.encode(newRow)

        try personCache.handleInsert(rowBytes: oldBytes)

        let updates = LockIsolated<[(Person, Person)]>([])
        let updateHandle = personCache.onUpdate { old, new in
            updates.withValue { $0.append((old, new)) }
        }

        let update = TransactionUpdate(querySets: [
            QuerySetUpdate(
                querySetId: QuerySetId(rawValue: 1),
                tables: [
                    TableUpdate(
                        tableName: RawIdentifier(rawValue: "Person"),
                        rows: [
                            .persistentTable(
                                PersistentTableRows(
                                    inserts: makeRowList(rows: [newBytes]),
                                    deletes: makeRowList(rows: [oldBytes])
                                )
                            )
                        ]
                    )
                ]
            )
        ])

        clientCache.applyTransactionUpdate(update)
        personCache.sync()

        XCTAssertEqual(personCache.rows, [newRow])
        XCTAssertEqual(updates.value.count, 1)
        XCTAssertEqual(updates.value[0].0, oldRow)
        XCTAssertEqual(updates.value[0].1, newRow)

        updateHandle.cancel()
    }

    @MainActor
    func testClientCacheCoalescesObservableSyncForUpdateBurst() async throws {
        let clientCache = ClientCache()
        let personCache = TableCache<Person>(tableName: "Person")
        clientCache.registerTable(name: "Person", cache: personCache)

        let encoder = BSATNEncoder()
        let first = try encoder.encode(Person(id: 1, name: "A"))
        let second = try encoder.encode(Person(id: 2, name: "B"))

        clientCache.applyTransactionUpdate(makeInsertUpdate(row: first, querySetId: 1))
        clientCache.applyTransactionUpdate(makeInsertUpdate(row: second, querySetId: 2))
        XCTAssertTrue(personCache.rows.isEmpty)

        for _ in 0..<20 where personCache.rows.count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(Set(personCache.rows.map(\.id)), Set([1, 2]))
    }

    struct PKPlayer: Codable, Hashable, Sendable, SpacetimePrimaryKeyRow, SpacetimeQueryableRow {
        var id: UInt32
        var name: String
        var score: Int32

        var primaryKey: UInt32 { id }
        static let tableName = "pk_player"

        static func columnName(for keyPath: PartialKeyPath<PKPlayer>) -> String? {
            switch keyPath {
            case \PKPlayer.id: return "id"
            case \PKPlayer.name: return "name"
            case \PKPlayer.score: return "score"
            default: return nil
            }
        }
    }

    @MainActor
    func testPrimaryKeyAwareOutOfOrderBatchUpdatePairingAndReconnect() throws {
        let clientCache = ClientCache()
        let players = TableCache<PKPlayer>(tableName: "pk_player")
        clientCache.registerTable(name: "pk_player", cache: players)

        let encoder = BSATNEncoder()
        let p1Old = PKPlayer(id: 1, name: "Alice", score: 10)
        let p2Old = PKPlayer(id: 2, name: "Bob", score: 20)
        let p1New = PKPlayer(id: 1, name: "Alice", score: 15)
        let p2New = PKPlayer(id: 2, name: "Bob", score: 25)
        let p3Inserted = PKPlayer(id: 3, name: "Charlie", score: 30)

        try players.handleBulkInsert(rowBytesList: [
            try encoder.encode(p1Old),
            try encoder.encode(p2Old),
        ])

        let updates = LockIsolated<[(PKPlayer, PKPlayer)]>([])
        let inserts = LockIsolated<[PKPlayer]>([])
        let deletes = LockIsolated<[PKPlayer]>([])

        let uHandle = players.onUpdate { old, new in updates.withValue { $0.append((old, new)) } }
        let iHandle = players.onInsert { row in inserts.withValue { $0.append(row) } }
        let dHandle = players.onDelete { row in deletes.withValue { $0.append(row) } }
        defer {
            uHandle.cancel()
            iHandle.cancel()
            dHandle.cancel()
        }

        // Deletes are in [p1Old, p2Old] order, while inserts are reversed [p2New, p3Inserted, p1New]!
        // Primary-key pairing must match p1Old->p1New and p2Old->p2New, and emit p3Inserted as an insert.
        let tx = TransactionUpdate(querySets: [
            QuerySetUpdate(
                querySetId: QuerySetId(rawValue: 1),
                tables: [
                    TableUpdate(
                        tableName: RawIdentifier(rawValue: "pk_player"),
                        rows: [
                            .persistentTable(
                                PersistentTableRows(
                                    inserts: makeRowList(rows: [
                                        try encoder.encode(p2New),
                                        try encoder.encode(p3Inserted),
                                        try encoder.encode(p1New),
                                    ]),
                                    deletes: makeRowList(rows: [
                                        try encoder.encode(p1Old),
                                        try encoder.encode(p2Old),
                                    ])
                                )
                            )
                        ]
                    )
                ]
            )
        ])

        clientCache.applyTransactionUpdate(tx)
        players.sync()

        XCTAssertEqual(deletes.value, [])
        XCTAssertEqual(inserts.value, [p3Inserted])
        XCTAssertEqual(updates.value.count, 2)
        XCTAssertTrue(updates.value.contains(where: { $0.0 == p1Old && $0.1 == p1New }))
        XCTAssertTrue(updates.value.contains(where: { $0.0 == p2Old && $0.1 == p2New }))
        XCTAssertEqual(players.find(byPrimaryKey: 1), p1New)
        XCTAssertEqual(players.find(byPrimaryKey: 2), p2New)
        XCTAssertEqual(players.find(byPrimaryKey: 3), p3Inserted)

        // Now test reconnect reconciliation: p1New updates to score 99, p2New is unchanged, p3Inserted is removed.
        updates.withValue { $0.removeAll() }
        inserts.withValue { $0.removeAll() }
        deletes.withValue { $0.removeAll() }

        let p1Reconnected = PKPlayer(id: 1, name: "Alice", score: 99)
        let replayed = QueryRows(tables: [
            SingleTableRows(
                table: RawIdentifier(rawValue: "pk_player"),
                rows: makeRowList(rows: [
                    try encoder.encode(p1Reconnected),
                    try encoder.encode(p2New),
                ])
            )
        ])
        clientCache.reconcile(querySets: [(querySetId: QuerySetId(rawValue: 10), rows: replayed)])
        players.sync()

        XCTAssertEqual(inserts.value, [])
        XCTAssertEqual(deletes.value, [p3Inserted])
        XCTAssertEqual(updates.value.count, 1)
        XCTAssertEqual(updates.value[0].0, p1New)
        XCTAssertEqual(updates.value[0].1, p1Reconnected)
    }

    @MainActor
    func testUniqueAndBTreeSecondaryIndexesStaySynchronized() throws {
        let players = TableCache<PKPlayer>(tableName: "pk_player")
        let encoder = BSATNEncoder()

        let alice = PKPlayer(id: 1, name: "Alice", score: 10)
        let bob = PKPlayer(id: 2, name: "Bob", score: 20)
        let charlie = PKPlayer(id: 3, name: "Charlie", score: 20)
        let diana = PKPlayer(id: 4, name: "Diana", score: 40)

        try players.handleBulkInsert(rowBytesList: [
            try encoder.encode(alice),
            try encoder.encode(bob),
        ])

        // Indexes created after initial rows are populated must include existing rows.
        let idIndex = players.createUniqueIndex(keyPath: \.id)
        let nameIndex = players.createUniqueIndex(keyPath: \.name)
        let scoreIndex = players.createBTreeIndex(keyPath: \.score)

        XCTAssertEqual(idIndex.find(1), alice)
        XCTAssertEqual(nameIndex.find("Bob"), bob)
        XCTAssertEqual(scoreIndex.filter(equal: 20), [bob])

        // Insert Charlie (score 20) and Diana (score 40)
        try players.handleBulkInsert(rowBytesList: [
            try encoder.encode(charlie),
            try encoder.encode(diana),
        ])

        XCTAssertEqual(Set(scoreIndex.filter(equal: 20)), Set([bob, charlie]))
        XCTAssertEqual(scoreIndex.filter(range: 15...40).count, 3)
        XCTAssertEqual(scoreIndex.filter(range: 10..<20), [alice])
        XCTAssertEqual(scoreIndex.filter(range: 25...), [diana])
        XCTAssertEqual(scoreIndex.filter(range: ...10), [alice])
        XCTAssertEqual(scoreIndex.filter(range: ..<20), [alice])

        // Update Alice's score from 10 to 50
        let aliceUpdated = PKPlayer(id: 1, name: "Alice", score: 50)
        try players.handleUpdate(
            oldRowBytes: try encoder.encode(alice),
            newRowBytes: try encoder.encode(aliceUpdated)
        )

        XCTAssertEqual(idIndex.find(1), aliceUpdated)
        XCTAssertEqual(scoreIndex.filter(equal: 10), [])
        XCTAssertEqual(scoreIndex.filter(equal: 50), [aliceUpdated])

        // Delete Bob
        try players.handleDelete(rowBytes: try encoder.encode(bob))
        XCTAssertNil(idIndex.find(2))
        XCTAssertNil(nameIndex.find("Bob"))
        XCTAssertEqual(scoreIndex.filter(equal: 20), [charlie])
    }

    @MainActor
    func testPerQuerySetTrackingAndClientSideEviction() throws {
        let clientCache = ClientCache()
        let players = TableCache<PKPlayer>(tableName: "pk_player")
        clientCache.registerTable(name: "pk_player", cache: players)

        let encoder = BSATNEncoder()
        let sharedRow = PKPlayer(id: 1, name: "Shared", score: 10)
        let exclusiveRow = PKPlayer(id: 2, name: "ExclusiveToSub1", score: 20)
        let sharedBytes = try encoder.encode(sharedRow)
        let exclusiveBytes = try encoder.encode(exclusiveRow)

        let qs1 = QuerySetId(rawValue: 101)
        let qs2 = QuerySetId(rawValue: 202)

        try players.applyQuerySetTransition(
            querySetId: qs1,
            deleteRowBytesList: [],
            insertRowBytesList: [sharedBytes, exclusiveBytes]
        )
        try players.applyQuerySetTransition(
            querySetId: qs2,
            deleteRowBytesList: [],
            insertRowBytesList: [sharedBytes]
        )
        players.sync()
        XCTAssertEqual(Set(players.rows), Set([sharedRow, exclusiveRow]))

        let deletes = LockIsolated<[PKPlayer]>([])
        let handle = players.onDelete { row in deletes.withValue { $0.append(row) } }
        defer { handle.cancel() }

        // Evicting qs1 drops exclusiveRow (refcount 1 -> 0) and decrements sharedRow (refcount 2 -> 1).
        clientCache.evictQuerySet(qs1)
        players.sync()

        XCTAssertEqual(players.rows, [sharedRow])
        XCTAssertEqual(deletes.value, [exclusiveRow])

        // Evicting qs2 drops sharedRow (refcount 1 -> 0).
        clientCache.evictQuerySet(qs2)
        players.sync()

        XCTAssertEqual(players.rows, [])
        XCTAssertEqual(deletes.value, [exclusiveRow, sharedRow])
    }

    func testTypedQueryBuilderGeneratesExpectedSQL() {
        let queryAll = TableQuery<PKPlayer>().sql
        XCTAssertEqual(queryAll, "SELECT * FROM pk_player")

        let filtered = TableQuery<PKPlayer>()
            .where(\.name, equals: "O'Connor")
            .where(\.score, greaterThanOrEqual: 100)
            .sql
        XCTAssertEqual(filtered, "SELECT * FROM pk_player WHERE name = 'O''Connor' AND score >= 100")

        let colScore = SQLColumn<PKPlayer, Int32>(\.score)
        let colId = SQLColumn<PKPlayer, UInt32>(\.id)
        let compound = TableQuery<PKPlayer>()
            .where((colScore > 50 && colScore <= 200) || colId == 1)
            .sql
        XCTAssertEqual(compound, "SELECT * FROM pk_player WHERE ((score > 50 AND score <= 200) OR id = 1)")
    }

    @MainActor
    func testAsyncStreamsYieldInsertsUpdatesAndDeletes() async throws {
        let players = TableCache<PKPlayer>(tableName: "pk_player")
        let encoder = BSATNEncoder()
        let p1 = PKPlayer(id: 1, name: "One", score: 1)
        let p1Updated = PKPlayer(id: 1, name: "OneUpdated", score: 2)

        var insertIterator = players.inserts.makeAsyncIterator()
        var updateIterator = players.updates.makeAsyncIterator()
        var deleteIterator = players.deletes.makeAsyncIterator()

        try players.handleInsert(rowBytes: try encoder.encode(p1))
        try players.handleUpdate(
            oldRowBytes: try encoder.encode(p1),
            newRowBytes: try encoder.encode(p1Updated)
        )
        try players.handleDelete(rowBytes: try encoder.encode(p1Updated))

        let inserted = await insertIterator.next()
        let updated = await updateIterator.next()
        let deleted = await deleteIterator.next()

        XCTAssertEqual(inserted, p1)
        XCTAssertEqual(updated?.oldRow, p1)
        XCTAssertEqual(updated?.newRow, p1Updated)
        XCTAssertEqual(deleted, p1Updated)
    }

    @MainActor
    func testClientCacheDiskSnapshotSaveAndLoadRoundTrip() throws {
        let encoder = BSATNEncoder()
        let p1 = PKPlayer(id: 1, name: "SavedAlice", score: 42)
        let p2 = PKPlayer(id: 2, name: "SavedBob", score: 84)

        let sourceCache = ClientCache()
        let sourcePlayers = TableCache<PKPlayer>(tableName: "pk_player")
        sourceCache.registerTable(name: "pk_player", cache: sourcePlayers)
        try sourcePlayers.handleBulkInsert(rowBytesList: [
            try encoder.encode(p1),
            try encoder.encode(p2),
        ])

        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("spacetimedb_snapshot_\(UUID().uuidString).bsatn")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }

        try sourceCache.saveSnapshot(to: snapshotURL)

        let targetCache = ClientCache()
        let targetPlayers = TableCache<PKPlayer>(tableName: "pk_player")
        targetCache.registerTable(name: "pk_player", cache: targetPlayers)

        try targetCache.loadSnapshot(from: snapshotURL)
        targetPlayers.sync()

        XCTAssertEqual(Set(targetPlayers.rows), Set([p1, p2]))
        XCTAssertEqual(targetPlayers.find(byPrimaryKey: 1), p1)
        XCTAssertEqual(targetPlayers.find(byPrimaryKey: 2), p2)
    }

    private func makeRowList(rows: [Data]) -> BsatnRowList {
        var rowsData = Data()
        var offsets: [UInt64] = []
        offsets.reserveCapacity(rows.count)
        for row in rows {
            offsets.append(UInt64(rowsData.count))
            rowsData.append(row)
        }
        return BsatnRowList(sizeHint: .rowOffsets(offsets), rowsData: rowsData)
    }

    private func makeInsertUpdate(row: Data, querySetId: UInt32) -> TransactionUpdate {
        TransactionUpdate(querySets: [
            QuerySetUpdate(
                querySetId: QuerySetId(rawValue: querySetId),
                tables: [
                    TableUpdate(
                        tableName: RawIdentifier(rawValue: "Person"),
                        rows: [
                            .persistentTable(
                                PersistentTableRows(
                                    inserts: makeRowList(rows: [row]),
                                    deletes: .empty
                                )
                            )
                        ]
                    )
                ]
            )
        ])
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(_ value: T) {
        var copy = value.littleEndian
        self.append(Swift.withUnsafeBytes(of: &copy) { Data($0) })
    }
}
