import CryptoKit
import Foundation
import Network
import Synchronization

public protocol WebSocketTransportDelegate: AnyObject, Sendable {
    func webSocketTransportDidConnect()
    func webSocketTransportDidDisconnect(error: Error?)
    func webSocketTransportDidReceive(data: Data)
    func webSocketTransportDidReceivePong()
}

public protocol WebSocketTransport: AnyObject, Sendable {
    var delegate: WebSocketTransportDelegate? { get set }
    var negotiatedProtocol: String? { get }
    func connect(to url: URL, protocols: [String], headers: [String: String])
    func disconnect()
    func send(data: Data, completion: @escaping @Sendable (Error?) -> Void)
    func sendPing(completion: @escaping @Sendable (Error?) -> Void)
}

public extension WebSocketTransport {
    var negotiatedProtocol: String? { nil }
}

enum WebSocketTransportError: Error, Equatable, LocalizedError {
    case invalidURL(String)
    case invalidRequestHeader(String)
    case handshakeTooLarge
    case invalidHandshake(String)
    case notConnected
    case reservedBitsSet
    case maskedServerFrame
    case invalidOpcode(UInt8)
    case invalidPayloadLength
    case fragmentedControlFrame
    case controlFrameTooLarge(Int)
    case frameTooLarge(UInt64)
    case messageTooLarge(Int)
    case unexpectedContinuation
    case interruptedFragment
    case textMessageUnsupported
    case invalidCloseFrame(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let reason):
            return "Invalid WebSocket URL: \(reason)"
        case .invalidRequestHeader(let name):
            return "Invalid WebSocket request header: \(name)"
        case .handshakeTooLarge:
            return "WebSocket handshake headers exceeded the allowed size."
        case .invalidHandshake(let reason):
            return "Invalid WebSocket handshake: \(reason)"
        case .notConnected:
            return "WebSocket transport is not connected."
        case .reservedBitsSet:
            return "WebSocket frame uses unsupported reserved bits."
        case .maskedServerFrame:
            return "WebSocket server frames must not be masked."
        case .invalidOpcode(let opcode):
            return "WebSocket frame has unsupported opcode \(opcode)."
        case .invalidPayloadLength:
            return "WebSocket frame uses an invalid payload length encoding."
        case .fragmentedControlFrame:
            return "WebSocket control frames must not be fragmented."
        case .controlFrameTooLarge(let size):
            return "WebSocket control frame payload is too large (\(size) bytes)."
        case .frameTooLarge(let size):
            return "WebSocket frame payload is too large (\(size) bytes)."
        case .messageTooLarge(let size):
            return "WebSocket message is too large (\(size) bytes)."
        case .unexpectedContinuation:
            return "WebSocket continuation frame arrived without an open fragmented message."
        case .interruptedFragment:
            return "WebSocket fragmented message was interrupted by a new data frame."
        case .textMessageUnsupported:
            return "SpacetimeDB only accepts binary WebSocket messages."
        case .invalidCloseFrame(let reason):
            return "Invalid WebSocket close frame: \(reason)"
        }
    }
}

final class NWWebSocketTransport: WebSocketTransport {
    static let defaultMaximumFramePayloadSize = 64 * 1024 * 1024
    static let defaultMaximumMessagePayloadSize = 128 * 1024 * 1024
    private static let maximumHandshakeSize = 64 * 1024
    private static let receiveChunkSize = 64 * 1024
    private static let reservedRequestHeaders: Set<String> = [
        "host",
        "upgrade",
        "connection",
        "sec-websocket-version",
        "sec-websocket-key",
        "sec-websocket-protocol",
    ]

    private struct State {
        weak var delegate: WebSocketTransportDelegate?
        var connection: NWConnection?
        var didStartHandshake = false
        var didCompleteHandshake = false
        var handshakeKey = ""
        var negotiatedProtocol: String?
        var incomingBuffer = Data()
        var fragmentOpcode: UInt8?
        var fragmentBuffer = Data()

        mutating func resetReceiveState() {
            didStartHandshake = false
            didCompleteHandshake = false
            handshakeKey = ""
            negotiatedProtocol = nil
            incomingBuffer = Data()
            fragmentOpcode = nil
            fragmentBuffer = Data()
        }
    }

    private enum HandshakeBufferResult {
        case stale
        case incomplete
        case complete(Data)
        case failed(WebSocketTransportError)
    }

    private let state: Mutex<State> = Mutex(State())
    private let maximumFramePayloadSize: Int
    private let maximumMessagePayloadSize: Int
    private let queue = DispatchQueue(label: "spacetimedb.transport.nw", qos: .userInitiated)

    init(
        maximumFramePayloadSize: Int = defaultMaximumFramePayloadSize,
        maximumMessagePayloadSize: Int = defaultMaximumMessagePayloadSize
    ) {
        precondition(maximumFramePayloadSize > 0)
        precondition(maximumMessagePayloadSize >= maximumFramePayloadSize)
        self.maximumFramePayloadSize = maximumFramePayloadSize
        self.maximumMessagePayloadSize = maximumMessagePayloadSize
    }

    var delegate: WebSocketTransportDelegate? {
        get { state.withLock { $0.delegate } }
        set { state.withLock { $0.delegate = newValue } }
    }

    var negotiatedProtocol: String? {
        state.withLock { $0.negotiatedProtocol }
    }

    func connect(to url: URL, protocols: [String], headers: [String: String]) {
        guard let scheme = url.scheme?.lowercased(), ["ws", "wss", "http", "https"].contains(scheme) else {
            notifyDisconnected(error: WebSocketTransportError.invalidURL("unsupported scheme"))
            return
        }
        guard let host = url.host, !host.isEmpty else {
            notifyDisconnected(error: WebSocketTransportError.invalidURL("missing host"))
            return
        }

        let isSecure = scheme == "wss" || scheme == "https"
        let portNumber = url.port ?? (isSecure ? 443 : 80)
        guard (1...65_535).contains(portNumber), let port = NWEndpoint.Port(rawValue: UInt16(portNumber)) else {
            notifyDisconnected(error: WebSocketTransportError.invalidURL("invalid port"))
            return
        }

        let parameters = NWParameters(
            tls: isSecure ? NWProtocolTLS.Options() : nil,
            tcp: NWProtocolTCP.Options()
        )
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let previousConnection = state.withLock { state -> NWConnection? in
            let previous = state.connection
            state.connection = connection
            state.resetReceiveState()
            state.handshakeKey = Self.makeSecWebSocketKey()
            return previous
        }
        previousConnection?.cancel()

        connection.stateUpdateHandler = { [weak self] connectionState in
            self?.handleStateChange(
                connectionState,
                for: connection,
                url: url,
                protocols: protocols,
                headers: headers
            )
        }
        connection.start(queue: queue)
    }

    func disconnect() {
        let target = state.withLock { state -> (NWConnection, Bool)? in
            guard let connection = state.connection else { return nil }
            let completedHandshake = state.didCompleteHandshake
            state.connection = nil
            state.resetReceiveState()
            return (connection, completedHandshake)
        }
        guard let (connection, completedHandshake) = target else { return }

        guard completedHandshake else {
            connection.cancel()
            return
        }

        let normalClosure = Data([0x03, 0xE8])
        connection.send(content: Self.makeFrame(opcode: 0x8, payload: normalClosure), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func send(data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        guard let connection = readyConnection() else {
            completion(WebSocketTransportError.notConnected)
            return
        }

        connection.send(content: Self.makeFrame(opcode: 0x2, payload: data), completion: .contentProcessed { error in
            completion(error)
        })
    }

    func sendPing(completion: @escaping @Sendable (Error?) -> Void) {
        guard let connection = readyConnection() else {
            completion(WebSocketTransportError.notConnected)
            return
        }

        connection.send(content: Self.makeFrame(opcode: 0x9, payload: Data()), completion: .contentProcessed { error in
            completion(error)
        })
    }

    private func readyConnection() -> NWConnection? {
        state.withLock { state in
            guard state.didCompleteHandshake else { return nil }
            return state.connection
        }
    }

    private func handleStateChange(
        _ connectionState: NWConnection.State,
        for connection: NWConnection,
        url: URL,
        protocols: [String],
        headers: [String: String]
    ) {
        switch connectionState {
        case .ready:
            sendHandshake(connection: connection, url: url, protocols: protocols, headers: headers)
        case .failed(let error):
            terminate(connection: connection, error: error)
        case .cancelled:
            terminate(connection: connection, error: nil, cancelConnection: false)
        case .waiting(let error):
            guard isCurrent(connection) else { return }
            Log.network.debug("NWConnection waiting: \(error.localizedDescription)")
        case .preparing, .setup:
            break
        @unknown default:
            break
        }
    }

    private func sendHandshake(
        connection: NWConnection,
        url: URL,
        protocols: [String],
        headers: [String: String]
    ) {
        guard let key = state.withLock({ state -> String? in
            guard state.connection === connection, !state.didStartHandshake else { return nil }
            state.didStartHandshake = true
            return state.handshakeKey
        }) else { return }

        let request: Data
        do {
            request = try Self.makeHandshakeRequest(url: url, key: key, protocols: protocols, headers: headers)
        } catch {
            terminate(connection: connection, error: error)
            return
        }

        connection.send(content: request, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.terminate(connection: connection, error: error)
                return
            }
            self.receiveHandshakeResponse(connection: connection, key: key, protocols: protocols)
        })
    }

    static func makeHandshakeRequest(
        url: URL,
        key: String,
        protocols: [String],
        headers: [String: String]
    ) throws -> Data {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawHost = url.host,
              !rawHost.isEmpty else {
            throw WebSocketTransportError.invalidURL("missing host")
        }
        for protocolName in protocols where !isHTTPToken(protocolName) {
            throw WebSocketTransportError.invalidRequestHeader("Sec-WebSocket-Protocol")
        }

        let encodedPath = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let requestTarget = encodedPath + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
        let scheme = url.scheme?.lowercased()
        let isSecure = scheme == "wss" || scheme == "https"
        let defaultPort = isSecure ? 443 : 80
        let encodedHost = components.percentEncodedHost ?? rawHost
        let bracketedHost = encodedHost.contains(":") && !encodedHost.hasPrefix("[")
            ? "[\(encodedHost)]"
            : encodedHost
        let hostHeader = if let port = url.port, port != defaultPort {
            "\(bracketedHost):\(port)"
        } else {
            bracketedHost
        }

        var lines = [
            "GET \(requestTarget) HTTP/1.1",
            "Host: \(hostHeader)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Key: \(key)",
        ]
        if !protocols.isEmpty {
            lines.append("Sec-WebSocket-Protocol: \(protocols.joined(separator: ", "))")
        }
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            guard isHTTPToken(name), isValidHeaderValue(value) else {
                throw WebSocketTransportError.invalidRequestHeader(name)
            }
            guard !reservedRequestHeaders.contains(name.lowercased()) else { continue }
            lines.append("\(name): \(value)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func receiveHandshakeResponse(connection: NWConnection, key: String, protocols: [String]) {
        guard isCurrent(connection) else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.receiveChunkSize
        ) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.terminate(connection: connection, error: error)
                return
            }

            let result = self.state.withLock { state -> HandshakeBufferResult in
                guard state.connection === connection else { return .stale }
                if let content, !content.isEmpty {
                    state.incomingBuffer.append(content)
                }
                if let delimiter = state.incomingBuffer.range(of: Data("\r\n\r\n".utf8)) {
                    guard delimiter.upperBound <= Self.maximumHandshakeSize else {
                        return .failed(.handshakeTooLarge)
                    }
                    let header = Data(state.incomingBuffer[..<delimiter.upperBound])
                    state.incomingBuffer.removeSubrange(..<delimiter.upperBound)
                    return .complete(header)
                }
                guard state.incomingBuffer.count < Self.maximumHandshakeSize else {
                    return .failed(.handshakeTooLarge)
                }
                return .incomplete
            }

            switch result {
            case .stale:
                return
            case .failed(let handshakeError):
                self.terminate(connection: connection, error: handshakeError)
            case .incomplete:
                if isComplete {
                    self.terminate(
                        connection: connection,
                        error: WebSocketTransportError.invalidHandshake("connection closed before headers completed")
                    )
                } else {
                    self.receiveHandshakeResponse(connection: connection, key: key, protocols: protocols)
                }
            case .complete(let header):
                let selectedProtocol: String?
                do {
                    selectedProtocol = try Self.validateHandshakeResponse(header, key: key, protocols: protocols)
                } catch {
                    self.terminate(connection: connection, error: error)
                    return
                }

                let activation = self.state.withLock { state -> (Bool, WebSocketTransportDelegate?) in
                    guard state.connection === connection, !state.didCompleteHandshake else {
                        return (false, nil)
                    }
                    state.didCompleteHandshake = true
                    state.negotiatedProtocol = selectedProtocol
                    return (true, state.delegate)
                }
                guard activation.0 else { return }
                activation.1?.webSocketTransportDidConnect()
                guard self.processBufferedFrames(connection: connection) else { return }

                if isComplete {
                    self.terminate(connection: connection, error: nil)
                } else {
                    self.receiveNextMessage(connection: connection)
                }
            }
        }
    }

    @discardableResult
    static func validateHandshakeResponse(_ headerData: Data, key: String, protocols: [String]) throws -> String? {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw WebSocketTransportError.invalidHandshake("headers are not valid UTF-8")
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw WebSocketTransportError.invalidHandshake("missing HTTP status line")
        }
        let statusParts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard statusParts.count >= 2,
              statusParts[0] == "HTTP/1.1",
              statusParts[1] == "101" else {
            throw WebSocketTransportError.invalidHandshake("server did not return HTTP 101")
        }

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw WebSocketTransportError.invalidHandshake("malformed HTTP header")
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard isHTTPToken(name), isValidHeaderValue(value) else {
                throw WebSocketTransportError.invalidHandshake("malformed HTTP header")
            }
            headers[name, default: []].append(value)
        }

        let upgradeTokens = headers["upgrade", default: []]
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard upgradeTokens.contains("websocket") else {
            throw WebSocketTransportError.invalidHandshake("missing Upgrade: websocket")
        }
        let connectionTokens = headers["connection", default: []]
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard connectionTokens.contains("upgrade") else {
            throw WebSocketTransportError.invalidHandshake("missing Connection: Upgrade")
        }

        let acceptValues = headers["sec-websocket-accept", default: []]
        guard acceptValues.count == 1, acceptValues[0] == Self.computeAcceptKey(from: key) else {
            throw WebSocketTransportError.invalidHandshake("Sec-WebSocket-Accept does not match")
        }

        let selectedProtocols = headers["sec-websocket-protocol", default: []]
        if protocols.isEmpty {
            guard selectedProtocols.isEmpty else {
                throw WebSocketTransportError.invalidHandshake("server selected an unoffered subprotocol")
            }
            return nil
        } else {
            guard selectedProtocols.count == 1, protocols.contains(selectedProtocols[0]) else {
                throw WebSocketTransportError.invalidHandshake("server did not select an offered subprotocol")
            }
            return selectedProtocols[0]
        }
    }

    private func receiveNextMessage(connection: NWConnection) {
        guard state.withLock({ state in
            state.connection === connection && state.didCompleteHandshake
        }) else { return }

        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.receiveChunkSize
        ) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.terminate(connection: connection, error: error)
                return
            }

            let isCurrent = self.state.withLock { state -> Bool in
                guard state.connection === connection else { return false }
                if let content, !content.isEmpty {
                    state.incomingBuffer.append(content)
                }
                return true
            }
            guard isCurrent else { return }
            guard self.processBufferedFrames(connection: connection) else { return }

            if isComplete {
                self.terminate(connection: connection, error: nil)
            } else {
                self.receiveNextMessage(connection: connection)
            }
        }
    }

    private func processBufferedFrames(connection: NWConnection) -> Bool {
        var parseBuffer: Data?
        state.withLock { state in
            guard state.connection === connection else { return }
            var buffer = Data()
            swap(&buffer, &state.incomingBuffer)
            parseBuffer = buffer
        }
        guard var parseBuffer else { return false }

        let frames: [(fin: Bool, opcode: UInt8, payload: Data)]
        do {
            frames = try Self.parseFrames(
                from: &parseBuffer,
                maximumPayloadSize: maximumFramePayloadSize
            )
        } catch {
            terminate(connection: connection, error: error)
            return false
        }

        var messages: [(UInt8, Data)] = []
        do {
            let committed = try state.withLock { state -> Bool in
                guard state.connection === connection else { return false }
                if !state.incomingBuffer.isEmpty {
                    parseBuffer.append(state.incomingBuffer)
                }
                state.incomingBuffer = parseBuffer
                messages = try Self.reassemble(
                    frames,
                    state: &state,
                    maximumMessagePayloadSize: maximumMessagePayloadSize
                )
                return true
            }
            guard committed else { return false }
        } catch {
            terminate(connection: connection, error: error)
            return false
        }

        for (opcode, payload) in messages {
            let delivery = state.withLock { state -> (Bool, WebSocketTransportDelegate?) in
                guard state.connection === connection else { return (false, nil) }
                return (true, state.delegate)
            }
            guard delivery.0 else { return false }

            switch opcode {
            case 0x2:
                delivery.1?.webSocketTransportDidReceive(data: payload)
            case 0x8:
                do {
                    try Self.validateClosePayload(payload)
                } catch {
                    terminate(connection: connection, error: error)
                    return false
                }
                handleRemoteClose(connection: connection, payload: payload)
                return false
            case 0x9:
                connection.send(
                    content: Self.makeFrame(opcode: 0xA, payload: payload),
                    completion: .contentProcessed { [weak self] error in
                        if let error {
                            self?.terminate(connection: connection, error: error)
                        }
                    }
                )
            case 0xA:
                delivery.1?.webSocketTransportDidReceivePong()
            default:
                terminate(connection: connection, error: WebSocketTransportError.invalidOpcode(opcode))
                return false
            }
        }
        return isCurrent(connection)
    }

    private func handleRemoteClose(
        connection: NWConnection,
        payload: Data
    ) {
        let closeResult = state.withLock { state -> (Bool, WebSocketTransportDelegate?) in
            guard state.connection === connection else { return (false, nil) }
            let delegate = state.delegate
            state.connection = nil
            state.resetReceiveState()
            return (true, delegate)
        }
        guard closeResult.0 else { return }

        connection.send(content: Self.makeFrame(opcode: 0x8, payload: payload), completion: .contentProcessed { _ in
            connection.cancel()
        })
        closeResult.1?.webSocketTransportDidDisconnect(error: nil)
    }

    private func terminate(
        connection: NWConnection,
        error: Error?,
        cancelConnection: Bool = true
    ) {
        let target = state.withLock { state -> (Bool, WebSocketTransportDelegate?) in
            guard state.connection === connection else { return (false, nil) }
            let delegate = state.delegate
            state.connection = nil
            state.resetReceiveState()
            return (true, delegate)
        }
        guard target.0 else { return }
        if cancelConnection {
            connection.cancel()
        }
        target.1?.webSocketTransportDidDisconnect(error: error)
    }

    private func notifyDisconnected(error: Error?) {
        delegate?.webSocketTransportDidDisconnect(error: error)
    }

    private func isCurrent(_ connection: NWConnection) -> Bool {
        state.withLock { $0.connection === connection }
    }

    private static func makeSecWebSocketKey() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8(truncatingIfNeeded: generator.next())
        }
        return Data(bytes).base64EncodedString()
    }

    private static func computeAcceptKey(from key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }

    private static func isHTTPToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case 48...57, 65...90, 97...122:
                return true
            case 33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
                return true
            default:
                return false
            }
        }
    }

    private static func isValidHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { byte in
            byte == 9 || (byte >= 32 && byte != 127)
        }
    }

    static func makeFrame(opcode: UInt8, payload: Data) -> Data {
        let payloadLength = payload.count
        let extendedLengthSize = payloadLength <= 125 ? 0 : (payloadLength <= 0xFFFF ? 2 : 8)
        let payloadOffset = 2 + extendedLengthSize + 4
        var frame = Data(count: payloadOffset + payloadLength)
        var generator = SystemRandomNumberGenerator()
        let maskWord = generator.next()

        frame.withUnsafeMutableBytes { destination in
            let bytes = destination.bindMemory(to: UInt8.self)
            bytes[0] = 0x80 | (opcode & 0x0F)

            var cursor = 2
            if payloadLength <= 125 {
                bytes[1] = 0x80 | UInt8(payloadLength)
            } else if payloadLength <= 0xFFFF {
                bytes[1] = 0x80 | 126
                bytes[cursor] = UInt8((payloadLength >> 8) & 0xFF)
                bytes[cursor + 1] = UInt8(payloadLength & 0xFF)
                cursor += 2
            } else {
                bytes[1] = 0x80 | 127
                let length = UInt64(payloadLength)
                for shift in stride(from: 56, through: 0, by: -8) {
                    bytes[cursor] = UInt8((length >> UInt64(shift)) & 0xFF)
                    cursor += 1
                }
            }

            withUnsafeBytes(of: maskWord) { mask in
                for index in 0..<4 {
                    bytes[cursor + index] = mask[index]
                }
                cursor += 4

                payload.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                    for index in 0..<payloadLength {
                        bytes[cursor + index] = source[index] ^ mask[index & 3]
                    }
                }
            }
        }
        return frame
    }

    static func parseFrames(
        from buffer: inout Data,
        maximumPayloadSize: Int = defaultMaximumFramePayloadSize
    ) throws -> [(fin: Bool, opcode: UInt8, payload: Data)] {
        precondition(maximumPayloadSize > 0)
        var frames: [(fin: Bool, opcode: UInt8, payload: Data)] = []
        var index = 0
        while true {
            let start = index
            guard buffer.count - index >= 2 else { break }
            let first = buffer[index]
            let second = buffer[index + 1]
            index += 2

            let fin = (first & 0x80) != 0
            guard first & 0x70 == 0 else { throw WebSocketTransportError.reservedBitsSet }
            let opcode = first & 0x0F
            guard opcode == 0x0 || opcode == 0x1 || opcode == 0x2 || opcode == 0x8 || opcode == 0x9 || opcode == 0xA else {
                throw WebSocketTransportError.invalidOpcode(opcode)
            }
            guard second & 0x80 == 0 else { throw WebSocketTransportError.maskedServerFrame }

            let lengthMarker = Int(second & 0x7F)
            var payloadLength = lengthMarker
            if lengthMarker == 126 {
                guard buffer.count - index >= 2 else {
                    index = start
                    break
                }
                payloadLength = Int(buffer[index]) << 8 | Int(buffer[index + 1])
                guard payloadLength >= 126 else { throw WebSocketTransportError.invalidPayloadLength }
                index += 2
            } else if lengthMarker == 127 {
                guard buffer.count - index >= 8 else {
                    index = start
                    break
                }
                guard buffer[index] & 0x80 == 0 else {
                    throw WebSocketTransportError.invalidPayloadLength
                }
                var decodedLength: UInt64 = 0
                for byte in buffer[index..<(index + 8)] {
                    decodedLength = (decodedLength << 8) | UInt64(byte)
                }
                guard decodedLength > UInt64(UInt16.max) else {
                    throw WebSocketTransportError.invalidPayloadLength
                }
                guard decodedLength <= UInt64(maximumPayloadSize) else {
                    throw WebSocketTransportError.frameTooLarge(decodedLength)
                }
                payloadLength = Int(decodedLength)
                index += 8
            }

            guard payloadLength <= maximumPayloadSize else {
                throw WebSocketTransportError.frameTooLarge(UInt64(payloadLength))
            }
            if opcode >= 0x8 {
                guard fin else { throw WebSocketTransportError.fragmentedControlFrame }
                guard payloadLength <= 125 else {
                    throw WebSocketTransportError.controlFrameTooLarge(payloadLength)
                }
            }
            guard buffer.count - index >= payloadLength else {
                index = start
                break
            }

            let payload = Data(buffer[index..<(index + payloadLength)])
            index += payloadLength
            frames.append((fin, opcode, payload))
        }
        if index > 0 {
            buffer.removeSubrange(0..<index)
        }
        return frames
    }

    func reassemble(_ rawFrames: [(fin: Bool, opcode: UInt8, payload: Data)]) throws -> [(UInt8, Data)] {
        try state.withLock { state in
            try Self.reassemble(
                rawFrames,
                state: &state,
                maximumMessagePayloadSize: maximumMessagePayloadSize
            )
        }
    }

    private static func reassemble(
        _ rawFrames: [(fin: Bool, opcode: UInt8, payload: Data)],
        state: inout State,
        maximumMessagePayloadSize: Int
    ) throws -> [(UInt8, Data)] {
        var messages: [(UInt8, Data)] = []
        for frame in rawFrames {
            switch frame.opcode {
            case 0x8, 0x9, 0xA:
                messages.append((frame.opcode, frame.payload))
            case 0x0:
                guard let opcode = state.fragmentOpcode else {
                    throw WebSocketTransportError.unexpectedContinuation
                }
                let combinedSize = state.fragmentBuffer.count + frame.payload.count
                guard combinedSize <= maximumMessagePayloadSize else {
                    throw WebSocketTransportError.messageTooLarge(combinedSize)
                }
                state.fragmentBuffer.append(frame.payload)
                if frame.fin {
                    messages.append((opcode, state.fragmentBuffer))
                    state.fragmentOpcode = nil
                    state.fragmentBuffer = Data()
                }
            case 0x1:
                throw WebSocketTransportError.textMessageUnsupported
            case 0x2:
                guard state.fragmentOpcode == nil else {
                    throw WebSocketTransportError.interruptedFragment
                }
                guard frame.payload.count <= maximumMessagePayloadSize else {
                    throw WebSocketTransportError.messageTooLarge(frame.payload.count)
                }
                if frame.fin {
                    messages.append((frame.opcode, frame.payload))
                } else {
                    state.fragmentOpcode = frame.opcode
                    state.fragmentBuffer = frame.payload
                }
            default:
                throw WebSocketTransportError.invalidOpcode(frame.opcode)
            }
        }
        return messages
    }

    static func validateClosePayload(_ payload: Data) throws {
        guard payload.count != 1 else {
            throw WebSocketTransportError.invalidCloseFrame("status code is truncated")
        }
        guard payload.count >= 2 else { return }

        let code = UInt16(payload[payload.startIndex]) << 8
            | UInt16(payload[payload.index(after: payload.startIndex)])
        guard (1_000...4_999).contains(code), ![1_004, 1_005, 1_006, 1_015].contains(code) else {
            throw WebSocketTransportError.invalidCloseFrame("status code \(code) is not allowed")
        }

        let reason = payload.dropFirst(2)
        guard reason.isEmpty || String(data: reason, encoding: .utf8) != nil else {
            throw WebSocketTransportError.invalidCloseFrame("reason is not valid UTF-8")
        }
    }
}
