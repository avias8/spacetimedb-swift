# SpacetimeDB Swift SDK

Native Swift SDK for connecting to SpacetimeDB over `v2.bsatn.spacetimedb`, decoding realtime updates, and maintaining a typed local cache.

[![Swift Package Index](https://img.shields.io/badge/Swift%20Package%20Index-spacetimedb--swift-orange)](https://swiftpackageindex.com/avias8/spacetimedb-swift)
[![Swift Versions](https://img.shields.io/endpoint?url=https://swiftpackageindex.com/api/packages/avias8/spacetimedb-swift/badge?type=swift-versions)](https://swiftpackageindex.com/avias8/spacetimedb-swift)
[![Platforms](https://img.shields.io/endpoint?url=https://swiftpackageindex.com/api/packages/avias8/spacetimedb-swift/badge?type=platforms)](https://swiftpackageindex.com/avias8/spacetimedb-swift)

## Contents

- [Requirements](#requirements)
- [Package Layout](#package-layout)
- [Add The SDK To A Swift Package](#add-the-sdk-to-a-swift-package)
- [Quick Start](#quick-start)
- [Core API](#core-api)
- [Auth Token Persistence (Keychain)](#auth-token-persistence-keychain)
- [Network Awareness And Reconnect Behavior](#network-awareness-and-reconnect-behavior)
- [Distribution Hardening](#distribution-hardening)
- [DocC and Swift Package Index](#docc-and-swift-package-index)
- [Apple CI Matrix](#apple-ci-matrix)
- [Logging](#logging)
- [Benchmarks](#benchmarks)
- [Validation Matrix](#validation-matrix)
- [License](#license)

## Requirements

- Swift tools `6.2`
- Apple platforms:
  - macOS `15+`
  - iOS `18+`
  - visionOS `2+`
  - watchOS `11+`

## Package Layout

```text
spacetimedb-swift
├── Package.swift
├── Benchmarks/Package.swift
├── Sources/SpacetimeDB
│   ├── Auth/KeychainTokenStore.swift
│   ├── BSATN/
│   ├── Cache/
│   ├── Network/
│   ├── Log.swift
│   ├── RuntimeTypes.swift
│   └── SpacetimeDB.swift
└── Tests/SpacetimeDBTests
```

## Add The SDK To A Swift Package

From GitHub releases (recommended):

```swift
dependencies: [
    .package(url: "https://github.com/avias8/spacetimedb-swift.git", from: "0.24.0"),
],
targets: [
    .executableTarget(
        name: "MyClient",
        dependencies: [
            .product(name: "SpacetimeDB", package: "spacetimedb-swift"),
        ]
    ),
]
```

From a local checkout:

```swift
dependencies: [
    .package(path: "../spacetimedb-swift"),
],
targets: [
    .executableTarget(
        name: "MyClient",
        dependencies: [
            .product(name: "SpacetimeDB", package: "spacetimedb-swift"),
        ]
    ),
]
```

Then import in code:

```swift
import SpacetimeDB
```

## Quick Start

```swift
import Foundation
import SpacetimeDB

@MainActor
final class AppModel: SpacetimeClientDelegate {
    private var client: SpacetimeClient?

    func start() {
        SpacetimeModule.registerTables()

        let client = SpacetimeClient(
            serverUrl: URL(string: "http://127.0.0.1:3000")!,
            moduleName: "my-module"
        )
        client.delegate = self
        client.connect()
        self.client = client
    }

    func stop() {
        client?.disconnect()
        client = nil
    }

    // MARK: SpacetimeClientDelegate
    func onConnect() {}
    func onDisconnect(error: Error?) {}
    func onIdentityReceived(identity: [UInt8], token: String) {}
    func onTransactionUpdate(message: Data?) {}
    func onReducerError(reducer: String, message: String, isInternal: Bool) {}
}
```

## Core API

### Connect/Disconnect

```swift
let client = SpacetimeClient(serverUrl: url, moduleName: "my-module")
client.delegate = delegate
client.connect(token: optionalBearerToken)
client.disconnect()
```

### Reducers

```swift
client.send("add_person", argsData)
```

### Procedures

Typed callback:

```swift
client.sendProcedure("hello", argsData, responseType: String.self) { result in
    // Result<String, Error>
}
```

Raw callback:

```swift
client.sendProcedure("hello", argsData) { result in
    // Result<Data, Error>
}
```

`async/await`:

```swift
let rawData = try await client.sendProcedure("hello", argsData)
let value = try await client.sendProcedure("hello", argsData, responseType: String.self)
let timed = try await client.sendProcedure("hello", argsData, timeout: .seconds(5))
let typedTimed = try await client.sendProcedure("hello", argsData, responseType: String.self, timeout: .seconds(5))
```

### One-Off Queries

Callback:

```swift
client.oneOffQuery("SELECT * FROM person") { result in
    // Result<QueryRows, Error>
}
```

`async/await`:

```swift
let rows = try await client.oneOffQuery("SELECT * FROM person")
let timedRows = try await client.oneOffQuery("SELECT * FROM person", timeout: .seconds(3))
```

Cancellation: cancel the task calling an async procedure/query API, and it throws `CancellationError` while removing the pending callback state.

### Subscriptions

```swift
let handle = client.subscribe(
    queries: ["SELECT * FROM person"],
    onApplied: { /* initial snapshot applied */ },
    onError: { message in /* subscription failed */ }
)

handle.unsubscribe()
```

### Client Cache

Register tables once, then read typed rows from generated caches:

```swift
SpacetimeModule.registerTables()
let people = PersonTable.cache.rows
```

The SDK applies transaction updates into `SpacetimeClient.clientCache`. Internal cache mutation remains off the main actor; observable `rows` snapshots are coalesced and published on the main actor for SwiftUI safety.

## Auth Token Persistence (Keychain)

`KeychainTokenStore` provides opt-in token persistence per module:

```swift
let tokenStore = KeychainTokenStore(service: "com.example.myapp.spacetimedb")

// Load on app start.
let savedToken = tokenStore.load(forModule: "my-module")
client.connect(token: savedToken)

// Save when identity/token arrives.
func onIdentityReceived(identity: [UInt8], token: String) {
    tokenStore.save(token: token, forModule: "my-module")
}
```

## Network Awareness And Reconnect Behavior

`SpacetimeClient` supports reconnect backoff through `ReconnectPolicy`:

```swift
let policy = ReconnectPolicy(
    maxRetries: nil,
    initialDelaySeconds: 1.0,
    maxDelaySeconds: 30.0,
    multiplier: 2.0,
    jitterRatio: 0.2
)
```

Network path changes are monitored internally. When the device is offline, reconnect attempts are deferred; when connectivity returns, reconnect is retriggered automatically.

Compression mode can be set at client construction:

```swift
let client = SpacetimeClient(
    serverUrl: url,
    moduleName: "my-module",
    reconnectPolicy: policy,
    compressionMode: .gzip // .none | .gzip | .brotli
)
```

## Distribution Hardening

The Swift package is validated in CI for reproducibility and packaging health:

- `swift test`
- `swift test --sanitize=thread`
- `swift build -c release`
- iOS, visionOS, and watchOS simulator cross-builds
- an isolated benchmark package that does not add dependencies to SDK consumers

## DocC and Swift Package Index

DocC bundle and tutorials live in:

- `Sources/SpacetimeDB/SpacetimeDB.docc`

DocC build command:

```bash
xcodebuild docbuild \
  -scheme SpacetimeDB \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Swift Package Index builder config is in:

- `.spi.yml`

Detailed publishing runbook:

- `PUBLISHING.md`
- `DISTRIBUTION.md`
- `SPI_SUBMISSION_CHECKLIST.md`

Package page and badge endpoints:

```text
Package: https://swiftpackageindex.com/avias8/spacetimedb-swift
Swift versions badge: https://img.shields.io/endpoint?url=https://swiftpackageindex.com/api/packages/avias8/spacetimedb-swift/badge?type=swift-versions
Platforms badge: https://img.shields.io/endpoint?url=https://swiftpackageindex.com/api/packages/avias8/spacetimedb-swift/badge?type=platforms
```

## Apple CI Matrix

Swift CI runs from `.github/workflows/ci.yml`:

- `macOS`: build, unit tests, Thread Sanitizer, and DocC
- `iOS simulator`: cross-build of `SpacetimeDB`
- `visionOS simulator`: cross-build of `SpacetimeDB`
- `watchOS simulator`: cross-build of `SpacetimeDB`

## Logging

The SDK uses `os.Logger` categories:

- `Client`
- `Cache`
- `Network`

Logs are visible in Console.app and device logs using subsystem `com.clockworklabs.SpacetimeDB`.

## Benchmarks

Benchmark target: `SpacetimeDBBenchmarks`

Includes suites for:

- BSATN encode/decode
- protocol message encode/decode
- reducer/procedure request+response round-trip encode/decode
- cache insert/delete throughput

Run from repo root:

```bash
swift package --package-path Benchmarks benchmark --target SpacetimeDBBenchmarks
```

List available benchmarks:

```bash
swift package --package-path Benchmarks benchmark list
```

Compare two captured baselines:

```bash
swift package --package-path Benchmarks benchmark baseline compare \
  <baseline-a> <baseline-b> \
  --target SpacetimeDBBenchmarks \
  --no-progress
```

## Validation Matrix

From repo root:

```bash
swift test
swift test --sanitize=thread
swift build -c release
swift package --package-path Benchmarks benchmark list
swift package --package-path Benchmarks benchmark --target SpacetimeDBBenchmarks
xcodebuild docbuild -scheme SpacetimeDB -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## License

This package carries the SpacetimeDB Business Source License 1.1 terms in `LICENSE.txt`. Review that file before production use.
