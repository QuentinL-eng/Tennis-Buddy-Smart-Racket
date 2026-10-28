#if !os(watchOS)
import CoreBluetooth
import Foundation

/// Connects to the real racket over BLE and streams its samples.
public final class RacketBLE: NSObject, SampleSource, @unchecked Sendable {
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

    public var onSamples: (([IMUSample]) -> Void)?
    public var nativeCalibration: Calibration? { nil }
    /// Main-queue callbacks.
    public var onState: ((State) -> Void)?
    public var onStatus: ((RacketProtocol.Status) -> Void)?
    /// Verdict from the racket's on-device sweet-spot model (main queue).
    public var onVerdict: ((RacketProtocol.ShotVerdict) -> Void)?
    /// Handle-tap gesture (main queue).
    public var onTap: ((RacketProtocol.TapGesture) -> Void)?

    public private(set) var state: State = .idle {
        didSet { let s = state; DispatchQueue.main.async { self.onState?(s) } }
    }
    public private(set) var lostPackets = 0

    private let queue = DispatchQueue(label: "tennisbuddy.ble", qos: .userInitiated)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    private var wantsConnection = false
    private var h3lisRange: UInt8 = 1
    private var lastSeq: UInt16?
    private var timeBase: (micros: UInt32, wraps: Double)?
    private var lastMicros: UInt32 = 0
    private var wraps: Double = 0

    private let service = CBUUID(string: RacketProtocol.serviceUUID)
    private let imuUUID = CBUUID(string: RacketProtocol.imuUUID)
    private let statusUUID = CBUUID(string: RacketProtocol.statusUUID)
    private let controlUUID = CBUUID(string: RacketProtocol.controlUUID)
    private let shotUUID = CBUUID(string: RacketProtocol.shotUUID)
    private let tapUUID = CBUUID(string: RacketProtocol.tapUUID)

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

    public func setHighGRange(_ code: UInt8) {
        queue.async {
            guard let p = self.peripheral, let c = self.control else { return }
            p.writeValue(Data([RacketProtocol.Command.h3lisRange.rawValue, code]), for: c, type: .withResponse)
        }
    }

    private func scanIfReady() {
        guard wantsConnection, central.state == .poweredOn, peripheral == nil else { return }
        if let known = central.retrieveConnectedPeripherals(withServices: [service]).first {
            connect(known)
            return
        }
        state = .scanning
        central.scanForPeripherals(withServices: [service])
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p)
    }

    private func handleIMU(_ data: Data) {
        guard let packet = RacketProtocol.decodePacket(data) else { return }
        if let last = lastSeq {
            let gap = Int(packet.seq &- last) - 1
            if gap > 0 && gap < 1000 { lostPackets += gap }
        }
        lastSeq = packet.seq
        if packet.t0Micros < lastMicros, lastMicros - packet.t0Micros > 1_000_000_000 { wraps += 4294.967296 }
        lastMicros = packet.t0Micros
        let t0 = Double(packet.t0Micros) / 1e6 + wraps
        let wide = packet.flags & RacketProtocol.flagGyro4000 != 0
        IMUSample.gyroSaturation = (wide ? 3990 : 1990) * .pi / 180
        let gyroScale = wide ? RacketProtocol.mpuGyroLSBPerDps / 2 : RacketProtocol.mpuGyroLSBPerDps
        let samples = packet.samples.enumerated().map { k, raw in
            RacketProtocol.convert(raw, time: t0 + Double(k) * 0.001, h3lisRange: h3lisRange, gyroLSBPerDps: gyroScale)
        }
        onSamples?(samples)
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
        connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        lastSeq = nil
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
        state = .idle
        scanIfReady()   // auto-reconnect
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = peripheral.services?.first(where: { $0.uuid == service }) else { return }
        peripheral.discoverCharacteristics([imuUUID, statusUUID, controlUUID, shotUUID, tapUUID], for: s)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case imuUUID: peripheral.setNotifyValue(true, for: c)
            case statusUUID: peripheral.setNotifyValue(true, for: c); peripheral.readValue(for: c)
            case shotUUID, tapUUID: peripheral.setNotifyValue(true, for: c)
            case controlUUID:
                control = c
                peripheral.writeValue(Data([RacketProtocol.Command.startStream.rawValue]), for: c, type: .withResponse)
                // ±2000 dps clips fast spins (twirling the racket in the hand). Older firmware ignores this.
                peripheral.writeValue(Data([RacketProtocol.Command.gyroRange.rawValue, 1]), for: c, type: .withResponse)
            default: break
            }
        }
        state = .connected
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let data = characteristic.value else { return }
        if characteristic.uuid == imuUUID {
            handleIMU(data)
        } else if characteristic.uuid == shotUUID, let v = RacketProtocol.decodeShotVerdict(data) {
            DispatchQueue.main.async { self.onVerdict?(v) }
        } else if characteristic.uuid == tapUUID, let t = RacketProtocol.decodeTap(data) {
            DispatchQueue.main.async { self.onTap?(t) }
        } else if characteristic.uuid == statusUUID, let status = RacketProtocol.decodeStatus(data) {
            h3lisRange = status.h3lisRange
            DispatchQueue.main.async { self.onStatus?(status) }
        }
    }
}
#endif
