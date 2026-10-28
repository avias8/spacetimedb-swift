# Release Runbook

This repository is the public Swift Package Manager source of truth for `SpacetimeDB`. `Package.swift`, `Sources`, and `Tests` remain at repository root so consumers and Swift Package Index can use each release tag directly.

## Version Policy

Releases use semantic version tags in the form `vX.Y.Z`.

- While the SDK is below `1.0`, use a minor release for source-breaking API or deployment-target changes.
- Use a patch release for compatible fixes.
- Keep the package dependency snippet, changelog, and release notes on the same version.

The current release is `0.24.0`.

## Preflight

Run from repository root on the release commit:

```bash
swift --version
swift package describe
swift test
NSUnbufferedIO=YES swift test --sanitize=thread
swift build -c release
xcodebuild -scheme SpacetimeDB -destination 'generic/platform=iOS Simulator' -configuration Release CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme SpacetimeDB -destination 'generic/platform=visionOS Simulator' -configuration Release CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme SpacetimeDB -destination 'generic/platform=watchOS Simulator' -configuration Release CODE_SIGNING_ALLOWED=NO build
swift package --package-path Benchmarks benchmark list
xcodebuild docbuild -scheme SpacetimeDB -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
git diff --exit-code
git status --short
```

The cross-build commands require the corresponding Xcode platform components. CI uses GitHub's `macos-26` image, which includes the iOS, visionOS, and watchOS SDKs.

The root package intentionally has no third-party dependencies and therefore does not commit a root `Package.resolved`. Benchmark-only dependencies live under `Benchmarks` and its lockfile is ignored.

## Cut A Release

1. Replace `Unreleased` in `CHANGELOG.md` with the release date.
2. Confirm README installation examples reference the release version.
3. Commit the release metadata on `main`.
4. Create and push an annotated tag.
5. Publish matching GitHub release notes.

```bash
export VERSION="0.24.0"

git switch main
git pull --ff-only origin main
git tag -a "v$VERSION" -m "SpacetimeDB Swift SDK $VERSION"
git push origin main "v$VERSION"
gh release create "v$VERSION" --title "SpacetimeDB Swift SDK $VERSION" --generate-notes
```

Do not move or replace an existing release tag. Increment the patch version if a tag already exists.

## Verify Distribution

```bash
git ls-remote --tags origin "refs/tags/v$VERSION"
curl -fsSL "https://swiftpackageindex.com/api/packages/avias8/spacetimedb-swift/badge?type=swift-versions"
curl -fsSL "https://swiftpackageindex.com/api/packages/avias8/spacetimedb-swift/badge?type=platforms"
```

Verify the package page at <https://swiftpackageindex.com/avias8/spacetimedb-swift>, its generated documentation, and a clean install in a new Xcode project.
