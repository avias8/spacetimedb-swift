import Foundation

/// Negotiated SpacetimeDB WebSocket wire subprotocol.
public enum SpacetimeWireProtocol: String, Sendable, CaseIterable, Equatable {
    case v2 = "v2.bsatn.spacetimedb"
    case v3 = "v3.bsatn.spacetimedb"

    /// Subprotocols offered during the WebSocket opening handshake, in preference order.
    public static let preferredProtocols: [String] = [
        Self.v3.rawValue,
        Self.v2.rawValue,
    ]

    /// Normalizes a server-selected WebSocket subprotocol string, defaulting to `.v2` for empty/legacy values.
    public static func normalize(_ negotiatedProtocol: String?) -> SpacetimeWireProtocol {
        guard let negotiatedProtocol, !negotiatedProtocol.isEmpty else {
            return .v2
        }
        if negotiatedProtocol == Self.v3.rawValue {
            return .v3
        }
        if negotiatedProtocol == Self.v2.rawValue {
            return .v2
        }
        Log.network.warning("Unexpected WebSocket subprotocol '\(negotiatedProtocol)', falling back to \(Self.v2.rawValue)")
        return .v2
    }
}

public enum WebSocketV3FrameError: Error, Equatable, LocalizedError {
    case emptyPayload
    case invalidMessageCount(requested: Int, available: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyPayload:
            return "v3 WebSocket payloads must contain at least one message."
        case .invalidMessageCount(let requested, let available):
            return "v3 WebSocket payload requested \(requested) messages from \(available) available."
        }
    }
}

/// Framing helpers for `v3.bsatn.spacetimedb`, which concatenates one or more BSATN-encoded
/// `ClientMessage` or `ServerMessage` payloads back-to-back within a single WebSocket binary message.
public enum WebSocketV3Frames {
    /// Maximum target byte size for a single outbound `v3` batched WebSocket frame (256 KiB).
    public static let maxOutboundFrameBytes = 256 * 1024

    /// Returns how many leading messages from `messages` fit within `maxFrameBytes`.
    /// Always returns at least `1` when `messages` is non-empty, even if the first message exceeds `maxFrameBytes`.
    public static func countClientMessagesForFrame(
        _ messages: [Data],
        maxFrameBytes: Int = maxOutboundFrameBytes
    ) throws -> Int {
        guard let first = messages.first else {
            throw WebSocketV3FrameError.emptyPayload
        }
        if first.count > maxFrameBytes {
            return 1
        }

        var count = 1
        var frameSize = first.count
        while count < messages.count {
            let nextSize = messages[count].count
            if frameSize + nextSize > maxFrameBytes {
                break
            }
            frameSize += nextSize
            count += 1
        }
        return count
    }

    /// Concatenates the first `messageCount` encoded `ClientMessage` payloads into a single `v3` frame payload.
    public static func encodeClientMessages(
        _ messages: [Data],
        messageCount: Int? = nil
    ) throws -> Data {
        guard !messages.isEmpty else {
            throw WebSocketV3FrameError.emptyPayload
        }
        let count = messageCount ?? messages.count
        guard count >= 1, count <= messages.count else {
            throw WebSocketV3FrameError.invalidMessageCount(requested: count, available: messages.count)
        }
        if count == 1 {
            return messages[0]
        }

        var totalBytes = 0
        for i in 0..<count {
            totalBytes += messages[i].count
        }

        var combined = Data()
        combined.reserveCapacity(totalBytes)
        for i in 0..<count {
            combined.append(messages[i])
        }
        return combined
    }

    /// Decodes one or more concatenated `ServerMessage`s from a decompressed `v3` (or `v2`) BSATN payload.
    public static func decodeServerMessages(from bsatnPayload: Data) throws -> [ServerMessage] {
        guard !bsatnPayload.isEmpty else {
            throw WebSocketV3FrameError.emptyPayload
        }

        return try bsatnPayload.withUnsafeBytes { buffer in
            var reader = BSATNReader(buffer: buffer)
            var messages: [ServerMessage] = []
            while reader.remaining > 0 {
                messages.append(try ServerMessage.decodeBSATN(from: &reader))
            }
            return messages
        }
    }
}
