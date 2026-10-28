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
