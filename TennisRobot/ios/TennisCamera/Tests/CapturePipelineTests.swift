import CoreVideo
import Darwin
import XCTest
@testable import TennisCamera

/// End-to-end coverage of the path the phone actually runs: a 4:2:0
/// `CVPixelBuffer` in, a validated 40-byte packet out over a real TCP socket.
///
/// This is the test that pins down the assumptions a device would otherwise be
/// needed to check: plane order, chroma subsampling layout, row padding and the
/// wire format.
final class CapturePipelineTests: XCTestCase {
    private let port: UInt16 = 5101

    func testSyntheticFrameReachesTheSocketAsAnObservation() throws {
        let server = ObservationServer()
        let processor = FrameProcessor(server: server)

        let connected = expectation(description: "client accepted")
        connected.assertForOverFulfill = false
        server.onStateChange = { isConnected, _ in
            if isConnected { connected.fulfill() }
        }
        server.start(port: port)

        var socketFD: Int32 = -1
        let clientQueue = DispatchQueue(label: "test.client")
        clientQueue.async {
            socketFD = Self.connectWithRetry(port: self.port, attempts: 50)
        }

        wait(for: [connected], timeout: 10)
        // The connect may land just before the accept callback is delivered.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertGreaterThanOrEqual(socketFD, 0, "test client failed to connect")
        guard socketFD >= 0 else { return }
        defer { close(socketFD) }
        Self.setReceiveTimeout(socketFD, seconds: 5)

        let frame = SyntheticFrame(
            width: 1920,
            height: 1080,
            background: (40, 60, 90),
            patches: [.init(cx: 900, cy: 520, radius: 40, r: 220, g: 235, b: 40)]
        )
        let pixelBuffer = try XCTUnwrap(Self.makePixelBuffer(from: frame))
        processor.process(pixelBuffer: pixelBuffer, tCapture: 987_654_321)

        let raw = try XCTUnwrap(Self.readExactly(socketFD, count: 40), "no packet arrived")
        let packet = try XCTUnwrap(ObservationPacket(decoding: raw))
        XCTAssertEqual(packet.kind, .observation)
        XCTAssertEqual(packet.tCaptureNs, 987_654_321, "capture timestamp is passed through untouched")
        XCTAssertEqual(packet.width, 1920)
        XCTAssertEqual(packet.height, 1080)
        XCTAssertEqual(Double(packet.u), 900, accuracy: 1.0)
        XCTAssertEqual(Double(packet.v), 520, accuracy: 1.0)
        XCTAssertEqual(Double(packet.radius), 40, accuracy: 1.0)
        XCTAssertGreaterThan(packet.confidence, 0.9)
        XCTAssertEqual(packet.sequence, 0, "first packet of the session")

        // Status packets share the layout and follow in order.
        processor.sendStatusPacket(tCaptureNs: 987_654_321)
        let statusRaw = try XCTUnwrap(Self.readExactly(socketFD, count: 40), "no status packet")
        let status = try XCTUnwrap(ObservationPacket(decoding: statusRaw))
        XCTAssertEqual(status.kind, .status)
        XCTAssertEqual(status.width, 1920)
        XCTAssertEqual(status.height, 1080)
        XCTAssertEqual(status.tCaptureNs, 987_654_321)
        XCTAssertEqual(
            Int(status.confidence),
            ObservationPacket.thermalLevel(ProcessInfo.processInfo.thermalState),
            "thermal state is encoded as the wire value"
        )
        XCTAssertEqual(status.radius, 0, "dropped frames")
        XCTAssertEqual(status.sequence, 1, "the counter covers every packet")

        server.stop()
    }

    /// The status packet is driven by the capture clock, not the main runloop,
    /// so it lands once per second of capture time however busy the UI is.
    func testStatusPacketFiresOncePerSecondOfCaptureTime() throws {
        // A different port from the test above: NWListener cancels asynchronously,
        // so reusing the same port immediately races the previous listener's
        // teardown and the bind silently fails.
        let port: UInt16 = self.port + 1
        let server = ObservationServer()
        let processor = FrameProcessor(server: server)

        let connected = expectation(description: "client accepted")
        connected.assertForOverFulfill = false
        server.onStateChange = { isConnected, _ in
            if isConnected { connected.fulfill() }
        }
        server.start(port: port)

        var socketFD: Int32 = -1
        let clientQueue = DispatchQueue(label: "test.status.client")
        clientQueue.async {
            socketFD = Self.connectWithRetry(port: port, attempts: 50)
        }

        wait(for: [connected], timeout: 10)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertGreaterThanOrEqual(socketFD, 0, "test client failed to connect")
        guard socketFD >= 0 else { return }
        defer { close(socketFD) }
        Self.setReceiveTimeout(socketFD, seconds: 2)

        // A blank frame sends no observations, so the only traffic is status.
        let frame = SyntheticFrame(width: 640, height: 480, background: (128, 128, 128))
        let pixelBuffer = try XCTUnwrap(Self.makePixelBuffer(from: frame))
        let ns: UInt64 = 1_000_000_000
        processor.process(pixelBuffer: pixelBuffer, tCapture: 10 * ns)
        processor.process(pixelBuffer: pixelBuffer, tCapture: 10 * ns + ns / 2)
        XCTAssertNil(
            Self.readExactly(socketFD, count: 40),
            "no status before one second of capture time has elapsed"
        )

        processor.process(pixelBuffer: pixelBuffer, tCapture: 10 * ns + ns + 41_666_666)
        let raw = try XCTUnwrap(Self.readExactly(socketFD, count: 40), "status packet missing")
        let status = try XCTUnwrap(ObservationPacket(decoding: raw))
        XCTAssertEqual(status.kind, .status)
        XCTAssertEqual(status.tCaptureNs, 10 * ns + ns + 41_666_666, "stamped with the capture time")
        Self.setReceiveTimeout(socketFD, seconds: 1)
        XCTAssertNil(Self.readExactly(socketFD, count: 40), "only one status per second")

        server.stop()
    }

    func testBlankFrameSendsNothingButStillCountsFrames() throws {
        let server = ObservationServer()
        let processor = FrameProcessor(server: server)

        let frame = SyntheticFrame(width: 640, height: 480, background: (128, 128, 128))
        let pixelBuffer = try XCTUnwrap(Self.makePixelBuffer(from: frame))
        processor.process(pixelBuffer: pixelBuffer, tCapture: 1)

        let snapshot = processor.stats.snapshot()
        XCTAssertEqual(snapshot.frames, 1)
        XCTAssertEqual(snapshot.detections, 0)
        XCTAssertEqual(snapshot.packets, 0)
    }

    func testDetectorCanBeSwitchedOff() throws {
        let server = ObservationServer()
        let processor = FrameProcessor(server: server)
        processor.updateSettings { $0.detectorEnabled = false }

        let frame = SyntheticFrame(
            width: 640,
            height: 480,
            background: (40, 60, 90),
            patches: [.init(cx: 320, cy: 240, radius: 20, r: 220, g: 235, b: 40)]
        )
        let pixelBuffer = try XCTUnwrap(Self.makePixelBuffer(from: frame))
        processor.process(pixelBuffer: pixelBuffer, tCapture: 1)

        let snapshot = processor.stats.snapshot()
        XCTAssertEqual(snapshot.frames, 1, "frames are still counted for the capture rate")
        XCTAssertEqual(snapshot.detections, 0)
        XCTAssertEqual(snapshot.detectorMedianMs, 0)
    }

    // MARK: - Helpers

    /// Copy the synthetic planes into a real `CVPixelBuffer`, row by row, so the
    /// detector sees the same row padding a capture device produces.
    private static func makePixelBuffer(from frame: SyntheticFrame) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            frame.width,
            frame.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        if let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            frame.luma.withUnsafeBytes { source in
                for y in 0..<frame.height {
                    memcpy(
                        lumaBase.advanced(by: y * stride),
                        source.baseAddress!.advanced(by: y * frame.width),
                        frame.width
                    )
                }
            }
        }

        if let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let rowBytes = frame.width
            frame.chroma.withUnsafeBytes { source in
                for y in 0..<(frame.height / 2) {
                    memcpy(
                        chromaBase.advanced(by: y * stride),
                        source.baseAddress!.advanced(by: y * rowBytes),
                        rowBytes
                    )
                }
            }
        }

        return pixelBuffer
    }

    private static func connectWithRetry(port: UInt16, attempts: Int) -> Int32 {
        for _ in 0..<attempts {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { return -1 }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")

            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 { return fd }
            close(fd)
            Thread.sleep(forTimeInterval: 0.1)
        }
        return -1
    }

    private static func setReceiveTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func readExactly(_ fd: Int32, count: Int) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: count)
        while data.count < count {
            let wanted = count - data.count
            let received = chunk.withUnsafeMutableBytes { buffer in
                Darwin.recv(fd, buffer.baseAddress, wanted, 0)
            }
            if received <= 0 { return nil }
            data.append(contentsOf: chunk[0..<received])
        }
        return data
    }
}
