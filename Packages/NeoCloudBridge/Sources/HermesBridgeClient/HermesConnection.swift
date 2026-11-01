import Foundation
import CloudBridgeCore

// MARK: - Event fan-out

/// One connection, any number of listeners.
///
/// The controller subscribes once and keeps its own copy of the state; a stream that was not
/// terminated keeps working across reconnects, which is what "recover after a drop" needs.
final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<HermesBridgeEvent>.Continuation] = [:]

    func stream() -> AsyncStream<HermesBridgeEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock { self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    func publish(_ event: HermesBridgeEvent) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(event) }
    }

    func finish() {
        let targets = lock.withLock { () -> [AsyncStream<HermesBridgeEvent>.Continuation] in
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        for continuation in targets { continuation.finish() }
    }
}

// MARK: - Connection

struct ConnectionContext: Sendable {
    let transport: HermesSocketTransport
    let eventHub: EventHub
}

/// Owns the socket, the pending RPC continuations and the read loop.
///
/// An actor because three things must not interleave: opening, correlating responses, and tearing
/// down on a drop. Every generation check below exists so a late frame from a dead socket cannot
/// resolve a request made on the new one.
actor WireConnection {
    private var transport: HermesSocketTransport?
    private var eventHub: EventHub?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var readerTask: Task<Void, Never>?
    private var connectTask: Task<ConnectionContext, Error>?
    private var activeMessageID: UUID?
    private var idCounter = 0
    private var generation = 0

    var isConnected: Bool { transport != nil }

    func setActiveMessage(_ messageID: UUID?) {
        activeMessageID = messageID
    }

    func connectIfNeeded(_ make: @Sendable @escaping () async throws -> ConnectionContext) async throws {
        if transport != nil { return }
        if let connectTask { return _ = try await connectTask.value }
        let task = Task { try await make() }
        connectTask = task
        do {
            let context = try await task.value
            transport = context.transport
            eventHub = context.eventHub
            connectTask = nil
            generation += 1
            startReader(generation: generation, transport: context.transport)
        } catch {
            connectTask = nil
            throw error
        }
    }

    private func startReader(generation: Int, transport: HermesSocketTransport) {
        readerTask?.cancel()
        readerTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let text = try await transport.receive()
                    await self?.handle(text: text, generation: generation)
                } catch {
                    await self?.handleDisconnect(error, generation: generation)
                    return
                }
            }
        }
    }

    private func handle(text: String, generation: Int) {
        guard generation == self.generation else { return }
        for frame in HermesWireCodec.frames(from: text) {
            switch frame {
            case .response(let id, let result):
                resolve(id, with: .success(result))
            case .failure(let id, let error):
                resolve(id, with: .failure(HermesTransportError.rpc(code: error.code, message: error.message)))
            case .event(let params):
                if let event = HermesEventMapper.event(from: params, messageID: activeMessageID) {
                    if event.kind == .completed || event.kind == .failed { activeMessageID = nil }
                    eventHub?.publish(event)
                }
            case .serverRequest(let id, let method, let params):
                // The cloud channel cannot answer a question. Surface it so the bridge can hold the
                // task at `waitingOnMac` instead of pretending the turn is progressing.
                eventHub?.publish(HermesBridgeEvent(kind: .interactive, messageID: activeMessageID,
                                                    text: params["prompt"].string,
                                                    detail: "\(method):\(id)"))
            case .unrecognised:
                // Unknown frames are never forwarded: the executor only sees typed events.
                continue
            }
        }
    }

    private func handleDisconnect(_ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        let detail = (error as? HermesTransportError)?.description ?? error.localizedDescription
        transport = nil
        readerTask = nil
        let failed = pending
        pending.removeAll()
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        for (_, continuation) in failed {
            continuation.resume(throwing: HermesTransportError.disconnected(detail))
        }
        eventHub?.publish(HermesBridgeEvent(kind: .disconnected, messageID: activeMessageID, detail: detail))
    }

    func call(_ method: String, params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        guard let transport else { throw HermesTransportError.notConnected }
        idCounter += 1
        // The id correlates this response with this request in this connection. It is not an
        // idempotency key and is never persisted: Hermes does not deduplicate on it.
        let id = "neo-\(generation)-\(idCounter)"
        let frame = HermesWireCodec.request(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expire(id, method: method)
            }
            Task {
                do { try await transport.send(frame) }
                catch { self.fail(id, error: error) }
            }
        }
    }

    private func resolve(_ id: String, with result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timeouts.removeValue(forKey: id)?.cancel()
        continuation.resume(with: result)
    }

    private func expire(_ id: String, method: String) {
        resolve(id, with: .failure(HermesTransportError.timeout(method)))
    }

    private func fail(_ id: String, error: Error) {
        resolve(id, with: .failure(error))
    }

    func close() async {
        generation += 1
        readerTask?.cancel()
        readerTask = nil
        let live = transport
        transport = nil
        let failed = pending
        pending.removeAll()
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        for (_, continuation) in failed {
            continuation.resume(throwing: HermesTransportError.disconnected("closed"))
        }
        await live?.close()
    }
}

// MARK: - URLSession transport

/// The real socket. Deliberately thin: framing and policy live in the codec and the client.
public final class URLSessionHermesSocket: HermesSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func open(url: URL) async throws {
        let webSocket = session.webSocketTask(with: url)
        // Hermes can stream large replay frames; the default limit is too small for a long transcript.
        webSocket.maximumMessageSize = 16 * 1024 * 1024
        webSocket.resume()
        lock.withLock { task = webSocket }
    }

    public func send(_ text: String) async throws {
        guard let task = lock.withLock({ task }) else { throw HermesTransportError.notConnected }
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        guard let task = lock.withLock({ task }) else { throw HermesTransportError.notConnected }
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    public func close() async {
        let webSocket = lock.withLock { () -> URLSessionWebSocketTask? in
            let current = task
            task = nil
            return current
        }
        webSocket?.cancel(with: .goingAway, reason: nil)
    }
}
