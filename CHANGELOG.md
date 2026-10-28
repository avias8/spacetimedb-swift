# Changelog

## 1.0.0 - 2026-10-27

- Add `v3.bsatn.spacetimedb` WebSocket wire protocol negotiation, bounded outbound multi-message frame batching (`WebSocketV3Frames`), and inbound multi-message frame decoding alongside `v2.bsatn.spacetimedb`.
- Add per-`QuerySetId` row membership tracking and deterministic query-set eviction (`ClientCache.evictQuerySet(_:)`, `TableCache.evictQuerySet(_:)`) on `unsubscribe()` or subscription error.
- Add instance-scoped `ClientCache` on `SpacetimeClient` (`client.cache`) so multiple `SpacetimeClient` connections can run concurrently in the same process while preserving `SpacetimeClient.clientCache` as the default.
- Add `SpacetimePrimaryKeyRow` primary-key identity tracking, $O(1)$ `TableCache.find(byPrimaryKey:)`, and automatic `onUpdate(oldRow, newRow)` pairing across incremental transactions and reconnect reconciliations.
- Add client-side `UniqueIndex<Row, Key>` ($O(1)$ `.find(_:)`) and `BTreeIndex<Row, Key>` ($O(\log N)$ `.filter(from:through:)`, `.filter(from:to:)`).
- Add `KeyPath`-based `TableQuery<Row>` SQL subscription builder (`SpacetimeQueryableRow`, `SQLColumn`, `SQLPredicate`).
- Add SwiftUI `@SpacetimeQuery` `DynamicProperty` wrapper and structured concurrency `AsyncSequence` streams (`table.inserts`, `table.deletes`, `table.updates`, `client.connectionStates`).
- Add `SpacetimeDBCodegenPlugin` SPM build tool plugin, `SpacetimeTableDescriptor`, `@SpacetimePrimaryKey`, `@SpacetimeUniqueIndexed`, `@SpacetimeBTreeIndexed`, and `SpacetimeSchemaValidator`.
- Add `lightMode` and `confirmedReads` connection options on `SpacetimeClient`.
- Add optimistic reducer predictions (`OptimisticRowChange`, `client.send(_:_:optimisticChanges:)`) with automatic commit/rollback on `ReducerResult` or disconnect.
- Add BSATN disk snapshot persistence (`ClientCache.saveSnapshot(to:)`, `ClientCache.loadSnapshot(from:)`).
- Add pluggable `WebSocketTransport` protocol, `URLSessionWebSocketTransport`, deterministic chaos & soak testing (`ChaosSoakTests`), `tvOS` support, and GitHub Actions CI matrix (`.github/workflows/ci.yml`).
- Update `spacetime generate --lang swift` in `crates/codegen/src/swift.rs` to emit `SpacetimeTableDescriptor`, `SpacetimePrimaryKeyRow`, `SpacetimeQueryableRow`, instance-scoped `ClientCache` registration, and optimistic/async reducer and procedure overloads.

## 0.24.0 - 2026-10-27

- Remove implicit `subscribeAll(tables:)` on `InitialConnection` so explicit client subscriptions govern local cache replication by default, while routing explicit `subscribeAll(tables:)` calls through managed subscriptions for automatic reconnect replay.
- Deduplicate `TableCache.rows` across overlapping subscriptions so `RowEntry.count` acts as a subscription reference count rather than row multiplicity.
- Make `TableCache` `onInsert` and `onDelete` delta callbacks refcount-aware (`0 -> 1` and `1 -> 0`), matching the Rust and TypeScript SDKs.
- Add `TableCache.reconcile(rowBytesList:)`, `ClientCache.reconcile(queryRowsList:replacingTables:)`, and `ClientCache.clear(tables:)` to diff cached rows against replayed subscription snapshots on reconnect without ghost rows, redundant BSATN decoding, or duplicate callbacks.
- Batch replayed subscriptions across `resubscribeManagedSubscriptions()` in `SpacetimeClient` and buffer mid-replay `TransactionUpdate`s so multi-subscription reconnects reconcile atomically.

## 0.23.0 - 2026-07-17

- Update the Swift SDK release line for compatibility with SpacetimeDB 2.7.0.
- Preserve Swift code generation and CLI language detection across the 2.7.0 upstream merge.
- Preserve generated Ninja, simple-module, and keynote client compatibility.
- Validate the Network.framework WebSocket transport and Swift 6 concurrency paths under Thread Sanitizer.
- Validate all 83 package tests, with four opt-in live integration tests skipped by default.
- Validate SDK, demo, keynote, DocC, benchmark, Rust codegen, and TypeScript integration checks.
- Validate generated Swift procedure callbacks against a live SpacetimeDB 2.7.0 server.

## 0.22.0 - 2026-07-17

- Reassemble fragmented WebSocket messages, including large subscription snapshots.
- Validate HTTP upgrades, selected subprotocols, frame structure, and control-frame rules.
- Bound frame and reassembled-message sizes to prevent unbounded buffering.
- Ignore stale `NWConnection` callbacks after reconnect and report remote close frames.
- Protect all transport state with Swift 6 `Mutex<State>` and remove unchecked sendability from the transport.
- Build masked client frames in one allocation and perform graceful WebSocket close handshakes.
- Protect observability and async continuation state with Swift 6 synchronization while keeping disabled metrics on an atomic fast path.
- Coalesce cache-to-observation synchronization so update bursts create fewer main-actor tasks.
- Make the process-wide client cache an immutable, thread-safe singleton.
- Make subscription callbacks explicitly main-actor isolated and sendable, removing unchecked sendability from `SubscriptionHandle`.
- Add statically dispatched and inlined BSATN codecs, direct client/server message paths, and hybrid no-copy encoder storage.
- Defer cache-index materialization and batch transaction inserts, raising generated-row bulk insertion above 7 million rows per second in local Apple Silicon benchmarks.
- Move benchmarks to an isolated nested package so SDK consumers have no third-party dependencies.
- Add standalone package CI, including Thread Sanitizer coverage, and align documented Apple deployment targets with `Package.swift`.
- Add the applicable SpacetimeDB Business Source License.

## 0.21.0 - 2026-03-03

- Mirrored `sdks/swift` from upstream `swift-integration` through commit `3ee44cea6`.
- Completed NW transport integration by adding `NWWebSocketTransport`.
- Updated `SpacetimeClient` for Swift 6 performance and concurrency improvements.
- Updated SDK surface wiring in `SpacetimeDB.swift` for the new transport/client behavior.
- Included generated/demo compatibility updates used by Ninja and keynote Swift clients.
- Refreshed mirror README dependency snippet for release consumption from GitHub.
- Updated distribution runbook examples to release as `0.21.0`.
- Updated SPI checklist release version default to `0.21.0`.
