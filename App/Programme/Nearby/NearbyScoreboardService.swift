import Foundation
import Network
import Observation
import ProgrammeCore

/// Nearby read-only scoreboard: one scorer broadcasts presentation
/// snapshots; nearby displays render them and can do nothing else.
///
/// Transport is `Network` (TCP over Bonjour); pairing UI is
/// `DeviceDiscoveryUI`. There is deliberately no command path — the wire
/// decodes exactly one snapshot type, so a display is read-only by
/// construction, and a broken connection only ever affects the display.
/// The scorer never waits on this service: publishing is fire-and-forget
/// off the scoring path.
///
/// The clock is an anchor, not a stream. Displays render time locally
/// from the anchor; a slow heartbeat only keeps the receiver-local receipt
/// time fresh so live matches do not look stale (sender clocks may differ,
/// so the wire `sentAt` is never a freshness source). Scorer backgrounding
/// suspends delivery and displays go stale rather than wrong.
@MainActor
@Observable
final class NearbyScoreboardService {
    nonisolated static let serviceType = "_programme-sb._tcp"
    /// Heartbeat keeps live displays fresh without per-second streaming.
    private static let heartbeatInterval: Duration = .seconds(10)

    /// The one native service description for both sides: the scorer's
    /// `DevicePairingView` and the serving `NWListener` are built from this
    /// same provider, so discoverability and transport can never disagree
    /// about what is advertised. The transport stays plain Bonjour TCP:
    /// the SDK offers no `BrowserProvider` for application services, so
    /// `DevicePicker` can only discover Bonjour endpoints — and `.tcp` is
    /// the correct parameters object for a Bonjour-discovered TCP service.
    nonisolated static var pairingProvider: BonjourListenerProvider {
        BonjourListenerProvider.bonjour(type: Self.serviceType)
    }

    enum Advertising: Equatable {
        case off
        case waiting
        case serving(displayCount: Int)
    }

    enum DisplayLink {
        case idle
        case connecting
        case live
        case disconnected
    }

    private(set) var advertising: Advertising = .off
    private(set) var displayLink: DisplayLink = .idle
    /// Latest received snapshot on a display. Kept across disconnects so
    /// the display goes stale rather than blank; a new connection replaces
    /// it.
    private(set) var received: ScoreboardSnapshot?
    /// Receiver-local receipt time of the last valid frame. Link freshness
    /// is always `now - lastFrameReceivedAt`, never the wire `sentAt`.
    private(set) var lastFrameReceivedAt: Date?

    private var listener: NWListener?
    private var displays: [NWConnection] = []
    private var displayConnection: NWConnection?
    private var latest: ScoreboardSnapshot?
    private var heartbeat: Task<Void, Never>?

    // MARK: - Scorer side

    /// Advertises this match for nearby displays. Safe to call repeatedly;
    /// restarts cleanly.
    func startAdvertising() {
        stopAdvertising()
        guard let listener = try? NWListener(service: Self.pairingProvider.service, using: .tcp)
        else { return }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.serve(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.advertisingStateChanged(state) }
        }
        listener.start(queue: .main)
        self.listener = listener
        advertising = .waiting
    }

    /// Broadcasts a snapshot to every connected display. Fire-and-forget:
    /// scoring never waits on delivery.
    func publish(_ snapshot: ScoreboardSnapshot) {
        latest = snapshot
        sendLatest()
    }

    func stopAdvertising() {
        heartbeat?.cancel()
        heartbeat = nil
        for display in displays { display.cancel() }
        displays = []
        listener?.cancel()
        listener = nil
        latest = nil
        advertising = .off
    }

    // MARK: - Display side

    /// Connects to a scorer chosen in the system picker, then receives.
    /// Anything received decodes through the snapshot wire or is dropped.
    func connect(to endpoint: Network.Bonjour.Endpoint) {
        disconnectDisplay()
        received = nil
        lastFrameReceivedAt = nil
        let connection = NWConnection(to: endpoint.nwEndpoint, using: .tcp)
        displayConnection = connection
        displayLink = .connecting
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.displayStateChanged(state) }
        }
        connection.start(queue: .main)
        receiveLoop(connection, decoder: ScoreboardWire.Decoder())
    }

    func disconnectDisplay() {
        displayConnection?.cancel()
        displayConnection = nil
        displayLink = .idle
        // `received` and its receipt time survive: the display shows the
        // last snapshot with a stale banner instead of going blank. A new
        // connection replaces both.
    }

    // MARK: - Private

    private func serve(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.displayConnectionStateChanged(connection, state) }
        }
        connection.start(queue: .main)
        displays.append(connection)
        updateServing()
        updateHeartbeat()
        sendLatest(to: connection)
    }

    private func displayConnectionStateChanged(_ connection: NWConnection, _ state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            displays.removeAll { $0 === connection }
            updateServing()
            updateHeartbeat()
        default: break
        }
    }

    private func updateServing() {
        guard advertising != .off else { return }
        advertising = displays.isEmpty ? .waiting : .serving(displayCount: displays.count)
    }

    private func advertisingStateChanged(_ state: NWListener.State) {
        switch state {
        case .failed, .cancelled:
            heartbeat?.cancel()
            heartbeat = nil
            advertising = .off
        default: break
        }
    }

    private func updateHeartbeat() {
        guard listener != nil, !displays.isEmpty else {
            heartbeat?.cancel()
            heartbeat = nil
            return
        }
        guard heartbeat == nil else { return }

        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.heartbeatInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.sendLatest()
            }
        }
    }

    private func sendLatest() {
        guard let latest else { return }
        for display in displays { sendLatest(to: display) }
    }

    private func sendLatest(to display: NWConnection) {
        guard let latest, let frame = try? ScoreboardWire.encode(latest) else { return }
        display.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func displayStateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready: displayLink = .live
        case .failed, .cancelled: displayLink = .disconnected
        default: break
        }
    }

    private func receiveLoop(_ connection: NWConnection, decoder: ScoreboardWire.Decoder) {
        var decoder = decoder
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                // A replaced connection's late frames must neither revive
                // its snapshots nor disconnect the current link: only the
                // live connection may mutate receive state.
                guard let self, connection === self.displayConnection else { return }
                if let data, !data.isEmpty {
                    for snapshot in decoder.append(data) {
                        self.received = snapshot
                        self.lastFrameReceivedAt = Date()
                        self.displayLink = .live
                    }
                }
                if error == nil {
                    self.receiveLoop(connection, decoder: decoder)
                } else {
                    self.displayLink = .disconnected
                }
            }
        }
    }
}
