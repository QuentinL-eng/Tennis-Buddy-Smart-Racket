import AVFoundation
import CoreMedia
import Foundation

extension CaptureClock {
    /// Now, on the same clock as `CMSampleBuffer` presentation timestamps, so a racket packet's arrival time
    /// and a camera frame's capture time can be subtracted directly.
    static var nowNs: UInt64 {
        nanoseconds(from: CMClockGetTime(CMClockGetHostTimeClock()))
    }
}

/// Writes one recording session to `Documents/sessions/<stamp>/` for offline analysis
/// (`tools/phone_session.py` in the repo root reads it). Every file is little-endian and every time is a
/// nanosecond count on the phone's host clock, the same clock as `t_capture_ns` in the observation packets.
///
///     frames.bin      u64 t_ns                                  one per delivered camera frame
///     detections.bin  u64 t_ns, f32 u, v, radius, confidence    one per ball candidate (24 bytes)
///     racket.bin      u64 t_ns, u8 kind, u16 length, payload    raw BLE notifications, t_ns = arrival
///     events.csv      t_ns,label                                 sync marks pressed by the user
///     video.mov       the 240 fps frames (optional)
///     video_frames.bin  u64 t_ns of each frame that reached video.mov, in file order (skipped frames are absent)
///     meta.json       format, device, counters
///
/// All file work runs on a utility queue; the capture queue only appends small values to a buffer.
final class SessionLogger: @unchecked Sendable {
    enum RacketKind: UInt8 {
        case imu = 1, status = 2, shot = 3, tap = 4
    }

    private final class LogFile {
        let handle: FileHandle
        var buffer = Data()
        init?(url: URL) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: url) else { return nil }
            self.handle = handle
        }
        func flush() {
            guard !buffer.isEmpty else { return }
            try? handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        func flushIfLarge() {
            if buffer.count >= 64 * 1024 { flush() }
        }
        func close() {
            flush()
            try? handle.close()
        }
    }

    let directory: URL
    private let queue = DispatchQueue(label: "tennisrobot.session.log", qos: .utility)
    private let frames: LogFile?
    private let detections: LogFile?
    private let racket: LogFile?
    private let events: LogFile?
    private let videoIndex: LogFile?
    private var meta: [String: Any]
    private var frameCount = 0
    private var detectionCount = 0
    private var racketCount = 0
    private var firstFrameNs: UInt64 = 0

    // Video writer state, touched from the capture queue and `finish`.
    private let videoLock = NSLock()
    private let wantsVideo: Bool
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoFailed: String?
    private var videoClosed = false
    private var videoFrames = 0
    private var videoSkipped = 0

    /// - Parameters:
    ///   - info: written to meta.json as-is (format, device, thermal state, ...).
    init?(info: [String: Any], recordVideo: Bool) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = documents.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              let frames = LogFile(url: dir.appendingPathComponent("frames.bin")),
              let detections = LogFile(url: dir.appendingPathComponent("detections.bin")),
              let racket = LogFile(url: dir.appendingPathComponent("racket.bin")),
              let events = LogFile(url: dir.appendingPathComponent("events.csv")),
              let videoIndex = LogFile(url: dir.appendingPathComponent("video_frames.bin"))
        else { return nil }
        directory = dir
        self.frames = frames
        self.detections = detections
        self.racket = racket
        self.events = events
        self.videoIndex = videoIndex
        events.buffer.append(Data("t_ns,label\n".utf8))
        wantsVideo = recordVideo

        var meta = info
        meta["format_version"] = 1
        meta["started_wall"] = ISO8601DateFormatter().string(from: Date())
        meta["started_host_ns"] = CaptureClock.nowNs
        meta["clock"] = "CMClockGetHostTimeClock, nanoseconds"
        meta["video"] = recordVideo
        self.meta = meta
        writeMeta()
    }

    var name: String { directory.lastPathComponent }

    // MARK: Logging (any thread)

    func logFrame(_ tNs: UInt64) {
        queue.async {
            if self.frameCount == 0 { self.firstFrameNs = tNs }
            self.frameCount += 1
            self.frames?.buffer.appendLE(tNs)
            self.frames?.flushIfLarge()
        }
    }

    func logDetections(_ tNs: UInt64, _ list: [BallDetection]) {
        queue.async {
            for d in list {
                self.detectionCount += 1
                self.detections?.buffer.appendLE(tNs)
                self.detections?.buffer.appendLE(d.u.bitPattern)
                self.detections?.buffer.appendLE(d.v.bitPattern)
                self.detections?.buffer.appendLE(d.radius.bitPattern)
                self.detections?.buffer.appendLE(d.confidence.bitPattern)
            }
            self.detections?.flushIfLarge()
        }
    }

    func logRacket(tNs: UInt64, kind: RacketKind, payload: Data) {
        queue.async {
            self.racketCount += 1
            self.racket?.buffer.appendLE(tNs)
            self.racket?.buffer.append(kind.rawValue)
            self.racket?.buffer.appendLE(UInt16(truncatingIfNeeded: payload.count))
            self.racket?.buffer.append(payload)
            self.racket?.flushIfLarge()
        }
    }

    func mark(_ label: String) {
        let t = CaptureClock.nowNs
        let clean = label.replacingOccurrences(of: ",", with: ";")
        queue.async {
            self.events?.buffer.append(Data("\(t),\(clean)\n".utf8))
            self.events?.flush()
        }
    }

    // MARK: Video (capture queue)

    /// Appends the frame to video.mov. Does nothing when video is off. A frame the encoder cannot take right
    /// now is skipped and counted instead of blocking the capture queue.
    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard wantsVideo else { return }
        videoLock.lock()
        defer { videoLock.unlock() }
        if videoFailed != nil || videoClosed { return }
        if writer == nil {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            do {
                let w = try AVAssetWriter(url: directory.appendingPathComponent("video.mov"), fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: Int(dims.width),
                    AVVideoHeightKey: Int(dims.height),
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: 30_000_000,
                        AVVideoExpectedSourceFrameRateKey: 240,
                    ],
                ])
                input.expectsMediaDataInRealTime = true
                guard w.canAdd(input) else { videoFailed = "writer refused the video input"; return }
                w.add(input)
                guard w.startWriting() else {
                    videoFailed = w.error?.localizedDescription ?? "startWriting failed"
                    return
                }
                w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                writer = w
                videoInput = input
            } catch {
                videoFailed = error.localizedDescription
                return
            }
        }
        guard let input = videoInput, let active = writer else { return }
        if active.status == .failed {
            videoFailed = active.error?.localizedDescription ?? "writer failed"
            return
        }
        if input.isReadyForMoreMediaData, input.append(sampleBuffer) {
            videoFrames += 1
            let t = CaptureClock.nanoseconds(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            queue.async {
                self.videoIndex?.buffer.appendLE(t)
                self.videoIndex?.flushIfLarge()
            }
        } else {
            videoSkipped += 1
        }
    }

    // MARK: Finish

    /// Flushes everything, closes the video and rewrites meta.json with the counters.
    func finish(extra: [String: Any], completion: @escaping (String) -> Void) {
        // Closing under the lock means a frame already in flight on the capture queue cannot append afterwards.
        videoLock.lock()
        videoClosed = true
        let finishing = writer
        videoInput?.markAsFinished()
        videoLock.unlock()
        let closeFiles = { [self] (videoError: String?) in
            queue.async {
                self.frames?.close()
                self.detections?.close()
                self.racket?.close()
                self.events?.close()
                self.videoIndex?.close()
                var meta = self.meta
                extra.forEach { meta[$0.key] = $0.value }
                meta["stopped_host_ns"] = CaptureClock.nowNs
                meta["first_frame_ns"] = self.firstFrameNs
                meta["frames"] = self.frameCount
                meta["detections"] = self.detectionCount
                meta["racket_records"] = self.racketCount
                self.videoLock.lock()
                meta["video_frames"] = self.videoFrames
                meta["video_frames_skipped"] = self.videoSkipped
                let failure = videoError ?? self.videoFailed
                self.videoLock.unlock()
                if let failure { meta["video_error"] = failure }
                self.meta = meta
                self.writeMeta()
                var summary = "\(self.frameCount) frames, \(self.detectionCount) detections, \(self.racketCount) racket records"
                if self.wantsVideo { summary += ", video \(self.videoFrames) frames (\(self.videoSkipped) skipped)" }
                if let failure { summary += " — video error: \(failure)" }
                completion(summary)
            }
        }
        if let finishing, finishing.status == .writing {
            finishing.finishWriting { closeFiles(finishing.status == .failed ? finishing.error?.localizedDescription : nil) }
        } else {
            closeFiles(nil)
        }
    }

    private func writeMeta() {
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("meta.json"))
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
