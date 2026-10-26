import Foundation
import Network

/// TCP listener for the observation packets.
///
/// The app listens and the host connects, because `iproxy` is what makes the
/// USB-C link look like a local TCP socket. Nothing here knows or cares whether
/// the peer arrived over USB, Ethernet or Wi-Fi: it accepts one client, streams
/// packets, and keeps capturing when that client goes away.
///
/// `TCP_NODELAY` is on so a 40-byte packet is not held back by Nagle waiting for
/// more payload; at 240 Hz the packets are already tiny and spaced.
final class ObservationServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tennisrobot.observation.server", qos: .userInteractive)
    private let lock = NSLock()

    private var listener: NWListener?
    private var connection: NWConnection?

    private var _connected = false
    private var _port: UInt16 = 5000
    private var bindRetries = 0
    private var _lastError: String?
    private var _sentPackets: UInt64 = 0

    /// Called on the server queue whenever the connection or error state
    /// changes. Hop to the main thread before touching UI.
    var onStateChange: (@Sendable (Bool, String?) -> Void)?

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _connected
    }

    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return _port
    }

    var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastError
    }

    var sentPackets: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _sentPackets
    }

    func start(port: UInt16) {
        queue.async { [weak self] in
            self?.bindRetries = 0
            self?.startOnQueue(port: port)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.connection?.cancel()
            self.connection = nil
            self.update { self._connected = false }
        }
    }

    func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.update {
                        self._lastError = "send: \(error.localizedDescription)"
                    }
                    self.notify()
                    self.drop(connection)
                } else {
                    self.update { self._sentPackets &+= 1 }
                }
            })
        }
    }

    // MARK: - Private

    private func startOnQueue(port: UInt16) {
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        update {
            self._port = port
            self._connected = false
            self._lastError = nil
            self._sentPackets = 0
        }
        notify()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            fail("invalid port \(port)")
            return
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2

        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.update { self._lastError = nil }
                    self.bindRetries = 0
                    self.notify()
                case .failed(let error):
                    // A listener left behind by a previous launch can hold the
                    // port for a moment after the process dies. Retrying is
                    // cheaper than making the operator relaunch the app.
                    if self.bindRetries < 2 {
                        self.bindRetries += 1
                        self.listener?.cancel()
                        self.listener = nil
                        NSLog("TennisCamera: listen on %d failed (%@), retrying",
                              Int(port), error.localizedDescription)
                        self.queue.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                            self?.startOnQueue(port: port)
                        }
                    } else {
                        NSLog("TennisCamera: listen on %d failed again: %@",
                              Int(port), error.localizedDescription)
                        self.fail("listen: \(error.localizedDescription)")
                        self.update { self._connected = false }
                        self.notify()
                    }
                case .cancelled:
                    break
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: self.queue)
        } catch {
            fail("listen: \(error.localizedDescription)")
        }
    }

    private func accept(_ newConnection: NWConnection) {
        // One client at a time. A reconnect replaces the old data path instead of
        // waiting for its state machine to notice, because a half-open socket
        // after `iproxy` restarts can sit in `.ready` indefinitely.
        connection?.cancel()
        connection = newConnection

        newConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.update {
                    self._connected = true
                    self._lastError = nil
                }
                self.notify()
            case .failed(let error), .waiting(let error):
                self.update { self._lastError = error.localizedDescription }
                self.markDisconnected(newConnection)
            case .cancelled:
                self.markDisconnected(newConnection)
            default:
                break
            }
        }
        newConnection.start(queue: queue)
        drain(newConnection)
    }

    /// Read and discard anything the peer sends, so a clean close is noticed.
    private func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.markDisconnected(connection)
                return
            }
            self.drain(connection)
        }
    }

    private func drop(_ connection: NWConnection) {
        guard self.connection === connection else { return }
        self.connection = nil
        connection.cancel()
        update { self._connected = false }
        notify()
    }

    private func markDisconnected(_ connection: NWConnection) {
        guard self.connection === connection else { return }
        self.connection = nil
        update { self._connected = false }
        notify()
    }

    private func fail(_ message: String) {
        update { self._lastError = message }
        notify()
    }

    private func update(_ body: () -> Void) {
        lock.lock()
        body()
        lock.unlock()
    }

    private func notify() {
        lock.lock()
        let connected = _connected
        let error = _lastError
        lock.unlock()
        onStateChange?(connected, error)
    }
}
