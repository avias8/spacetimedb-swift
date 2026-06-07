import XCTest
@testable import SpacetimeDB

/// Regression tests for WebSocket message fragmentation. A large server message
/// (e.g. a big subscription snapshot) is split across multiple WS frames: a
/// leading data frame with FIN=0, then continuation frames (opcode 0x0), the
/// last with FIN=1. The transport must reassemble these into one message.
/// Before the fix, the FIN bit was ignored and continuation frames were dropped,
/// so any fragmented message was corrupted/lost.
final class FrameFragmentationTests: XCTestCase {

    /// Builds a single unmasked server→client WebSocket frame. Built as an
    /// explicit `[UInt8]` so the header bytes are unambiguous (avoids any
    /// `Data.append` integer-literal overload surprises).
    private func serverFrame(fin: Bool, opcode: UInt8, payload: Data) -> Data {
        var header: [UInt8] = []
        header.append((fin ? 0x80 : 0x00) | (opcode & 0x0F))
        let len = payload.count
        if len <= 125 {
            header.append(UInt8(len))                       // mask bit 0: server frames unmasked
        } else if len <= 0xFFFF {
            header.append(126)
            header.append(UInt8((len >> 8) & 0xFF))
            header.append(UInt8(len & 0xFF))
        } else {
            header.append(127)
            let l = UInt64(len)
            for shift in stride(from: 56, through: 0, by: -8) {
                header.append(UInt8((l >> UInt64(shift)) & 0xFF))
            }
        }
        var frame = Data(header)
        frame.append(payload)                               // no masking key for server frames
        return frame
    }

    private func feed(_ transport: NWWebSocketTransport, bytes: Data) -> [(UInt8, Data)] {
        var buffer = bytes
        let raw = NWWebSocketTransport.parseFrames(from: &buffer)
        return transport.reassemble(raw)
    }

    func testUnfragmentedBinaryMessagePassesThrough() {
        let transport = NWWebSocketTransport()
        let payload = Data((0..<200).map { UInt8($0 % 256) })
        let frame = serverFrame(fin: true, opcode: 0x2, payload: payload)

        let messages = feed(transport, bytes: frame)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].0, 0x2)
        XCTAssertEqual(messages[0].1, payload)
    }

    func testLargeFragmentedMessageIsReassembled() {
        let transport = NWWebSocketTransport()
        // ~300KB, the rough scale of an 80-stroke subscription snapshot.
        let full = Data((0..<300_000).map { UInt8($0 % 251) })
        let third = full.count / 3
        let p1 = full.subdata(in: 0..<third)
        let p2 = full.subdata(in: third..<(2 * third))
        let p3 = full.subdata(in: (2 * third)..<full.count)

        var bytes = Data()
        bytes.append(serverFrame(fin: false, opcode: 0x2, payload: p1)) // start
        bytes.append(serverFrame(fin: false, opcode: 0x0, payload: p2)) // continuation
        bytes.append(serverFrame(fin: true,  opcode: 0x0, payload: p3)) // final

        let messages = feed(transport, bytes: bytes)
        XCTAssertEqual(messages.count, 1, "fragments must collapse into one message")
        XCTAssertEqual(messages[0].0, 0x2, "reassembled message keeps the original opcode")
        XCTAssertEqual(messages[0].1, full, "reassembled payload must equal the original")
    }

    /// Fragments must reassemble even when split across separate TCP reads
    /// (the real receive loop appends partial data and re-parses).
    func testFragmentsAcrossSeparateReadsAreReassembled() {
        let transport = NWWebSocketTransport()
        let full = Data((0..<120_000).map { UInt8(($0 * 7) % 251) })
        let half = full.count / 2
        let p1 = full.subdata(in: 0..<half)
        let p2 = full.subdata(in: half..<full.count)

        var produced: [(UInt8, Data)] = []
        // First TCP read: only the starting fragment.
        produced += feed(transport, bytes: serverFrame(fin: false, opcode: 0x2, payload: p1))
        XCTAssertTrue(produced.isEmpty, "no complete message until the final fragment")
        // Second TCP read: the final fragment.
        produced += feed(transport, bytes: serverFrame(fin: true, opcode: 0x0, payload: p2))

        XCTAssertEqual(produced.count, 1)
        XCTAssertEqual(produced[0].0, 0x2)
        XCTAssertEqual(produced[0].1, full)
    }

    /// A control frame (ping) interleaved with normal traffic still passes through.
    func testControlFramePassesThrough() {
        let transport = NWWebSocketTransport()
        let ping = serverFrame(fin: true, opcode: 0x9, payload: Data("hi".utf8))
        let messages = feed(transport, bytes: ping)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].0, 0x9)
    }
}
