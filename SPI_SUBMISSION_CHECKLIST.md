# Swift Package Index Release Checklist

The package is listed at <https://swiftpackageindex.com/avias8/spacetimedb-swift>. Use this checklist for `0.24.0` and later releases.

## Release Inputs

```bash
export SPI_OWNER="avias8"
export SPI_REPO="spacetimedb-swift"
export SPI_VERSION="0.24.0"
```

## Repository Readiness

- [ ] Repository root contains `Package.swift`, `Sources`, `Tests`, `.spi.yml`, and `LICENSE.txt`.
- [ ] Root `Package.swift` has no third-party dependencies.
- [ ] `.spi.yml` lists `SpacetimeDB` as a documentation target.
- [ ] README installation examples use `$SPI_VERSION`.
- [ ] `CHANGELOG.md` has dated release notes.

## Validation

- [ ] `swift package describe`
- [ ] `swift test`
- [ ] `NSUnbufferedIO=YES swift test --sanitize=thread`
- [ ] `swift build -c release`
- [ ] iOS simulator release build
- [ ] visionOS simulator release build
- [ ] watchOS simulator release build
- [ ] `swift package --package-path Benchmarks benchmark list`
- [ ] `xcodebuild docbuild -scheme SpacetimeDB -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO`
- [ ] `git diff --exit-code`

## Tag And GitHub Release

```bash
git tag -a "v$SPI_VERSION" -m "SpacetimeDB Swift SDK $SPI_VERSION"
git push origin main "v$SPI_VERSION"
gh release create "v$SPI_VERSION" \
  --title "SpacetimeDB Swift SDK $SPI_VERSION" \
  --generate-notes
```

- [ ] `git ls-remote --tags origin "refs/tags/v$SPI_VERSION"` returns the tag.
- [ ] The GitHub release and tag reference the same commit.

## Swift Package Index

SPI should discover new semantic-version tags automatically. If the package is ever removed, resubmit `https://github.com/$SPI_OWNER/$SPI_REPO` at <https://swiftpackageindex.com/add-a-package>.

```bash
SPI_API_BASE="https://swiftpackageindex.com/api/packages/$SPI_OWNER/$SPI_REPO"

curl -fsSL "$SPI_API_BASE/badge?type=swift-versions" -o /tmp/spi-swift-versions.json
curl -fsSL "$SPI_API_BASE/badge?type=platforms" -o /tmp/spi-platforms.json

grep -q '"isError":false' /tmp/spi-swift-versions.json
grep -q '"isError":false' /tmp/spi-platforms.json
```

- [ ] Package page resolves.
- [ ] `SpacetimeDB` documentation builds.
- [ ] Swift-version badge is not pending.
- [ ] Platform badge lists the supported Apple platforms.
- [ ] SPI recognizes `LICENSE.txt`.
- [ ] A clean Xcode project resolves `.package(..., from: "$SPI_VERSION")`.
