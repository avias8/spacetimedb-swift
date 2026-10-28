# ``SpacetimeDB``

Native Swift SDK for SpacetimeDB realtime clients across Apple platforms (`macOS`, `iOS`, `tvOS`, `visionOS`, `watchOS`).

## Overview

`SpacetimeDB` provides:

- BSATN protocol encoding/decoding
- `v3.bsatn.spacetimedb` and `v2.bsatn.spacetimedb` WebSocket transports (`NWWebSocketTransport` and `URLSessionWebSocketTransport`) with reconnect reconciliation and outbound frame batching
- Typed table cache integration (`ClientCache`, `TableCache`) with primary-key identity (`SpacetimePrimaryKeyRow`) and client-side indexes (`UniqueIndex`, `BTreeIndex`)
- Type-safe `KeyPath` SQL query builder (`TableQuery`, `SQLColumn`, `SQLPredicate`) and SwiftUI `@SpacetimeQuery`
- Optimistic reducer mutations (`OptimisticRowChange`) and offline BSATN disk snapshots
- Reducer/procedure/query client APIs and `AsyncSequence` streams
- Apple platform support for macOS, iOS, tvOS, visionOS, and watchOS

## Key Types

- ``SpacetimeClient``
- ``SpacetimeClientDelegate``
- ``SpacetimeWireProtocol``
- ``WebSocketV3Frames``
- ``URLSessionWebSocketTransport``
- ``ReconnectPolicy``
- ``CompressionMode``
- ``SubscriptionHandle``
- ``ClientCache``
- ``TableCache``
- ``SpacetimePrimaryKeyRow``
- ``UniqueIndex``
- ``BTreeIndex``
- ``TableQuery``
- ``SQLColumn``
- ``SQLPredicate``
- ``OptimisticRowChange``
- ``SpacetimeTableDescriptor``
- ``SpacetimeSchemaValidator``
- ``KeychainTokenStore``

## Tutorials

- [Tutorial: Build Your First SpacetimeDB Swift Client](doc:Tutorial-Build-First-Client)
- [Tutorial: Auth Tokens, Keychain, and Reconnect](doc:Tutorial-Auth-Reconnect)

## Publishing

- [Publishing DocC and Swift Package Index Releases](doc:Publishing-and-Swift-Package-Index)
- [Apple CI Matrix (macOS, iOS Simulator)](doc:Apple-CI-Matrix)
