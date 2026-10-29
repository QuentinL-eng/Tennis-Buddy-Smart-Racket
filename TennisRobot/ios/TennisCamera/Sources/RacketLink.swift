import CoreBluetooth
import Foundation

/// Minimal BLE client for the Tennis Buddy racket (protocol: firmware/include/protocol.h). It forwards the
/// raw notifications, stamped on arrival with the camera's clock, and decodes nothing: conversion to physical
/// units happens offline, where the packet's flags and the status packet say which scales applied.
final class RacketLink: NSObject, @unchecked Sendable {
    struct Snapshot {
        var state = "off"
        var imuPackets = 0
        var lostPackets = 0
        var packetsPerSecond = 0.0
        var gyro4000 = false
        var batteryMV = 0
        /// Packets the racket itself dropped because its BLE queue was full (status packet, since boot).
        var racketDropped = 0
    }

    private static let serviceUUID = CBUUID(string: "7E5B0001-6B1D-4D8E-9C1A-7E5B7E5B0001")
    private static let imuUUID = CBUUID(string: "7E5B0002-6B1D-4D8E-9C1A-7E5B7E5B0001")
    private static let statusUUID = CBUUID(string: "7E5B0003-6B1D-4D8E-9C1A-7E5B7E5B0001")
    private static let controlUUID = CBUUID(string: "7E5B0004-6B1D-4D8E-9C1A-7E5B7E5B0001")
    private static let shotUUID = CBUUID(string: "7E5B0005-6B1D-4D8E-9C1A-7E5B7E5B0001")
    private static let tapUUID = CBUUID(string: "7E5B0006-6B1D-4D8E-9C1A-7E5B7E5B0001")

    /// Every notification, with its arrival time on the camera clock. Called on the BLE queue.
    var onRecord: ((UInt64, SessionLogger.RacketKind, Data) -> Void)?

    private let queue = DispatchQueue(label: "tennisrobot.racket.ble", qos: .userInitiated)
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var wantsConnection = false

    private let lock = NSLock()
    private var snap = Snapshot()
    private var lastSeq: UInt16?
    private var windowStartNs: UInt64 = 0
    private var windowCount = 0
    private var lastStatus: Data?

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snap
    }

    /// The most recent status packet, so a session can begin with the racket's range settings on record.
    var latestStatus: Data? {
        lock.lock()
        defer { lock.unlock() }
        return lastStatus
    }

    func start() {
        queue.async {
            self.wantsConnection = true
            if self.central == nil {
                // Created on first use so the Bluetooth permission prompt appears when capture starts.
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            } else {
                self.scanIfReady()
            }
        }
    }

    func stop() {
        queue.async {
            self.wantsConnection = false
            self.central?.stopScan()
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.peripheral = nil
            self.setState("off")
        }
    }

    private func setState(_ s: String) {
        lock.lock()
        snap.state = s
        lock.unlock()
    }

    private func scanIfReady() {
        guard wantsConnection, let central, central.state == .poweredOn, peripheral == nil else { return }
        if let known = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first {
            connect(known)
            return
        }
        setState("searching")
        central.scanForPeripherals(withServices: [Self.serviceUUID])
    }

    private func connect(_ p: CBPeripheral) {
        central?.stopScan()
        peripheral = p
        p.delegate = self
        setState("connecting")
        // A fresh link starts a fresh count; otherwise earlier runs' losses pile onto this one.
        lock.lock()
        snap.imuPackets = 0
        snap.lostPackets = 0
        snap.packetsPerSecond = 0
        lastSeq = nil
        windowStartNs = 0
        windowCount = 0
        lock.unlock()
        central?.connect(p)
    }

    private func handleIMU(_ data: Data, at t: UInt64) {
        guard data.count >= 8 else { return }
        let seq = UInt16(data[data.startIndex]) | UInt16(data[data.startIndex + 1]) << 8
        let flags = data[data.startIndex + 7]
        lock.lock()
        if let last = lastSeq {
            let gap = Int(seq &- last) - 1
            if gap > 0 && gap < 1000 { snap.lostPackets += gap }
        }
        lastSeq = seq
        snap.imuPackets += 1
        snap.gyro4000 = flags & (1 << 3) != 0
        if windowStartNs == 0 { windowStartNs = t }
        windowCount += 1
        if t - windowStartNs >= 1_000_000_000 {
            snap.packetsPerSecond = Double(windowCount) / (Double(t - windowStartNs) / 1e9)
            windowStartNs = t
            windowCount = 0
        }
        lock.unlock()
    }
}

extension RacketLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: setState("idle"); scanIfReady()
        case .unauthorized: setState("Bluetooth permission needed")
        default: setState("Bluetooth off")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        lock.lock()
        lastSeq = nil
        windowStartNs = 0
        windowCount = 0
        lock.unlock()
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        setState("idle")
        scanIfReady()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        setState("idle")
        scanIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics(
            [Self.imuUUID, Self.statusUUID, Self.controlUUID, Self.shotUUID, Self.tapUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.imuUUID, Self.shotUUID, Self.tapUUID:
                peripheral.setNotifyValue(true, for: c)
            case Self.statusUUID:
                peripheral.setNotifyValue(true, for: c)
                peripheral.readValue(for: c)
            case Self.controlUUID:
                // Start the 1 kHz stream and ask for the wide gyro range; the range is also flagged in every
                // IMU packet, so the offline converter does not have to trust this setting.
                peripheral.writeValue(Data([0x01]), for: c, type: .withResponse)
                peripheral.writeValue(Data([0x11, 1]), for: c, type: .withResponse)
            default: break
            }
        }
        setState("connected")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Stamp first: everything after this is bookkeeping and would add to the apparent latency.
        let t = CaptureClock.nowNs
        guard let data = characteristic.value else { return }
        let kind: SessionLogger.RacketKind
        switch characteristic.uuid {
        case Self.imuUUID: kind = .imu; handleIMU(data, at: t)
        case Self.statusUUID:
            kind = .status
            lock.lock()
            lastStatus = data
            if data.count >= 2 { snap.batteryMV = Int(data[data.startIndex]) | Int(data[data.startIndex + 1]) << 8 }
            if data.count >= 8 { snap.racketDropped = Int(data[data.startIndex + 6]) | Int(data[data.startIndex + 7]) << 8 }
            lock.unlock()
        case Self.shotUUID: kind = .shot
        case Self.tapUUID: kind = .tap
        default: return
        }
        onRecord?(t, kind, data)
    }
}
