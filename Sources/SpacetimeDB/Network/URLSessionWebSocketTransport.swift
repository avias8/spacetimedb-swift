import Foundation
import Synchronization

/// A `URLSessionWebSocketTask`-backed `WebSocketTransport` implementation.
///
/// Use `URLSessionWebSocketTransport` when you need `URLSessionConfiguration` features such as
/// custom HTTP proxy settings, corporate TLS certificates, or custom `URLSession` instances.
public final class URLSessionWebSocketTransport: NSObject, WebSocketTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    private struct State {
        weak var delegate: WebSocketTransportDelegate?
        var session: URLSession?
        var task: URLSessionWebSocketTask?
        var negotiatedProtocol: String?
        var isConnected = false
    }

    private let state: Mutex<State> = Mutex(State())
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
        super.init()
    }

    public var delegate: WebSocketTransportDelegate? {
        get { state.withLock { $0.delegate } }
        set { state.withLock { $0.delegate = newValue } }
    }

    public var negotiatedProtocol: String? {
        state.withLock { $0.negotiatedProtocol }
    }

    public func connect(to url: URL, protocols: [String], headers: [String: String]) {
        guard let scheme = url.scheme?.lowercased(), ["ws", "wss", "http", "https"].contains(scheme) else {
            delegate?.webSocketTransportDidDisconnect(error: WebSocketTransportError.invalidURL("unsupported scheme"))
            return
        }
        guard let host = url.host, !host.isEmpty else {
            delegate?.webSocketTransportDidDisconnect(error: WebSocketTransportError.invalidURL("missing host"))
            return
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.scheme == "http" { components?.scheme = "ws" }
        if components?.scheme == "https" { components?.scheme = "wss" }
        guard let wsURL = components?.url else {
            delegate?.webSocketTransportDidDisconnect(error: WebSocketTransportError.invalidURL("malformed URL"))
            return
        }

        var request = URLRequest(url: wsURL)
        if !protocols.isEmpty {
            request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = NWWebSocketTransport.defaultMaximumMessagePayloadSize

        let previous = state.withLock { state -> (URLSessionWebSocketTask?, URLSession?) in
            let prevTask = state.task
            let prevSession = state.session
            state.task = task
            state.session = session
            state.negotiatedProtocol = nil
            state.isConnected = false
            return (prevTask, prevSession)
        }
        previous.0?.cancel(with: .goingAway, reason: nil)
        previous.1?.invalidateAndCancel()

        task.resume()
        receiveNext(for: task)
    }

    public func disconnect() {
        let current = state.withLock { state -> (URLSessionWebSocketTask?, URLSession?) in
            let task = state.task
            let session = state.session
            state.task = nil
            state.session = nil
            state.negotiatedProtocol = nil
            state.isConnected = false
            return (task, session)
        }
        current.0?.cancel(with: .normalClosure, reason: nil)
        current.1?.invalidateAndCancel()
    }

    public func send(data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        let task = state.withLock { state -> URLSessionWebSocketTask? in
            guard state.isConnected else { return nil }
            return state.task
        }
        guard let task else {
            completion(WebSocketTransportError.notConnected)
            return
        }
        task.send(.data(data), completionHandler: completion)
    }

    public func sendPing(completion: @escaping @Sendable (Error?) -> Void) {
        let task = state.withLock { state -> URLSessionWebSocketTask? in
            guard state.isConnected else { return nil }
            return state.task
        }
        guard let task else {
            completion(WebSocketTransportError.notConnected)
            return
        }
        task.sendPing { [weak self] error in
            if error == nil {
                self?.delegate?.webSocketTransportDidReceivePong()
            }
            completion(error)
        }
    }

    private func receiveNext(for task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            let isCurrent = self.state.withLock { $0.task === task }
            guard isCurrent else { return }

            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.delegate?.webSocketTransportDidReceive(data: data)
                    self.receiveNext(for: task)
                case .string:
                    self.terminate(task: task, error: WebSocketTransportError.textMessageUnsupported)
                @unknown default:
                    self.receiveNext(for: task)
                }
            case .failure(let error):
                self.terminate(task: task, error: error)
            }
        }
    }

    private func terminate(task: URLSessionWebSocketTask, error: Error?) {
        let result = state.withLock { state -> (Bool, WebSocketTransportDelegate?, URLSession?) in
            guard state.task === task else { return (false, nil, nil) }
            let delegate = state.delegate
            let session = state.session
            state.task = nil
            state.session = nil
            state.negotiatedProtocol = nil
            state.isConnected = false
            return (true, delegate, session)
        }
        guard result.0 else { return }
        task.cancel()
        result.2?.invalidateAndCancel()
        result.1?.webSocketTransportDidDisconnect(error: error)
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let delegateToNotify = state.withLock { state -> WebSocketTransportDelegate? in
            guard state.task === webSocketTask else { return nil }
            state.isConnected = true
            state.negotiatedProtocol = `protocol`
            return state.delegate
        }
        delegateToNotify?.webSocketTransportDidConnect()
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        terminate(task: webSocketTask, error: nil)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let wsTask = task as? URLSessionWebSocketTask, let error else { return }
        terminate(task: wsTask, error: error)
    }
}
