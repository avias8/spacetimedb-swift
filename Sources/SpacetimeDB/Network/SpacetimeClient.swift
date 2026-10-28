import Foundation
import Network
import Synchronization

public enum SpacetimeClientProcedureError: Error, Equatable {
    case internalError(String)
    case disconnected
    case timeout
}

public enum SpacetimeClientConnectionError: Error, Equatable {
    case keepAliveTimeout
}

private final class AsyncResponseContinuation<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Error>?
        var timeoutTask: Task<Void, Never>?
        var completionResult: Result<Value, Error>?
        var isCompleted = false
    }

    private let state: Mutex<State> = Mutex(State())

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        var resultToResume: Result<Value, Error>?

        state.withLock { state in
            if state.isCompleted {
                resultToResume = state.completionResult
                state.completionResult = nil
            } else {
                state.continuation = continuation
            }
        }

        if let resultToResume {
            resume(continuation, with: resultToResume)
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        var shouldCancelTask = false

        state.withLock { state in
            if state.isCompleted {
                shouldCancelTask = true
            } else {
                state.timeoutTask = task
            }
        }

        if shouldCancelTask {
            task.cancel()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        var continuationToResume: CheckedContinuation<Value, Error>?
        var timeoutTaskToCancel: Task<Void, Never>?

        let didResolve = state.withLock { state -> Bool in
            if state.isCompleted {
                return false
            }
            state.isCompleted = true
            timeoutTaskToCancel = state.timeoutTask
            state.timeoutTask = nil

            if let continuation = state.continuation {
                continuationToResume = continuation
                state.continuation = nil
            } else {
                state.completionResult = result
            }
            return true
        }
        guard didResolve else { return }

        timeoutTaskToCancel?.cancel()
        if let continuationToResume {
            resume(continuationToResume, with: result)
        }
    }

    private func resume(_ continuation: CheckedContinuation<Value, Error>, with result: Result<Value, Error>) {
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

@MainActor
public protocol SpacetimeClientDelegate: AnyObject {
    func onConnect()
    func onDisconnect(error: Error?)
    func onConnectError(error: Error)
    func onConnectionStateChange(state: ConnectionState)
    func onIdentityReceived(identity: [UInt8], token: String)
    func onTransactionUpdate(message: Data?)
    func onReducerError(reducer: String, message: String, isInternal: Bool)
}

public extension SpacetimeClientDelegate {
    func onConnectError(error: Error) {}
    func onConnectionStateChange(state: ConnectionState) {}
    func onReducerError(reducer: String, message: String, isInternal: Bool) {}
}

public final class SpacetimeClient: @unchecked Sendable, WebSocketTransportDelegate {
    public let serverUrl: URL
    public let moduleName: String
    
    private let stateLock: Mutex<Void> = Mutex(())
    @inline(__always)
    private func withStateLock<R>(_ body: () throws -> R) rethrows -> R {
        try stateLock.withLock { _ in
            try body()
        }
    }

    private let callbackStateLock: Mutex<Void> = Mutex(())
    @inline(__always)
    private func withCallbackStateLock<R>(_ body: () throws -> R) rethrows -> R {
        try callbackStateLock.withLock { _ in
            try body()
        }
    }

    private let idStateLock: Mutex<Void> = Mutex(())
    @inline(__always)
    private func withIdStateLock<R>(_ body: () throws -> R) rethrows -> R {
        try idStateLock.withLock { _ in
            try body()
        }
    }

    private weak var _delegate: SpacetimeClientDelegate?
    public var delegate: SpacetimeClientDelegate? {
        get { withCallbackStateLock { _delegate } }
        set { withCallbackStateLock { _delegate = newValue } }
    }
    
    private var _connectionState: ConnectionState = .disconnected
    public var connectionState: ConnectionState {
        withStateLock { _connectionState }
    }

    private var connectionStateContinuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    /// An `AsyncStream` yielding the current `ConnectionState` and all subsequent state transitions.
    public var connectionStates: AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            let initial = withStateLock { () -> ConnectionState in
                connectionStateContinuations[id] = continuation
                return _connectionState
            }
            continuation.yield(initial)
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                _ = self.withStateLock {
                    self.connectionStateContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    private static let sharedState: Mutex<SpacetimeClient?> = Mutex(nil)
    public static var shared: SpacetimeClient? {
        get { sharedState.withLock { $0 } }
        set { sharedState.withLock { $0 = newValue } }
    }

    public static let clientCache = ClientCache()

    /// The `ClientCache` instance managed by this client. Defaults to `SpacetimeClient.clientCache`,
    /// or can be passed explicitly in `init` to isolate multi-client or multi-database state.
    public let cache: ClientCache

    private let transport: WebSocketTransport
    private let reconnectPolicy: ReconnectPolicy?
    private let compressionMode: CompressionMode
    public let lightMode: Bool
    public let confirmedReads: Bool?
    private var _negotiatedProtocol: SpacetimeWireProtocol = .v2
    public var negotiatedProtocol: SpacetimeWireProtocol {
        withStateLock { _negotiatedProtocol }
    }
    private var savedToken: String?
    private var reconnectAttempt = 0
    private var shouldStayConnected = false

    private let encoder = BSATNEncoder()
    private let decoder = BSATNDecoder()
    private var nextRequestId = RequestId(rawValue: 1)
    private var nextQuerySetId = QuerySetId(rawValue: 1)
    private var pendingReducerNames: [RequestId: String] = [:]
    private var pendingProcedureCallbacks: [RequestId: (Result<Data, Error>) -> Void] = [:]
    private var pendingOneOffQueryCallbacks: [RequestId: (Result<QueryRows, Error>) -> Void] = [:]
    private var pendingSubscriptionByRequestId: [RequestId: SubscriptionHandle] = [:]
    private var activeSubscriptionByQuerySetId: [QuerySetId: SubscriptionHandle] = [:]
    private var pendingUnsubscribeByRequestId: [RequestId: SubscriptionHandle] = [:]
    private var managedSubscriptions: [ObjectIdentifier: SubscriptionHandle] = [:]
    private var rawTransactionUpdateObserver: (@Sendable () -> Void)?
    private var rawTransactionUpdateCountObserver: (@Sendable (UInt64) -> Void)?
    private var pendingRawTransactionUpdateCount: UInt64 = 0
    private var rawTransactionUpdateCountDrainScheduled = false
    private let decodeQueue = DispatchQueue(label: "spacetimedb.client.decode", qos: .utility)

    // Send queue — NWWebSocketTransport handles its own internal queuing but we maintain 
    // a simplified queue to preserve ordering and handle connection lifecycle.
    private var sendQueue: [Data] = []
    /// Tables whose cached rows the next subscription rows replace (set on every connect).
    private var tablesToRefresh: Set<String> = []
    /// Request IDs of managed subscriptions replayed during the current reconnect pass.
    private var pendingReconnectRequestIds: Set<RequestId> = []
    /// Buffered `(querySetId, QueryRows)` payloads from replayed subscriptions awaiting full batch completion.
    private var pendingReconnectQueryRows: [(querySetId: QuerySetId?, rows: QueryRows)] = []
    /// Buffered incremental `TransactionUpdate`s received while a reconnect replay batch is still in flight.
    private var pendingReconnectTransactionUpdates: [TransactionUpdate] = []
    private var isTransportReady = false
    private var networkMonitor: NetworkMonitor?
    private let keepAlivePingInterval: Duration
    private let keepAlivePongTimeout: Duration
    private var keepAliveTask: Task<Void, Never>?
    private var keepAliveTimeoutTask: Task<Void, Never>?
    private var awaitingKeepAlivePong = false
    private var reconnectTask: Task<Void, Never>?
    private var isHandlingConnectionFailure = false
    private var transactionUpdateCallbackScheduled = false
    private var transactionUpdateCallbackDirty = false
    private let coalesceTransactionUpdateCallbacks: Bool

    public init(
        serverUrl: URL,
        moduleName: String,
        reconnectPolicy: ReconnectPolicy? = ReconnectPolicy(),
        compressionMode: CompressionMode = .gzip,
        lightMode: Bool = false,
        confirmedReads: Bool? = nil,
        cache: ClientCache = SpacetimeClient.clientCache,
        transport: WebSocketTransport? = nil,
        coalesceTransactionUpdateCallbacks: Bool = true,
        keepAlivePingIntervalSeconds: TimeInterval = 30.0,
        keepAlivePongTimeoutSeconds: TimeInterval = 10.0
    ) {
        self.serverUrl = serverUrl
        self.moduleName = moduleName
        self.reconnectPolicy = reconnectPolicy
        self.compressionMode = compressionMode
        self.lightMode = lightMode
        self.confirmedReads = confirmedReads
        self.cache = cache
        self.coalesceTransactionUpdateCallbacks = coalesceTransactionUpdateCallbacks
        let boundedPingInterval = max(1.0, keepAlivePingIntervalSeconds)
        let boundedPongTimeout = max(1.0, min(keepAlivePongTimeoutSeconds, boundedPingInterval))
        self.keepAlivePingInterval = .milliseconds(Int64((boundedPingInterval * 1000).rounded()))
        self.keepAlivePongTimeout = .milliseconds(Int64((boundedPongTimeout * 1000).rounded()))

        self.transport = transport ?? NWWebSocketTransport()
        self.transport.delegate = self
    }

    public func connect(token: String? = nil) {
        withStateLock {
            shouldStayConnected = true
            reconnectAttempt = 0
            if let token {
                self.savedToken = token
            }
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        
        startNetworkMonitor()
        performConnect(authToken: token ?? getSavedToken(), isReconnect: false)
    }

    /// Registers an optional callback fired synchronously after transaction
    /// updates are applied to the local cache.
    ///
    /// The callback may execute on internal non-main queues.
    public func setRawTransactionUpdateObserver(_ observer: (@Sendable () -> Void)?) {
        withCallbackStateLock {
            rawTransactionUpdateObserver = observer
        }
    }

    /// Registers an optional callback fired with the number of transaction
    /// updates applied since the last callback invocation.
    ///
    /// Updates are coalesced to reduce callback overhead on high-throughput
    /// streams. The callback may execute on internal non-main queues.
    public func setRawTransactionUpdateCountObserver(_ observer: (@Sendable (UInt64) -> Void)?) {
        withCallbackStateLock {
            rawTransactionUpdateCountObserver = observer
        }
    }

    private func getSavedToken() -> String? {
        withStateLock { savedToken }
    }

    private func performConnect(authToken: String?, isReconnect: Bool) {
        withStateLock {
            reconnectTask?.cancel()
            reconnectTask = nil
            isHandlingConnectionFailure = false
        }
        
        stopKeepAliveLoop()
        emitCounter(
            "spacetimedb.connection.attempts",
            tags: ["reconnect": isReconnect ? "true" : "false"]
        )
        var components = URLComponents(url: serverUrl, resolvingAgainstBaseURL: false)!
        components.path = "/v1/database/\(moduleName)/subscribe"
        var queryItems = [URLQueryItem(name: "compression", value: compressionMode.queryValue)]
        if lightMode {
            queryItems.append(URLQueryItem(name: "light", value: "true"))
        }
        if let confirmedReads {
            queryItems.append(URLQueryItem(name: "confirmed_reads", value: confirmedReads ? "true" : "false"))
        }
        components.queryItems = queryItems
        if components.scheme == "http" { components.scheme = "ws" }
        if components.scheme == "https" { components.scheme = "wss" }

        var headers: [String: String] = [:]
        if let token = authToken {
            headers["Authorization"] = "Bearer \(token)"
        }

        let (procedureCallbacks, queryCallbacks) = withStateLock { () -> ([RequestId: (Result<Data, Error>) -> Void], [RequestId: (Result<QueryRows, Error>) -> Void]) in
            isTransportReady = false
            _negotiatedProtocol = .v2
            sendQueue.removeAll()
            pendingReducerNames.removeAll()
            let procedureCallbacks = pendingProcedureCallbacks
            pendingProcedureCallbacks.removeAll()
            let queryCallbacks = pendingOneOffQueryCallbacks
            pendingOneOffQueryCallbacks.removeAll()
            pendingSubscriptionByRequestId.removeAll()
            pendingUnsubscribeByRequestId.removeAll()
            activeSubscriptionByQuerySetId.removeAll()
            pendingReconnectRequestIds.removeAll()
            pendingReconnectQueryRows.removeAll()
            pendingReconnectTransactionUpdates.removeAll()
            return (procedureCallbacks, queryCallbacks)
        }

        cache.revertAllOptimisticChanges()

        withIdStateLock {
            nextRequestId = RequestId(rawValue: 1)
            nextQuerySetId = QuerySetId(rawValue: 1)
        }
        
        failCallbacks(
            procedureCallbacks: procedureCallbacks,
            procedureError: SpacetimeClientProcedureError.disconnected,
            queryCallbacks: queryCallbacks,
            queryError: SpacetimeClientQueryError.disconnected
        )
        
        setConnectionState(isReconnect ? .reconnecting : .connecting)
        
        transport.connect(to: components.url!, protocols: SpacetimeWireProtocol.preferredProtocols, headers: headers)
    }

    public func disconnect() {
        let (procedureCallbacks, queryCallbacks, managed) = withStateLock {
            shouldStayConnected = false
            reconnectTask?.cancel()
            reconnectTask = nil
            isTransportReady = false
            _negotiatedProtocol = .v2
            sendQueue.removeAll()
            pendingReducerNames.removeAll()
            let procedureCallbacks = pendingProcedureCallbacks
            pendingProcedureCallbacks.removeAll()
            let queryCallbacks = pendingOneOffQueryCallbacks
            pendingOneOffQueryCallbacks.removeAll()
            pendingSubscriptionByRequestId.removeAll()
            pendingUnsubscribeByRequestId.removeAll()
            activeSubscriptionByQuerySetId.removeAll()
            pendingReconnectRequestIds.removeAll()
            pendingReconnectQueryRows.removeAll()
            pendingReconnectTransactionUpdates.removeAll()
            let managed = managedSubscriptions.values
            managedSubscriptions.removeAll()
            return (procedureCallbacks, queryCallbacks, managed)
        }
        
        cache.revertAllOptimisticChanges()
        stopNetworkMonitor()
        stopKeepAliveLoop()
        
        transport.disconnect()
        
        failCallbacks(
            procedureCallbacks: procedureCallbacks,
            procedureError: SpacetimeClientProcedureError.disconnected,
            queryCallbacks: queryCallbacks,
            queryError: SpacetimeClientQueryError.disconnected
        )
        
        for handle in managed {
            handle.markEnded()
        }
        
        setConnectionState(.disconnected)
        invokeDelegateCallback(named: "delegate.on_disconnect") { $0.onDisconnect(error: nil) }
    }
    
    private func failCallbacks(
        procedureCallbacks: [RequestId: (Result<Data, Error>) -> Void],
        procedureError: Error,
        queryCallbacks: [RequestId: (Result<QueryRows, Error>) -> Void],
        queryError: Error
    ) {
        for callback in procedureCallbacks.values {
            callback(.failure(procedureError))
        }
        for callback in queryCallbacks.values {
            callback(.failure(queryError))
        }
    }

    // MARK: - Serialized send queue

    private func enqueue(_ data: Data) {
        withStateLock {
            sendQueue.append(data)
        }
        flushQueue()
    }

    private func flushQueue() {
        let (framesToSend, messageCount, shouldScheduleMore): ([Data], Int, Bool) = withStateLock {
            guard isTransportReady, !sendQueue.isEmpty else {
                return ([], 0, false)
            }
            if _negotiatedProtocol == .v3 {
                let validMessages = sendQueue.filter { !$0.isEmpty }
                sendQueue = validMessages
                guard !sendQueue.isEmpty,
                      let batchCount = try? WebSocketV3Frames.countClientMessagesForFrame(sendQueue),
                      batchCount > 0,
                      let frame = try? WebSocketV3Frames.encodeClientMessages(Array(sendQueue[0..<batchCount])) else {
                    sendQueue.removeAll()
                    return ([], 0, false)
                }
                sendQueue.removeFirst(batchCount)
                return ([frame], batchCount, !sendQueue.isEmpty)
            } else {
                let data = sendQueue
                sendQueue.removeAll()
                return (data, data.count, false)
            }
        }
        guard !framesToSend.isEmpty else { return }

        emitCounter("spacetimedb.messages.out.count", by: Int64(messageCount))
        for frame in framesToSend {
            emitCounter("spacetimedb.messages.out.bytes", by: Int64(frame.count))

            transport.send(data: frame) { error in
                if let error = error {
                    Log.network.error("Send error: \(error.localizedDescription)")
                }
            }
        }

        if shouldScheduleMore {
            decodeQueue.async { [weak self] in
                self?.flushQueue()
            }
        }
    }

    public func send<T: Encodable>(_ message: T) {
        do {
            let data = try encoder.encode(message)
            enqueue(data)
        } catch {
            Log.network.error("Failed to encode message: \(error.localizedDescription)")
        }
    }

    public func send(_ message: ClientMessage) {
        do {
            let data = try encoder.encode(message)
            enqueue(data)
        } catch {
            Log.network.error("Failed to encode message: \(error.localizedDescription)")
        }
    }

    public func send(_ reducerName: String, _ args: Data, optimisticChanges: [OptimisticRowChange] = []) {
        let requestId = allocateRequestId()
        withStateLock {
            pendingReducerNames[requestId] = reducerName
        }
        if !optimisticChanges.isEmpty {
            cache.applyOptimisticChanges(requestId: requestId, changes: optimisticChanges)
            notifyRawTransactionUpdateObservers()
            notifyTransactionUpdate()
        }
        let call = CallReducer(requestId: requestId, flags: 0, reducer: reducerName, args: args)
        let message = ClientMessage.callReducer(call)
        send(message)
    }

    public func sendProcedure(_ procedureName: String, _ args: Data) {
        let call = CallProcedure(requestId: allocateRequestId(), flags: 0, procedure: procedureName, args: args)
        let message = ClientMessage.callProcedure(call)
        send(message)
    }

    public func sendProcedure(
        _ procedureName: String,
        _ args: Data,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        sendProcedure(procedureName, args, decodeReturn: { $0 }, completion: completion)
    }

    public func sendProcedure<R>(
        _ procedureName: String,
        _ args: Data,
        decodeReturn: @escaping (Data) throws -> R,
        completion: @escaping (Result<R, Error>) -> Void
    ) {
        let requestId = allocateRequestId()
        let timedCallback = makeTimedCallback(named: "procedure.completion") { (result: Result<Data, Error>) in
            switch result {
            case .success(let data):
                do {
                    completion(.success(try decodeReturn(data)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
        
        withStateLock {
            pendingProcedureCallbacks[requestId] = timedCallback
        }

        let call = CallProcedure(requestId: requestId, flags: 0, procedure: procedureName, args: args)
        let message = ClientMessage.callProcedure(call)
        send(message)
    }

    public func sendProcedure<R: Decodable>(
        _ procedureName: String,
        _ args: Data,
        responseType: R.Type,
        completion: @escaping (Result<R, Error>) -> Void
    ) {
        sendProcedure(
            procedureName,
            args,
            decodeReturn: { [decoder] data in
                try decoder.decode(responseType, from: data)
            },
            completion: completion
        )
    }

    public func sendProcedure(
        _ procedureName: String,
        _ args: Data
    ) async throws -> Data {
        try await sendProcedure(procedureName, args, timeout: nil)
    }

    public func sendProcedure(
        _ procedureName: String,
        _ args: Data,
        timeout: Duration?
    ) async throws -> Data {
        try Task.checkCancellation()
        let requestId = allocateRequestId()
        let asyncResponse = AsyncResponseContinuation<Data>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                asyncResponse.install(continuation)
                guard !Task.isCancelled else {
                    asyncResponse.resolve(.failure(CancellationError()))
                    return
                }

                let timedCallback = makeTimedCallback(named: "procedure.completion") { result in
                    asyncResponse.resolve(result)
                }
                
                withStateLock {
                    pendingProcedureCallbacks[requestId] = timedCallback
                }

                if let timeout {
                    asyncResponse.setTimeoutTask(
                        Task { [weak self] in
                            try? await Task.sleep(for: timeout)
                            guard let self else { return }
                            let removed = self.withStateLock {
                                self.pendingProcedureCallbacks.removeValue(forKey: requestId) != nil
                            }
                            if removed {
                                asyncResponse.resolve(.failure(SpacetimeClientProcedureError.timeout))
                            }
                        }
                    )
                }

                let call = CallProcedure(requestId: requestId, flags: 0, procedure: procedureName, args: args)
                let message = ClientMessage.callProcedure(call)
                send(message)
            }
        } onCancel: {
            withStateLock {
                _ = self.pendingProcedureCallbacks.removeValue(forKey: requestId)
            }
            asyncResponse.resolve(.failure(CancellationError()))
        }
    }

    public func sendProcedure<R: Decodable & Sendable>(
        _ procedureName: String,
        _ args: Data,
        responseType: R.Type
    ) async throws -> R {
        try await sendProcedure(procedureName, args, responseType: responseType, timeout: nil)
    }

    public func sendProcedure<R: Decodable & Sendable>(
        _ procedureName: String,
        _ args: Data,
        responseType: R.Type,
        timeout: Duration?
    ) async throws -> R {
        let raw = try await sendProcedure(procedureName, args, timeout: timeout)
        return try decoder.decode(responseType, from: raw)
    }

    public func oneOffQuery(_ query: String, completion: @escaping (Result<QueryRows, Error>) -> Void) {
        let requestId = allocateRequestId()
        let timedCallback = makeTimedCallback(named: "one_off_query.completion", completion)
        withStateLock {
            pendingOneOffQueryCallbacks[requestId] = timedCallback
        }
        send(ClientMessage.oneOffQuery(OneOffQuery(requestId: requestId, queryString: query)))
    }

    public func oneOffQuery(_ query: String) async throws -> QueryRows {
        try await oneOffQuery(query, timeout: nil)
    }

    public func oneOffQuery(_ query: String, timeout: Duration?) async throws -> QueryRows {
        try Task.checkCancellation()
        let requestId = allocateRequestId()
        let asyncResponse = AsyncResponseContinuation<QueryRows>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                asyncResponse.install(continuation)
                guard !Task.isCancelled else {
                    asyncResponse.resolve(.failure(CancellationError()))
                    return
                }

                let timedCallback = makeTimedCallback(named: "one_off_query.completion") { result in
                    asyncResponse.resolve(result)
                }
                
                withStateLock {
                    pendingOneOffQueryCallbacks[requestId] = timedCallback
                }

                if let timeout {
                    asyncResponse.setTimeoutTask(
                        Task { [weak self] in
                            try? await Task.sleep(for: timeout)
                            guard let self else { return }
                            let removed = self.withStateLock {
                                self.pendingOneOffQueryCallbacks.removeValue(forKey: requestId) != nil
                            }
                            if removed {
                                asyncResponse.resolve(.failure(SpacetimeClientQueryError.timeout))
                            }
                        }
                    )
                }

                send(ClientMessage.oneOffQuery(OneOffQuery(requestId: requestId, queryString: query)))
            }
        } onCancel: {
            withStateLock {
                _ = self.pendingOneOffQueryCallbacks.removeValue(forKey: requestId)
            }
            asyncResponse.resolve(.failure(CancellationError()))
        }
    }

    public func subscribe(
        queries: [String],
        onApplied: (@MainActor @Sendable () -> Void)? = nil,
        onError: (@MainActor @Sendable (String) -> Void)? = nil
    ) -> SubscriptionHandle {
        let timedOnApplied = onApplied.map { callback in
            makeTimedMainActorVoidCallback(named: "subscription.on_applied", callback)
        }
        let timedOnError = onError.map { callback in
            makeTimedMainActorCallback(named: "subscription.on_error", callback)
        }
        let handle = SubscriptionHandle(queries: queries, client: self, onApplied: timedOnApplied, onError: timedOnError)
        withStateLock {
            managedSubscriptions[ObjectIdentifier(handle)] = handle
        }
        startSubscription(handle)
        return handle
    }

    public func unsubscribe(_ handle: SubscriptionHandle, sendDroppedRows: Bool = false) {
        guard handle.state == .active, let querySetId = handle.querySetId else {
            return
        }

        let flags: UInt8 = sendDroppedRows ? 1 : 0
        let requestId = allocateRequestId()
        withStateLock {
            pendingUnsubscribeByRequestId[requestId] = handle
        }
        send(ClientMessage.unsubscribe(Unsubscribe(requestId: requestId, querySetId: querySetId, flags: flags)))
    }

    public func subscribeAll(tables: [String]) {
        guard !tables.isEmpty else {
            return
        }
        let queries = tables.map { "SELECT * FROM \($0)" }
        _ = subscribe(queries: queries)
    }

    @discardableResult
    private func startSubscription(_ handle: SubscriptionHandle) -> RequestId? {
        guard !handle.queries.isEmpty else {
            handle.markError("Subscription requires at least one query.")
            _ = withStateLock {
                managedSubscriptions.removeValue(forKey: ObjectIdentifier(handle))
            }
            return nil
        }

        let requestId = allocateRequestId()
        let querySetId = allocateQuerySetId()
        handle.markPending(requestId: requestId, querySetId: querySetId)
        withStateLock {
            pendingSubscriptionByRequestId[requestId] = handle
        }
        send(ClientMessage.subscribe(Subscribe(queryStrings: handle.queries, requestId: requestId, querySetId: querySetId)))
        return requestId
    }

    private func allocateRequestId() -> RequestId {
        withIdStateLock {
            let id = nextRequestId
            nextRequestId = RequestId(rawValue: nextRequestId.rawValue &+ 1)
            return id
        }
    }

    private func allocateQuerySetId() -> QuerySetId {
        withIdStateLock {
            let id = nextQuerySetId
            nextQuerySetId = QuerySetId(rawValue: nextQuerySetId.rawValue &+ 1)
            return id
        }
    }

    // MARK: - WebSocketTransportDelegate

    public func webSocketTransportDidConnect() {
        let negotiated = SpacetimeWireProtocol.normalize(transport.negotiatedProtocol)
        withStateLock {
            _negotiatedProtocol = negotiated
            isTransportReady = true
        }
        flushQueue()
    }

    public func webSocketTransportDidDisconnect(error: Error?) {
        withStateLock {
            isTransportReady = false
        }
        cache.revertAllOptimisticChanges()
        if let error = error {
            handleConnectionFailure(error)
        } else {
            setConnectionState(.disconnected)
        }
    }

    public func webSocketTransportDidReceivePong() {
        withStateLock {
            awaitingKeepAlivePong = false
            keepAliveTimeoutTask?.cancel()
            keepAliveTimeoutTask = nil
        }
    }

    public func webSocketTransportDidReceive(data: Data) {
        self.emitCounter("spacetimedb.messages.in.count")
        self.emitCounter("spacetimedb.messages.in.bytes", by: Int64(data.count))
        
        self.decodeQueue.async { [weak self] in
            guard let self = self else { return }
            let decoded = Self.decodeServerMessages(from: data)
            switch decoded {
            case .failure(let error):
                self.handleDecodedServerMessage(.failure(error))
            case .success(let messages):
                for message in messages {
                    self.handleDecodedServerMessage(.success(message))
                }
            }
        }
    }

    // MARK: - Message handling

    nonisolated private static func decodeServerMessages(from data: Data) -> Result<[ServerMessage], Error> {
        do {
            let bsatnData = try ServerMessageFrameDecoder.decodePayload(from: data)
            return .success(try WebSocketV3Frames.decodeServerMessages(from: bsatnData))
        } catch {
            return .failure(error)
        }
    }

    private func handleDecodedServerMessage(_ decoded: Result<ServerMessage, Error>) {
        switch decoded {
        case .failure(let error):
            Log.network.error("Failed to decode server message: \(error.localizedDescription)")
        case .success(let serverMsg):
            switch serverMsg {
            case .initialConnection(let connection):
                withStateLock {
                    reconnectAttempt = 0
                    savedToken = connection.token
                }
                
                setConnectionState(.connected)
                startKeepAliveLoop()
                invokeDelegateCallback(named: "delegate.on_identity_received") {
                    $0.onIdentityReceived(identity: Array(connection.identity.rawBytes), token: connection.token)
                }
                // Registering a table no longer subscribes to all of its rows: the app's own
                // subscriptions (`subscribe(queries:)`) decide what the cache holds.
                withStateLock {
                    tablesToRefresh = Set(cache.registeredTableNames)
                    pendingReconnectRequestIds.removeAll()
                    pendingReconnectQueryRows.removeAll()
                    pendingReconnectTransactionUpdates.removeAll()
                }
                resubscribeManagedSubscriptions()
                invokeDelegateCallback(named: "delegate.on_connect") { $0.onConnect() }
            case .transactionUpdate(let update):
                let wasBuffered = withStateLock { () -> Bool in
                    guard !pendingReconnectRequestIds.isEmpty else { return false }
                    pendingReconnectTransactionUpdates.append(update)
                    return true
                }
                if !wasBuffered {
                    cache.applyTransactionUpdate(update)
                    notifyRawTransactionUpdateObservers()
                    notifyTransactionUpdate()
                }
            case .subscribeApplied(let applied):
                let handle = handleSubscribeApplied(applied)
                enum ReconnectDisposition {
                    case waitingForMoreReplayedSubscriptions
                    case completedReconnectBatch(querySets: [(querySetId: QuerySetId?, rows: QueryRows)], bufferedUpdates: [TransactionUpdate])
                    case singleSubscription(staleTables: Set<String>)
                }

                var coveredNames = Set(applied.rows.tables.map { $0.table.rawValue })
                if let handle {
                    coveredNames.formUnion(Self.tableNames(in: handle.queries))
                }

                let disposition = withStateLock { () -> ReconnectDisposition in
                    if pendingReconnectRequestIds.remove(applied.requestId) != nil {
                        pendingReconnectQueryRows.append((querySetId: applied.querySetId, rows: applied.rows))
                        if pendingReconnectRequestIds.isEmpty {
                            let rows = pendingReconnectQueryRows
                            let updates = pendingReconnectTransactionUpdates
                            pendingReconnectQueryRows.removeAll()
                            pendingReconnectTransactionUpdates.removeAll()
                            tablesToRefresh.removeAll()
                            return .completedReconnectBatch(querySets: rows, bufferedUpdates: updates)
                        }
                        return .waitingForMoreReplayedSubscriptions
                    }

                    let stale = coveredNames.intersection(tablesToRefresh)
                    tablesToRefresh.subtract(stale)
                    return .singleSubscription(staleTables: stale)
                }

                switch disposition {
                case .waitingForMoreReplayedSubscriptions:
                    break
                case .completedReconnectBatch(let querySets, let bufferedUpdates):
                    cache.reconcile(querySets: querySets)
                    for buffered in bufferedUpdates {
                        cache.applyTransactionUpdate(buffered)
                    }
                    notifyRawTransactionUpdateObservers()
                    notifyTransactionUpdate()
                case .singleSubscription(let staleTables):
                    if staleTables.isEmpty {
                        let initial = applied.asTransactionUpdate()
                        cache.applyTransactionUpdate(initial)
                    } else {
                        cache.reconcile(
                            querySets: [(querySetId: applied.querySetId, rows: applied.rows)],
                            replacingTables: staleTables
                        )
                    }
                    notifyRawTransactionUpdateObservers()
                    notifyTransactionUpdate()
                }
            case .reducerResult(let reducerResult):
                handleReducerResult(reducerResult)
            case .other:
                break
            case .subscriptionError(let error):
                Log.client.warning("Subscription error for query_set_id=\(error.querySetId): \(error.error)")
                handleSubscriptionError(error)
            case .procedureResult(let result):
                handleProcedureResult(result)
            case .unsubscribeApplied(let applied):
                handleUnsubscribeApplied(applied)
            case .oneOffQueryResult(let result):
                handleOneOffQueryResult(result)
            }
        }
    }

    func handleReducerResult(_ reducerResult: ReducerResult) {
        let reducerName = withStateLock {
            pendingReducerNames.removeValue(forKey: reducerResult.requestId) ?? "<unknown>"
        }

        cache.revertOptimisticChanges(for: reducerResult.requestId)

        switch reducerResult.result {
        case .ok(let ok):
            cache.applyTransactionUpdate(ok.transactionUpdate)
            notifyRawTransactionUpdateObservers()
            notifyTransactionUpdate()
        case .okEmpty:
            notifyRawTransactionUpdateObservers()
            notifyTransactionUpdate()
        case .err(let errData):
            notifyRawTransactionUpdateObservers()
            notifyTransactionUpdate()
            let message: String
            if let decoded = try? decoder.decode(String.self, from: errData) {
                message = decoded
            } else if let utf8 = String(data: errData, encoding: .utf8), !utf8.isEmpty {
                message = utf8
            } else {
                message = "non-text payload (\(errData.count) bytes)"
            }
            Log.client.warning("Reducer request_id=\(reducerResult.requestId) returned error: \(message)")
            invokeDelegateCallback(named: "delegate.on_reducer_error") {
                $0.onReducerError(reducer: reducerName, message: message, isInternal: false)
            }
        case .internalError(let message):
            notifyRawTransactionUpdateObservers()
            notifyTransactionUpdate()
            Log.client.error("Reducer request_id=\(reducerResult.requestId) internal error: \(message)")
            invokeDelegateCallback(named: "delegate.on_reducer_error") {
                $0.onReducerError(reducer: reducerName, message: message, isInternal: true)
            }
            break
        }
    }

    func handleProcedureResult(_ result: ProcedureResult) {
        let callback = withStateLock {
            pendingProcedureCallbacks.removeValue(forKey: result.requestId)
        }
        
        guard let callback else {
            Log.client.warning("Received ProcedureResult for unknown request_id: \(result.requestId)")
            return
        }

        switch result.status {
        case .returned(let data):
            callback(.success(data))
        case .internalError(let message):
            callback(.failure(SpacetimeClientProcedureError.internalError(message)))
        }
    }

    func handleOneOffQueryResult(_ result: OneOffQueryResult) {
        let callback = withStateLock {
            pendingOneOffQueryCallbacks.removeValue(forKey: result.requestId)
        }
        
        guard let callback else {
            Log.client.warning("Received OneOffQueryResult for unknown request_id: \(result.requestId)")
            return
        }

        switch result.result {
        case .ok(let rows):
            callback(.success(rows))
        case .err(let message):
            callback(.failure(SpacetimeClientQueryError.serverError(message)))
        }
    }

    /// The table names in `SELECT * FROM <table> ...` queries, so a table whose subscription
    /// came back empty is still refreshed.
    static func tableNames(in queries: [String]) -> Set<String> {
        Set(queries.compactMap { q -> String? in
            let words = q.split(whereSeparator: { $0.isWhitespace || $0 == ";" })
            guard let i = words.firstIndex(where: { $0.uppercased() == "FROM" }), i + 1 < words.count else { return nil }
            let raw = words[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
            return raw.isEmpty ? nil : raw
        })
    }

    @discardableResult
    func handleSubscribeApplied(_ applied: SubscribeApplied) -> SubscriptionHandle? {
        let handle = withStateLock { () -> SubscriptionHandle? in
            let handle = pendingSubscriptionByRequestId.removeValue(forKey: applied.requestId)
            if let handle {
                activeSubscriptionByQuerySetId[applied.querySetId] = handle
            }
            return handle
        }
        
        handle?.markApplied(querySetId: applied.querySetId)
        return handle
    }

    func handleUnsubscribeApplied(_ applied: UnsubscribeApplied) {
        let handle = withStateLock { () -> SubscriptionHandle? in
            let handle = pendingUnsubscribeByRequestId.removeValue(forKey: applied.requestId)
            if let handle {
                activeSubscriptionByQuerySetId.removeValue(forKey: applied.querySetId)
                managedSubscriptions.removeValue(forKey: ObjectIdentifier(handle))
            }
            return handle
        }
        
        guard let handle else { return }
        handle.markEnded()

        if let rows = applied.rows {
            let update = queryRowsToTransactionUpdate(rows, querySetId: applied.querySetId, asInserts: false)
            cache.applyTransactionUpdate(update)
            notifyRawTransactionUpdateObservers()
            notifyTransactionUpdate()
        } else {
            cache.evictQuerySet(applied.querySetId)
            notifyRawTransactionUpdateObservers()
            notifyTransactionUpdate()
        }
    }

    @inline(__always)
    private func notifyRawTransactionUpdateObservers() {
        let (syncObserver, shouldScheduleCountDrain) = withCallbackStateLock { () -> ((@Sendable () -> Void)?, Bool) in
            pendingRawTransactionUpdateCount &+= 1
            let shouldSchedule = !rawTransactionUpdateCountDrainScheduled
            if shouldSchedule {
                rawTransactionUpdateCountDrainScheduled = true
            }
            return (rawTransactionUpdateObserver, shouldSchedule)
        }
        syncObserver?()

        guard shouldScheduleCountDrain else { return }
        Task { [weak self] in
            self?.drainRawTransactionUpdateCountObserver()
        }
    }

    private func drainRawTransactionUpdateCountObserver() {
        while true {
            let next = withCallbackStateLock { () -> ((@Sendable (UInt64) -> Void), UInt64)? in
                guard let observer = rawTransactionUpdateCountObserver else {
                    pendingRawTransactionUpdateCount = 0
                    rawTransactionUpdateCountDrainScheduled = false
                    return nil
                }
                guard pendingRawTransactionUpdateCount > 0 else {
                    rawTransactionUpdateCountDrainScheduled = false
                    return nil
                }
                let count = pendingRawTransactionUpdateCount
                pendingRawTransactionUpdateCount = 0
                return (observer, count)
            }

            guard let (observer, count) = next else { return }
            observer(count)
        }
    }

    func handleSubscriptionError(_ error: SubscriptionError) {
        let (handle, completedBatch): (SubscriptionHandle?, (rows: [(querySetId: QuerySetId?, rows: QueryRows)], updates: [TransactionUpdate])?) = withStateLock {
            var handle: SubscriptionHandle?
            var batchToFlush: (rows: [(querySetId: QuerySetId?, rows: QueryRows)], updates: [TransactionUpdate])?
            if let requestId = error.requestId {
                if let pending = pendingSubscriptionByRequestId.removeValue(forKey: requestId) {
                    managedSubscriptions.removeValue(forKey: ObjectIdentifier(pending))
                    handle = pending
                }
                if pendingReconnectRequestIds.remove(requestId) != nil, pendingReconnectRequestIds.isEmpty {
                    batchToFlush = (pendingReconnectQueryRows, pendingReconnectTransactionUpdates)
                    pendingReconnectQueryRows.removeAll()
                    pendingReconnectTransactionUpdates.removeAll()
                    tablesToRefresh.removeAll()
                }
            }
            if handle == nil {
                let active = activeSubscriptionByQuerySetId.removeValue(forKey: error.querySetId)
                if let active {
                    managedSubscriptions.removeValue(forKey: ObjectIdentifier(active))
                }
                handle = active
            }
            return (handle, batchToFlush)
        }

        handle?.markError(error.error)
        cache.evictQuerySet(error.querySetId)

        if let completedBatch {
            cache.reconcile(querySets: completedBatch.rows)
            for buffered in completedBatch.updates {
                cache.applyTransactionUpdate(buffered)
            }
            notifyRawTransactionUpdateObservers()
            notifyTransactionUpdate()
        } else {
            notifyRawTransactionUpdateObservers()
            notifyTransactionUpdate()
        }
    }

    private func resubscribeManagedSubscriptions() {
        let subsToStart = withStateLock {
            activeSubscriptionByQuerySetId.removeAll()
            pendingSubscriptionByRequestId.removeAll()
            return Array(managedSubscriptions.values.filter { $0.state != .ended })
        }

        var replayedRequestIds = Set<RequestId>()
        replayedRequestIds.reserveCapacity(subsToStart.count)
        for handle in subsToStart {
            if let requestId = startSubscription(handle) {
                replayedRequestIds.insert(requestId)
            }
        }

        if !replayedRequestIds.isEmpty {
            withStateLock {
                pendingReconnectRequestIds = replayedRequestIds
            }
        }
    }

    private func queryRowsToTransactionUpdate(_ rows: QueryRows, querySetId: QuerySetId, asInserts: Bool) -> TransactionUpdate {
        let updates = rows.tables.map { tableRows in
            let persistent = PersistentTableRows(
                inserts: asInserts ? tableRows.rows : .empty,
                deletes: asInserts ? .empty : tableRows.rows
            )
            return TableUpdate(tableName: tableRows.table, rows: [.persistentTable(persistent)])
        }

        return TransactionUpdate(querySets: [QuerySetUpdate(querySetId: querySetId, tables: updates)])
    }

    // MARK: - Network monitoring

    private func startNetworkMonitor() {
        let monitor = withStateLock { () -> NetworkMonitor? in
            guard networkMonitor == nil else {
                return nil
            }
            return NetworkMonitor()
        }
        guard let monitor else { return }
        
        monitor.onPathChange = { [weak self] isConnected in
            guard let self else { return }
            let shouldConnected = self.withStateLock { self.shouldStayConnected }
            let state = self.withStateLock { self._connectionState }
            let token = self.withStateLock { self.savedToken }
            
            if isConnected && shouldConnected {
                Log.network.info("Network restored, attempting reconnect")
                self.withStateLock {
                    self.reconnectAttempt = 0
                }
                
                guard state != .connected else { return }
                self.performConnect(authToken: token, isReconnect: true)
            }
        }
        monitor.start()
        
        withStateLock {
            networkMonitor = monitor
        }
    }

    private func stopNetworkMonitor() {
        let monitor = withStateLock { () -> NetworkMonitor? in
            let monitor = networkMonitor
            networkMonitor = nil
            return monitor
        }
        monitor?.stop()
    }

    // MARK: - Connection lifecycle

    private func setConnectionState(_ state: ConnectionState) {
        let continuations = withStateLock { () -> [AsyncStream<ConnectionState>.Continuation]? in
            guard _connectionState != state else { return nil }
            _connectionState = state
            return Array(connectionStateContinuations.values)
        }
        guard let continuations else { return }

        for continuation in continuations {
            continuation.yield(state)
        }
        
        emitGauge(
            "spacetimedb.connection.state",
            value: stateMetricValue(state),
            tags: ["state": stateMetricName(state)]
        )
        invokeDelegateCallback(named: "delegate.on_connection_state_change") {
            $0.onConnectionStateChange(state: state)
        }
    }

    private func handleConnectionFailure(_ error: Error) {
        let failureState = withStateLock { () -> (ConnectionState, [RequestId: (Result<Data, Error>) -> Void], [RequestId: (Result<QueryRows, Error>) -> Void])? in
            guard shouldStayConnected else { return nil }
            guard !isHandlingConnectionFailure else { return nil }
            isHandlingConnectionFailure = true
            let state = _connectionState
            let procCallbacks = pendingProcedureCallbacks
            pendingProcedureCallbacks.removeAll()
            let queryCallbacks = pendingOneOffQueryCallbacks
            pendingOneOffQueryCallbacks.removeAll()
            return (state, procCallbacks, queryCallbacks)
        }
        guard let (state, procCallbacks, queryCallbacks) = failureState else { return }

        Log.network.error("WebSocket error: \(error.localizedDescription)")
        emitCounter(
            "spacetimedb.connection.failures",
            tags: ["state": stateMetricName(state)]
        )
        stopKeepAliveLoop()
        transport.disconnect()

        failCallbacks(
            procedureCallbacks: procCallbacks,
            procedureError: error,
            queryCallbacks: queryCallbacks,
            queryError: error
        )

        if state == .connecting {
            invokeDelegateCallback(named: "delegate.on_connect_error") { @MainActor in $0.onConnectError(error: error) }
        }
        invokeDelegateCallback(named: "delegate.on_disconnect") { @MainActor in $0.onDisconnect(error: error) }

        guard let reconnectDelay = nextReconnectDelay() else {
            withStateLock {
                shouldStayConnected = false
            }
            setConnectionState(.disconnected)
            withStateLock {
                isHandlingConnectionFailure = false
            }
            return
        }

        setConnectionState(.reconnecting)

        let connected = withStateLock { networkMonitor?.isConnected ?? true }
        
        // If network is unavailable, defer reconnection until path restores.
        guard connected else {
            Log.network.info("Network unavailable, deferring reconnect until path restores")
            withStateLock {
                isHandlingConnectionFailure = false
            }
            return
        }

        withStateLock {
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(for: reconnectDelay)
                guard let self else { return }
                let (shouldStay, token) = self.withStateLock {
                    (self.shouldStayConnected, self.savedToken)
                }
                guard shouldStay else {
                    self.withStateLock { self.isHandlingConnectionFailure = false }
                    return
                }
                self.withStateLock { self.isHandlingConnectionFailure = false }
                self.performConnect(authToken: token, isReconnect: true)
            }
        }
    }

    // MARK: - Keepalive

    private func startKeepAliveLoop() {
        stopKeepAliveLoop()
        withStateLock {
            keepAliveTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let interval = self.withStateLock { self.keepAlivePingInterval }
                    
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { return }
                    self.sendKeepAlivePing()
                }
            }
        }
    }

    private func stopKeepAliveLoop() {
        withStateLock {
            keepAliveTask?.cancel()
            keepAliveTask = nil
            keepAliveTimeoutTask?.cancel()
            keepAliveTimeoutTask = nil
            awaitingKeepAlivePong = false
        }
    }

    private func sendKeepAlivePing() {
        let (shouldPing, isTimeout) = withStateLock { () -> (Bool, Bool) in
            guard shouldStayConnected, _connectionState == .connected else {
                return (false, false)
            }
            guard !awaitingKeepAlivePong else {
                return (false, true)
            }
            return (true, false)
        }
        
        if isTimeout {
            handleConnectionFailure(SpacetimeClientConnectionError.keepAliveTimeout)
            return
        }
        guard shouldPing else { return }

        withStateLock {
            awaitingKeepAlivePong = true
            keepAliveTimeoutTask?.cancel()
            let timeout = keepAlivePongTimeout
            keepAliveTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                let awaiting = self.withStateLock {
                    let val = self.awaitingKeepAlivePong
                    self.awaitingKeepAlivePong = false
                    return val
                }
                if awaiting {
                    self.handleConnectionFailure(SpacetimeClientConnectionError.keepAliveTimeout)
                }
            }
        }
        transport.sendPing { [weak self] error in
            guard let self else { return }
            if let error {
                self.withStateLock {
                    self.awaitingKeepAlivePong = false
                    self.keepAliveTimeoutTask?.cancel()
                    self.keepAliveTimeoutTask = nil
                }
                self.handleConnectionFailure(error)
            }
        }
    }

    private func nextReconnectDelay() -> Duration? {
        withStateLock {
            guard let reconnectPolicy else { return nil }
            reconnectAttempt += 1
            return reconnectPolicy.delay(forAttempt: reconnectAttempt)
        }
    }

    private func emitCounter(_ name: String, by value: Int64 = 1, tags: [String: String] = [:]) {
        guard let metrics = SpacetimeObservability.activeMetrics else { return }
        metrics.incrementCounter(name, by: value, tags: tags)
    }

    private func emitGauge(_ name: String, value: Double, tags: [String: String] = [:]) {
        guard let metrics = SpacetimeObservability.activeMetrics else { return }
        metrics.recordGauge(name, value: value, tags: tags)
    }

    private func emitTiming(_ name: String, milliseconds: Double, tags: [String: String] = [:]) {
        guard let metrics = SpacetimeObservability.activeMetrics else { return }
        metrics.recordTiming(name, milliseconds: milliseconds, tags: tags)
    }

    private func invokeDelegateCallback(
        named callbackName: String,
        _ callback: @escaping @MainActor (SpacetimeClientDelegate) -> Void
    ) {
        let delegate = withCallbackStateLock { _delegate }
        
        guard let delegate else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.emitTimedCallbackMetric(named: callbackName) {
                    callback(delegate)
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.emitTimedCallbackMetric(named: callbackName) {
                callback(delegate)
            }
        }
    }

    private func notifyTransactionUpdate() {
        guard coalesceTransactionUpdateCallbacks else {
            invokeDelegateCallback(named: "delegate.on_transaction_update") { $0.onTransactionUpdate(message: nil) }
            return
        }

        let shouldSchedule = withCallbackStateLock { () -> Bool in
            if transactionUpdateCallbackScheduled {
                transactionUpdateCallbackDirty = true
                return false
            }
            transactionUpdateCallbackScheduled = true
            transactionUpdateCallbackDirty = false
            return true
        }
        guard shouldSchedule else { return }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                drainTransactionUpdateCallbacksOnMainActor()
            }
            return
        }

        Task { @MainActor [weak self] in
            self?.drainTransactionUpdateCallbacksOnMainActor()
        }
    }

    @MainActor
    private func drainTransactionUpdateCallbacksOnMainActor() {
        while true {
            let delegate = withCallbackStateLock { _delegate }
            if let delegate {
                emitTimedCallbackMetric(named: "delegate.on_transaction_update") {
                    delegate.onTransactionUpdate(message: nil)
                }
            }

            let shouldContinue = withCallbackStateLock { () -> Bool in
                if transactionUpdateCallbackDirty {
                    transactionUpdateCallbackDirty = false
                    return true
                }
                transactionUpdateCallbackScheduled = false
                return false
            }
            if !shouldContinue {
                break
            }
        }
    }

    private func makeTimedVoidCallback(
        named callbackName: String,
        _ callback: @escaping () -> Void
    ) -> (() -> Void) {
        { [weak self] in
            guard let self else {
                callback()
                return
            }
            self.emitTimedCallbackMetric(named: callbackName, callback)
        }
    }

    private func makeTimedMainActorVoidCallback(
        named callbackName: String,
        _ callback: @escaping @MainActor @Sendable () -> Void
    ) -> (@MainActor @Sendable () -> Void) {
        { @MainActor [weak self] in
            guard let self else {
                callback()
                return
            }
            self.emitTimedCallbackMetric(named: callbackName, callback)
        }
    }

    private func makeTimedCallback<T>(
        named callbackName: String,
        _ callback: @escaping (T) -> Void
    ) -> ((T) -> Void) {
        { [weak self] value in
            guard let self else {
                callback(value)
                return
            }
            self.emitTimedCallbackMetric(named: callbackName) {
                callback(value)
            }
        }
    }

    private func makeTimedMainActorCallback<T: Sendable>(
        named callbackName: String,
        _ callback: @escaping @MainActor @Sendable (T) -> Void
    ) -> (@MainActor @Sendable (T) -> Void) {
        { @MainActor [weak self] value in
            guard let self else {
                callback(value)
                return
            }
            self.emitTimedCallbackMetric(named: callbackName) {
                callback(value)
            }
        }
    }

    private func emitTimedCallbackMetric(named callbackName: String, _ callback: () -> Void) {
        guard let metrics = SpacetimeObservability.activeMetrics else {
            callback()
            return
        }

        let start = ContinuousClock.now
        callback()
        let elapsed = start.duration(to: ContinuousClock.now)
        let components = elapsed.components
        let milliseconds =
            (Double(components.seconds) * 1000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
        metrics.recordTiming(
            "spacetimedb.callback.latency",
            milliseconds: milliseconds,
            tags: ["callback": callbackName]
        )
    }

    private func stateMetricName(_ state: ConnectionState) -> String {
        switch state {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reconnecting:
            return "reconnecting"
        }
    }

    private func stateMetricValue(_ state: ConnectionState) -> Double {
        switch state {
        case .disconnected:
            return 0
        case .connecting:
            return 1
        case .connected:
            return 2
        case .reconnecting:
            return 3
        }
    }
}

#if DEBUG
extension SpacetimeClient {
    func _test_simulateConnectionFailure(_ error: Error, shouldStayConnected: Bool = true) {
        withStateLock {
            self.shouldStayConnected = shouldStayConnected
        }
        handleConnectionFailure(error)
    }

    func _test_deliverServerMessage(_ message: ServerMessage) {
        handleDecodedServerMessage(.success(message))
    }

    func _test_setConnectionState(_ state: ConnectionState) {
        setConnectionState(state)
    }

    func _test_pendingProcedureCallbackCount() -> Int {
        withStateLock { pendingProcedureCallbacks.count }
    }

    func _test_pendingOneOffQueryCallbackCount() -> Int {
        withStateLock { pendingOneOffQueryCallbacks.count }
    }
}
#endif
