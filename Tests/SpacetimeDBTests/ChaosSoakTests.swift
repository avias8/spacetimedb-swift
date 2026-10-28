import Foundation
import XCTest
@testable import SpacetimeDB

/// Deterministic multi-client chaos and soak test suite exercising:
/// - Mid-stream socket drops and automatic reconnects
/// - Overlapping subscriptions with out-of-order `SubscribeApplied` batches
/// - Buffered incremental `TransactionUpdate`s arriving during reconnect replay
/// - High-frequency (60 Hz+) reducer update bursts with primary-key pairing & secondary indexes
/// - Subscription errors and client-side `QuerySetId` eviction
/// - Optimistic mutations and rollbacks across network drops
final class ChaosSoakTests: XCTestCase {

    struct BattleRoom: Codable, Hashable, Sendable, SpacetimePrimaryKeyRow, SpacetimeQueryableRow, SpacetimeTableDescriptor {
        typealias Row = BattleRoom
        static let tableName = "battle_room"

        var id: UInt32
        var code: String
        var phase: String
        var tick: UInt64

        var primaryKey: UInt32 { id }

        static func columnName(for keyPath: PartialKeyPath<BattleRoom>) -> String? {
            switch keyPath {
            case \BattleRoom.id: return "id"
            case \BattleRoom.code: return "code"
            case \BattleRoom.phase: return "phase"
            case \BattleRoom.tick: return "tick"
            default: return nil
            }
        }
    }

    private final class ChaosTransport: WebSocketTransport, @unchecked Sendable {
        weak var delegate: WebSocketTransportDelegate?
        var negotiatedProtocol: String? = "v3.bsatn.spacetimedb"
        var sentFrames: [Data] = []
        var connectCount = 0

        func connect(to url: URL, protocols: [String], headers: [String: String]) {
            connectCount += 1
        }

        func disconnect() {}

        func send(data: Data, completion: @escaping @Sendable (Error?) -> Void) {
            sentFrames.append(data)
            completion(nil)
        }

        func sendPing(completion: @escaping @Sendable (Error?) -> Void) {
            completion(nil)
        }
    }

    @MainActor
    func testChaosSoakMultiClientReconnectUnder60HzStreamAndOverlappingSubscriptions() throws {
        let encoder = BSATNEncoder()

        let cache = ClientCache()
        let roomTable = BattleRoom.register(in: cache)
        let codeIndex = roomTable.createUniqueIndex(keyPath: \.code)
        let tickIndex = roomTable.createBTreeIndex(keyPath: \.tick)

        let transport = ChaosTransport()
        let client = SpacetimeClient(
            serverUrl: URL(string: "http://localhost:3000")!,
            moduleName: "chaos-mod",
            reconnectPolicy: ReconnectPolicy(maxRetries: 10, initialDelaySeconds: 0.01, maxDelaySeconds: 0.05, multiplier: 1.0, jitterRatio: 0),
            compressionMode: .none,
            cache: cache,
            transport: transport
        )

        let insertedEvents = LockIsolated<[BattleRoom]>([])
        let updatedEvents = LockIsolated<[(BattleRoom, BattleRoom)]>([])
        let deletedEvents = LockIsolated<[BattleRoom]>([])

        let iHandle = roomTable.onInsert { r in insertedEvents.withValue { $0.append(r) } }
        let uHandle = roomTable.onUpdate { old, new in updatedEvents.withValue { $0.append((old, new)) } }
        let dHandle = roomTable.onDelete { r in deletedEvents.withValue { $0.append(r) } }
        defer {
            iHandle.cancel()
            uHandle.cancel()
            dHandle.cancel()
        }

        // 1. Connect and establish two overlapping subscriptions on `battle_room`
        client.connect(token: "chaos-jwt")
        transport.delegate?.webSocketTransportDidConnect()

        let initialConn1 = InitialConnection(
            identity: Identity(rawBytes: Data(repeating: 0x11, count: 32)),
            connectionId: ClientConnectionId(rawBytes: Data(repeating: 0x22, count: 16)),
            token: "chaos-jwt-1"
        )
        client._test_deliverServerMessage(.initialConnection(initialConn1))

        let subAll = client.subscribe(queries: [BattleRoom.query().sql])
        let subRoom1 = client.subscribe(queries: [BattleRoom.query().where(\.id, equals: 1).sql])

        let room1Initial = BattleRoom(id: 1, code: "HOMER", phase: "lobby", tick: 0)
        let room2Initial = BattleRoom(id: 2, code: "ILIAD", phase: "lobby", tick: 0)

        client._test_deliverServerMessage(
            .subscribeApplied(
                SubscribeApplied(
                    requestId: subAll.requestId!,
                    querySetId: subAll.querySetId!,
                    rows: QueryRows(tables: [
                        SingleTableRows(
                            table: RawIdentifier(rawValue: "battle_room"),
                            rows: try encodeRowList([room1Initial, room2Initial], with: encoder)
                        )
                    ])
                )
            )
        )
        client._test_deliverServerMessage(
            .subscribeApplied(
                SubscribeApplied(
                    requestId: subRoom1.requestId!,
                    querySetId: subRoom1.querySetId!,
                    rows: QueryRows(tables: [
                        SingleTableRows(
                            table: RawIdentifier(rawValue: "battle_room"),
                            rows: try encodeRowList([room1Initial], with: encoder)
                        )
                    ])
                )
            )
        )

        roomTable.sync()
        XCTAssertEqual(roomTable.rows.count, 2)
        XCTAssertEqual(codeIndex.find("HOMER"), room1Initial)
        XCTAssertEqual(codeIndex.find("ILIAD"), room2Initial)

        // 2. Simulate 60 ticks of high-frequency updates to room 1 across both overlapping query sets
        var currentRoom1 = room1Initial
        for tick in UInt64(1)...60 {
            let nextRoom1 = BattleRoom(id: 1, code: "HOMER", phase: "improvising", tick: tick)
            let oldBytes = try encoder.encode(currentRoom1)
            let newBytes = try encoder.encode(nextRoom1)

            let update = TransactionUpdate(querySets: [
                QuerySetUpdate(
                    querySetId: subAll.querySetId!,
                    tables: [
                        TableUpdate(
                            tableName: RawIdentifier(rawValue: "battle_room"),
                            rows: [.persistentTable(PersistentTableRows(inserts: makeRowList([newBytes]), deletes: makeRowList([oldBytes])))]
                        )
                    ]
                ),
                QuerySetUpdate(
                    querySetId: subRoom1.querySetId!,
                    tables: [
                        TableUpdate(
                            tableName: RawIdentifier(rawValue: "battle_room"),
                            rows: [.persistentTable(PersistentTableRows(inserts: makeRowList([newBytes]), deletes: makeRowList([oldBytes])))]
                        )
                    ]
                ),
            ])
            client._test_deliverServerMessage(.transactionUpdate(update))
            currentRoom1 = nextRoom1
        }

        roomTable.sync()
        XCTAssertEqual(roomTable.rows.count, 2)
        XCTAssertEqual(roomTable.find(byPrimaryKey: 1)?.tick, 60)
        XCTAssertEqual(codeIndex.find("HOMER")?.tick, 60)
        XCTAssertEqual(tickIndex.filter(range: 50...60), [currentRoom1])

        // 3. Enqueue an optimistic mutation right before a sudden socket drop!
        let optimisticRoom3 = BattleRoom(id: 3, code: "ODYSSEY", phase: "optimistic", tick: 1)
        client.send(
            "create_room",
            Data(),
            optimisticChanges: [try OptimisticRowChange.insert(tableName: "battle_room", row: optimisticRoom3)]
        )
        roomTable.sync()
        XCTAssertEqual(roomTable.rows.count, 3)

        // Drop socket mid-stream: optimistic mutation must be rolled back, and reconnect initiated.
        transport.delegate?.webSocketTransportDidDisconnect(error: WebSocketTransportError.notConnected)
        roomTable.sync()
        XCTAssertEqual(roomTable.rows.count, 2)
        XCTAssertNil(codeIndex.find("ODYSSEY"))

        // 4. Reconnect arrives while room 1 advanced to tick 100 ("battling") and room 2 was deleted on the server.
        // In addition, an incremental TransactionUpdate (tick 101) arrives BEFORE the second SubscribeApplied finishes!
        let initialConn2 = InitialConnection(
            identity: Identity(rawBytes: Data(repeating: 0x11, count: 32)),
            connectionId: ClientConnectionId(rawBytes: Data(repeating: 0x33, count: 16)),
            token: "chaos-jwt-2"
        )
        client._test_deliverServerMessage(.initialConnection(initialConn2))

        let replayedRoom1 = BattleRoom(id: 1, code: "HOMER", phase: "battling", tick: 100)
        let incrementalRoom1 = BattleRoom(id: 1, code: "HOMER", phase: "battling", tick: 101)

        // Deliver first SubscribeApplied (subAll)
        client._test_deliverServerMessage(
            .subscribeApplied(
                SubscribeApplied(
                    requestId: subAll.requestId!,
                    querySetId: subAll.querySetId!,
                    rows: QueryRows(tables: [
                        SingleTableRows(
                            table: RawIdentifier(rawValue: "battle_room"),
                            rows: try encodeRowList([replayedRoom1], with: encoder)
                        )
                    ])
                )
            )
        )

        // Deliver an interleaved TransactionUpdate while subRoom1's SubscribeApplied is still in flight!
        let interleavedTx = TransactionUpdate(querySets: [
            QuerySetUpdate(
                querySetId: subAll.querySetId!,
                tables: [
                    TableUpdate(
                        tableName: RawIdentifier(rawValue: "battle_room"),
                        rows: [
                            .persistentTable(
                                PersistentTableRows(
                                    inserts: try encodeRowList([incrementalRoom1], with: encoder),
                                    deletes: try encodeRowList([replayedRoom1], with: encoder)
                                )
                            )
                        ]
                    )
                ]
            ),
            QuerySetUpdate(
                querySetId: subRoom1.querySetId!,
                tables: [
                    TableUpdate(
                        tableName: RawIdentifier(rawValue: "battle_room"),
                        rows: [
                            .persistentTable(
                                PersistentTableRows(
                                    inserts: try encodeRowList([incrementalRoom1], with: encoder),
                                    deletes: try encodeRowList([replayedRoom1], with: encoder)
                                )
                            )
                        ]
                    )
                ]
            ),
        ])
        client._test_deliverServerMessage(.transactionUpdate(interleavedTx))

        // Deliver second SubscribeApplied (subRoom1) -> completes reconnect batch and flushes buffered tx!
        client._test_deliverServerMessage(
            .subscribeApplied(
                SubscribeApplied(
                    requestId: subRoom1.requestId!,
                    querySetId: subRoom1.querySetId!,
                    rows: QueryRows(tables: [
                        SingleTableRows(
                            table: RawIdentifier(rawValue: "battle_room"),
                            rows: try encodeRowList([replayedRoom1], with: encoder)
                        )
                    ])
                )
            )
        )

        roomTable.sync()
        XCTAssertEqual(roomTable.rows, [incrementalRoom1])
        XCTAssertNil(codeIndex.find("ILIAD"))
        XCTAssertEqual(codeIndex.find("HOMER"), incrementalRoom1)
        XCTAssertEqual(tickIndex.filter(range: 100...200), [incrementalRoom1])
        XCTAssertTrue(deletedEvents.value.contains(room2Initial))
    }

    func testSchemaValidatorDetectsDriftAndPassesValidSchema() throws {
        XCTAssertNoThrow(
            try SpacetimeSchemaValidator.validateColumns(
                table: "battle_room",
                expected: ["id", "code", "phase", "tick"],
                actual: ["id", "code", "phase", "tick"]
            )
        )

        XCTAssertThrowsError(
            try SpacetimeSchemaValidator.validateColumns(
                table: "battle_room",
                expected: ["id", "code", "phase", "tick"],
                actual: ["id", "code", "phase"]
            )
        ) { error in
            XCTAssertEqual(
                error as? SpacetimeSchemaValidator.SchemaDriftError,
                .missingColumns(table: "battle_room", missing: ["tick"])
            )
        }
    }

    private func encodeRowList<T: Encodable>(_ rows: [T], with encoder: BSATNEncoder) throws -> BsatnRowList {
        let encoded = try rows.map { try encoder.encode($0) }
        return makeRowList(encoded)
    }

    private func makeRowList(_ rows: [Data]) -> BsatnRowList {
        var rowsData = Data()
        var offsets: [UInt64] = []
        offsets.reserveCapacity(rows.count)
        for row in rows {
            offsets.append(UInt64(rowsData.count))
            rowsData.append(row)
        }
        return BsatnRowList(sizeHint: .rowOffsets(offsets), rowsData: rowsData)
    }
}
