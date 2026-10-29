#if !os(watchOS)
import CoreBluetooth
import Foundation

/// Connects to the real racket over BLE. Firmware 1.5+ detects hits itself and sends only the samples around each
/// one (impact mode, `ImpactSource`); older firmware, and calibration or raw recording, stream every sample.
public final class RacketBLE: NSObject, SampleSource, ImpactSource, @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case poweredOff, unauthorized, idle, scanning, connecting, connected
        public var label: String {
            switch self {
            case .poweredOff: "Bluetooth is off"
            case .unauthorized: "Bluetooth permission needed"
            case .idle: "Not connected"
            case .scanning: "Searching for racket…"
            case .connecting: "Connecting…"
            case .connected: "Connected"
            }
        }
    }

    public enum FirmwareUpdateState: Equatable, Sendable {
        case idle
        case sending(Double)   // fraction of the image acked by the racket
        case verifying
        case restarting        // racket is rebooting into the new firmware
        case finished
        case failed(String)

        public var isInProgress: Bool {
            switch self {
            case .sending, .verifying, .restarting: true
            default: false
            }
        }
    }

    public var onSamples: (([IMUSample]) -> Void)?
    public var onImpactWindow: ((ImpactWindow) -> Void)?
    public var onPose: ((RacketProtocol.Pose) -> Void)?
    public var nativeCalibration: Calibration? { nil }
    /// Main-queue callbacks.
    public var onState: ((State) -> Void)?
    public var onStatus: ((RacketProtocol.Status) -> Void)?
    /// Verdict from the racket's on-device sweet-spot model (main queue).
    public var onVerdict: ((RacketProtocol.ShotVerdict) -> Void)?
    public var onTap: ((RacketProtocol.TapGesture) -> Void)?
    /// Firmware update progress (main queue).
    public var onFirmwareUpdate: ((FirmwareUpdateState) -> Void)?
    /// Whether the connected racket's firmware accepts updates over BLE (main queue).
    public var onFirmwareUpdateSupport: ((Bool) -> Void)?

    public private(set) var state: State = .idle {
        didSet { let s = state; DispatchQueue.main.async { self.onState?(s) } }
    }
    public private(set) var lostPackets = 0
    /// Hits whose window never arrived (the racket was still sending the previous one, or a chunk was lost).
    public private(set) var lostWindows = 0
    private var link = LinkStats()

    /// Link counters since the app started, for a recording's link log: subtract the value at the start.
    public struct LinkStats: Codable, Sendable, Equatable {
        /// Raw-stream packets received, and how many of them had the gyro at ±4000 dps.
        public var packets = 0
        public var packetsAt4000dps = 0
        /// Raw-stream packets missing from the sequence numbers.
        public var lostPackets = 0
        public var windows = 0
        public var lostWindows = 0

        public init() {}

        public static func - (a: LinkStats, b: LinkStats) -> LinkStats {
            var d = LinkStats()
            d.packets = a.packets - b.packets
            d.packetsAt4000dps = a.packetsAt4000dps - b.packetsAt4000dps
            d.lostPackets = a.lostPackets - b.lostPackets
            d.windows = a.windows - b.windows
            d.lostWindows = a.lostWindows - b.lostWindows
            return d
        }
    }

    public func linkStats() -> LinkStats { queue.sync { link } }

    private let queue = DispatchQueue(label: "tennisbuddy.ble", qos: .userInitiated)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    private var wantsConnection = false
    /// Wire scale of high-g, from the racket's status: ±400 g on firmware 1.6+, ±200 g by default before.
    private var h3lisRange: UInt8 = 3
    private var lastSeq: UInt16?
    private var timeBase: (micros: UInt32, wraps: Double)?
    private var lastMicros: UInt32 = 0
    private var wraps: Double = 0
    /// Impact mode (all on `queue`).
    private var wantsRaw = false
    private var supportsImpactMode = false
    private var assembler = ImpactWindowAssembler()
    private var awaitingWindow: UInt16?
    private var gyroWide = false

    // Firmware update (all on `queue`).
    private var otaControl: CBCharacteristic?
    private var tapSubscribeRetries = 0
    private var otaData: CBCharacteristic?
    private var otaImage: FirmwareImage?
    private var otaSent = 0
    private var otaAcked = 0
    /// Set once the racket accepted the image; cleared when it reconnects.
    private var otaRestartingInto: FirmwareImage?
    /// The link dropped after DONE, so the next status comes from the rebooted racket.
    private var otaRebooted = false
    private var otaWatchdog: DispatchWorkItem?

    private let service = CBUUID(string: RacketProtocol.serviceUUID)
    private let imuUUID = CBUUID(string: RacketProtocol.imuUUID)
    private let statusUUID = CBUUID(string: RacketProtocol.statusUUID)
    private let controlUUID = CBUUID(string: RacketProtocol.controlUUID)
    private let tapUUID = CBUUID(string: RacketProtocol.tapUUID)
    private let shotUUID = CBUUID(string: RacketProtocol.shotUUID)
    private let hitUUID = CBUUID(string: RacketProtocol.hitUUID)
    private let windowUUID = CBUUID(string: RacketProtocol.windowUUID)
    private let poseUUID = CBUUID(string: RacketProtocol.poseUUID)
    private let otaControlUUID = CBUUID(string: RacketProtocol.otaControlUUID)
    private let otaDataUUID = CBUUID(string: RacketProtocol.otaDataUUID)

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    public func start() {
        queue.async {
            self.wantsConnection = true
            self.scanIfReady()
        }
    }

    public func stop() {
        queue.async {
            self.wantsConnection = false
            self.central.stopScan()
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.peripheral = nil
            if self.central.state == .poweredOn { self.state = .idle }
        }
    }

    /// Every sample instead of impact windows: for calibration (still poses, ball drops) and raw recordings.
    public func setRawStream(_ raw: Bool) {
        queue.async {
            guard self.wantsRaw != raw else { return }
            self.wantsRaw = raw
            self.sendStreamMode()
        }
    }

    private func sendStreamMode() {
        guard let p = peripheral, let c = control, supportsImpactMode else { return }
        let mode: RacketProtocol.StreamMode = wantsRaw ? .raw : .impacts
        p.writeValue(Data([RacketProtocol.Command.streamMode.rawValue, mode.rawValue]), for: c, type: .withResponse)
    }

    /// Sends a new firmware image to the racket, which verifies it and reboots into it. Progress arrives
    /// through `onFirmwareUpdate`.
    public func updateFirmware(_ image: FirmwareImage) {
        queue.async {
            guard self.otaImage == nil, self.otaRestartingInto == nil else { return }
            guard let p = self.peripheral, let c = self.otaControl, self.otaData != nil else {
                return self.reportUpdate(.failed("The racket isn't connected, or its firmware predates wireless updates"))
            }
            // Subscribe again in case the first attempt at connect failed; harmless if already subscribed.
            p.setNotifyValue(true, for: c)
            self.otaImage = image
            self.otaSent = 0
            self.otaAcked = 0
            var begin = Data([RacketProtocol.OTACommand.begin.rawValue])
            withUnsafeBytes(of: UInt32(image.data.count).littleEndian) { begin.append(contentsOf: $0) }
            withUnsafeBytes(of: image.crc32.littleEndian) { begin.append(contentsOf: $0) }
            p.writeValue(begin, for: c, type: .withResponse)
            self.reportUpdate(.sending(0))
            self.armWatchdog("The racket stopped responding")
        }
    }

    public func cancelFirmwareUpdate() {
        queue.async {
            guard self.otaImage != nil else { return }
            if let p = self.peripheral, let c = self.otaControl {
                p.writeValue(Data([RacketProtocol.OTACommand.abort.rawValue]), for: c, type: .withResponse)
            }
            self.endUpdate(.idle)
        }
    }

    private func reportUpdate(_ s: FirmwareUpdateState) {
        DispatchQueue.main.async { self.onFirmwareUpdate?(s) }
    }

    private func endUpdate(_ s: FirmwareUpdateState) {
        otaImage = nil
        otaRestartingInto = nil
        otaRebooted = false
        otaWatchdog?.cancel()
        otaWatchdog = nil
        reportUpdate(s)
    }

    /// Fails the update if the racket goes quiet for too long; rearmed on every reply.
    private func armWatchdog(_ message: String, after seconds: Double = 10) {
        otaWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.otaImage != nil, let p = self.peripheral, let c = self.otaControl {
                p.writeValue(Data([RacketProtocol.OTACommand.abort.rawValue]), for: c, type: .withResponse)
            }
            self.endUpdate(.failed(message))
        }
        otaWatchdog = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Sends image chunks up to the end of the current window; the racket's PROGRESS ack opens the next one.
    private func sendWindow() {
        guard let image = otaImage, let p = peripheral, let c = otaData else { return }
        let size = image.data.count
        let windowEnd = min(size, (otaAcked / RacketProtocol.otaWindow + 1) * RacketProtocol.otaWindow)
        let chunk = p.maximumWriteValueLength(for: .withoutResponse)
        while otaSent < windowEnd && p.canSendWriteWithoutResponse {
            let n = min(chunk, windowEnd - otaSent)
            p.writeValue(image.data.subdata(in: otaSent..<otaSent + n), for: c, type: .withoutResponse)
            otaSent += n
        }
    }

    private func handleOTAReply(_ data: Data) {
        guard let image = otaImage, let first = data.first, let reply = RacketProtocol.OTAReply(rawValue: first) else { return }
        let b = [UInt8](data)
        switch reply {
        case .ready:
            armWatchdog("The racket stopped responding")
            sendWindow()
        case .progress:
            guard b.count >= 5 else { return }
            otaAcked = Int(UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24)
            reportUpdate(.sending(Double(otaAcked) / Double(image.data.count)))
            armWatchdog("The racket stopped responding")
            if otaAcked >= image.data.count, let p = peripheral, let c = otaControl {
                p.writeValue(Data([RacketProtocol.OTACommand.end.rawValue]), for: c, type: .withResponse)
                reportUpdate(.verifying)
            } else {
                sendWindow()
            }
        case .done:
            otaImage = nil
            otaRestartingInto = image
            reportUpdate(.restarting)
            armWatchdog("The racket didn't come back after restarting", after: 45)
        case .error:
            endUpdate(.failed(RacketProtocol.otaErrorMessage(b.count >= 2 ? b[1] : 0)))
        }
    }

    /// After the reboot, the first status says which firmware is actually running.
    private func checkRestartedFirmware(_ status: RacketProtocol.Status) {
        guard let image = otaRestartingInto, otaRebooted else { return }
        if let expected = image.version, expected != status.firmwareVersion {
            endUpdate(.failed("The new firmware didn't start, so the racket went back to \(status.firmwareVersion)"))
        } else {
            endUpdate(.finished)
        }
    }

    /// The racket this app is paired with. With several rackets in range, only this one is ever used.
    private static let pairedKey = "tennisbuddy.pairedRacket"
    private var pairedID: UUID? {
        get { UserDefaults.standard.string(forKey: Self.pairedKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.pairedKey) }
    }
    /// Rackets heard while choosing the first one to pair with: the nearest (strongest signal) wins.
    private var candidates: [UUID: (peripheral: CBPeripheral, rssi: Int)] = [:]
    private var pickWork: DispatchWorkItem?

    /// Forgets the paired racket so the next connection picks the nearest one (swap rackets, new owner).
    public func forgetRacket() {
        queue.async {
            self.pairedID = nil
            self.candidates = [:]
            self.pickWork?.cancel()
            self.pickWork = nil
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
        }
    }

    private func scanIfReady() {
        guard wantsConnection, central.state == .poweredOn, peripheral == nil else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [service])
        if let known = connected.first(where: { pairedID == nil || $0.identifier == pairedID }) {
            connect(known)
            return
        }
        state = .scanning
        candidates = [:]
        central.scanForPeripherals(withServices: [service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: pairedID == nil])
    }

    private func connectNearest() {
        pickWork = nil
        guard peripheral == nil, let best = candidates.values.max(by: { $0.rssi < $1.rssi }) else { return }
        candidates = [:]
        connect(best.peripheral)
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p)
    }

    /// Racket micros → seconds, counting the 32-bit counter's wraps (every ~71 minutes).
    private func racketTime(_ micros: UInt32) -> Double {
        if micros < lastMicros, lastMicros - micros > 1_000_000_000 { wraps += 4294.967296 }
        if micros > lastMicros || lastMicros - micros > 1_000_000_000 { lastMicros = micros }
        return Double(micros) / 1e6 + wraps
    }

    private func handleIMU(_ data: Data) {
        guard let packet = RacketProtocol.decodePacket(data) else { return }
        if let last = lastSeq {
            let gap = Int(packet.seq &- last) - 1
            if gap > 0 && gap < 1000 { lostPackets += gap; link.lostPackets += gap }
        }
        lastSeq = packet.seq
        let t0 = racketTime(packet.t0Micros)
        let wide = packet.flags & RacketProtocol.flagGyro4000 != 0
        link.packets += 1
        if wide { link.packetsAt4000dps += 1 }
        IMUSample.gyroSaturation = (wide ? 3990 : 1990) * .pi / 180
        let gyroScale = wide ? RacketProtocol.mpuGyroLSBPerDps / 2 : RacketProtocol.mpuGyroLSBPerDps
        let samples = packet.samples.enumerated().map { k, raw in
            RacketProtocol.convert(raw, time: t0 + Double(k) * 0.001, h3lisRange: h3lisRange, gyroLSBPerDps: gyroScale)
        }
        onSamples?(samples)
    }

    private func handleHit(_ hit: RacketProtocol.Hit) {
        if awaitingWindow != nil { lostWindows += 1; link.lostWindows += 1 }
        awaitingWindow = hit.seq
    }

    private func handleWindowChunk(_ chunk: RacketProtocol.WindowChunk) {
        guard let window = assembler.add(chunk, h3lisRange: h3lisRange, time: racketTime) else { return }
        if awaitingWindow == window.seq { awaitingWindow = nil }
        link.windows += 1
        IMUSample.gyroSaturation = (gyroWide ? 3990 : 1990) * .pi / 180
        onImpactWindow?(window)
    }
}

extension RacketBLE: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: state = .idle; scanIfReady()
        case .unauthorized: state = .unauthorized
        default: state = .poweredOff
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        if let paired = pairedID {
            if peripheral.identifier == paired { connect(peripheral) }
            return
        }
        // Unpaired: listen for a moment, then take the closest racket rather than the first one heard.
        let rssi = RSSI.intValue
        if rssi == 127 { return }   // CoreBluetooth's "unavailable"
        candidates[peripheral.identifier] = (peripheral, rssi)
        if pickWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.connectNearest() }
            pickWork = work
            queue.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        pairedID = peripheral.identifier
        lastSeq = nil
        supportsImpactMode = false
        assembler = ImpactWindowAssembler()
        awaitingWindow = nil
        // The racket may have rebooted (its clock restarts at 0): start timestamps fresh.
        lastMicros = 0
        wraps = 0
        peripheral.discoverServices([service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        state = .idle
        scanIfReady()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        self.peripheral = nil
        control = nil
        otaControl = nil
        otaData = nil
        DispatchQueue.main.async { self.onFirmwareUpdateSupport?(false) }
        // A reboot into new firmware is expected to drop the link; anything else ends the update.
        if otaImage != nil { endUpdate(.failed("Lost the connection to the racket; it kept its old firmware")) }
        if otaRestartingInto != nil { otaRebooted = true }
        state = .idle
        scanIfReady()   // auto-reconnect
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = peripheral.services?.first(where: { $0.uuid == service }) else { return }
        peripheral.discoverCharacteristics([imuUUID, statusUUID, controlUUID, shotUUID, otaControlUUID, otaDataUUID,
                                            hitUUID, windowUUID, poseUUID], for: s)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case imuUUID: peripheral.setNotifyValue(true, for: c)
            case statusUUID: peripheral.setNotifyValue(true, for: c); peripheral.readValue(for: c)
            case shotUUID: peripheral.setNotifyValue(true, for: c)
            case tapUUID:
                tapSubscribeRetries = 0
                peripheral.setNotifyValue(true, for: c)
                if c.properties.contains(.write) { otaControl = c }
            case controlUUID:
                control = c
                peripheral.writeValue(Data([RacketProtocol.Command.startStream.rawValue]), for: c, type: .withResponse)
                peripheral.writeValue(Data([RacketProtocol.Command.gyroRange.rawValue, 1]), for: c, type: .withResponse)
            case otaDataUUID: otaData = c
            case hitUUID, windowUUID, poseUUID:
                supportsImpactMode = true
                peripheral.setNotifyValue(true, for: c)
            default: break
            }
        }
        sendStreamMode()
        let canUpdate = otaControl != nil && otaData != nil
        DispatchQueue.main.async { self.onFirmwareUpdateSupport?(canUpdate) }
        state = .connected
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let data = characteristic.value else { return }
        if characteristic.uuid == imuUUID {
            handleIMU(data)
        } else if characteristic.uuid == windowUUID, let chunk = RacketProtocol.decodeWindowChunk(data) {
            handleWindowChunk(chunk)
        } else if characteristic.uuid == hitUUID, let hit = RacketProtocol.decodeHit(data) {
            handleHit(hit)
        } else if characteristic.uuid == poseUUID, let pose = RacketProtocol.decodePose(data) {
            gyroWide = pose.flags & RacketProtocol.flagGyro4000 != 0
            onPose?(pose)
        } else if characteristic.uuid == shotUUID, let v = RacketProtocol.decodeShotVerdict(data) {
            DispatchQueue.main.async { self.onVerdict?(v) }
        } else if characteristic === otaControl {
            handleOTAReply(data)
        } else if characteristic.uuid == tapUUID, let tap = RacketProtocol.decodeTap(data) {
            DispatchQueue.main.async { self.onTap?(tap) }
        } else if characteristic.uuid == statusUUID, let status = RacketProtocol.decodeStatus(data) {
            h3lisRange = status.h3lisRange
            checkRestartedFirmware(status)
            DispatchQueue.main.async { self.onStatus?(status) }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        // Without this, a rejected update command would only show up as a timeout.
        guard characteristic.uuid == otaControlUUID, let error, otaImage != nil else { return }
        endUpdate(.failed("The racket rejected the update command: \(error.localizedDescription)"))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == otaControlUUID, let error else { return }
        // On tap firmware 0006 is the notify-only tap characteristic, not an update channel. The racket can
        // answer a subscribe with "insufficient resources" while its BLE buffers are busy streaming, so retry.
        if characteristic !== otaControl {
            tapSubscribeRetries += 1
            guard tapSubscribeRetries <= 10 else { return }
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self, weak peripheral] in
                guard let self, let peripheral, self.peripheral === peripheral else { return }
                peripheral.setNotifyValue(true, for: characteristic)
            }
            return
        }
        let failure = FirmwareUpdateState.failed("Couldn't subscribe to the racket's update replies: \(error.localizedDescription)")
        if otaImage != nil { endUpdate(failure) } else { reportUpdate(failure) }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        sendWindow()
    }
}
#endif
