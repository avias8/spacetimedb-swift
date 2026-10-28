# Publishing Guide

`spacetimedb-swift` is already structured as a standalone Swift package and is indexed by Swift Package Index. No monorepo mirroring step is required.

## Package Contents

- Runtime library: `Sources/SpacetimeDB`
- Unit and opt-in live tests: `Tests/SpacetimeDBTests`
- DocC catalog: `Sources/SpacetimeDB/SpacetimeDB.docc`
- Isolated performance tooling: `Benchmarks`
- Swift Package Index configuration: `.spi.yml`

The root manifest must remain dependency-free. Dependencies used only for benchmarking belong in `Benchmarks/Package.swift` so they are never resolved by SDK consumers.

## Documentation

Build DocC locally without adding a package dependency:

```bash
xcodebuild docbuild \
  -scheme SpacetimeDB \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Swift Package Index builds documentation for the `SpacetimeDB` target configured in `.spi.yml`.

## CI

`.github/workflows/ci.yml` validates:

- macOS unit tests, Thread Sanitizer, release build, and DocC
- iOS 18 simulator compilation
- visionOS 2 simulator compilation
- watchOS 11 simulator compilation
- benchmark package manifest resolution
- a clean tracked worktree after validation

## Release

Use `DISTRIBUTION.md` for the exact preflight, tag, push, and verification commands. Use `SPI_SUBMISSION_CHECKLIST.md` for package-index verification.

Consumer dependency:

```swift
.package(
    url: "https://github.com/avias8/spacetimedb-swift.git",
    from: "0.24.0"
)
```
