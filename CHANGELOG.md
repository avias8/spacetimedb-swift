# Changelog

## 0.20.0 - 2026-03-02

- Mirrored `sdks/swift` from upstream `swift-integration` through commit `9874e3c2f`.
- Included Ninja Swift demo rendering-path compatibility fixes.
- Split protocol messaging into `ClientMessage`, `ServerMessage`, and `ProtocolTypes`.
- Removed legacy `ProtocolMessages.swift` in favor of the new protocol layout.
- Added protocol parity and concurrency-related test coverage.
- Expanded benchmark coverage with generated-bindings benchmarks.
- Updated package platform declarations for current Apple SDK targets.
- Refreshed distribution and SPI release runbook defaults to `0.20.0`.
- Added mirror README install snippet for GitHub package consumption.
