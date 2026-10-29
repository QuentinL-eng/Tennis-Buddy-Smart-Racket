import Foundation
import simd

/// The samples around one hit, as the racket sends them in impact mode (firmware 1.5+).
public struct ImpactWindow: Sendable {
    public var seq: UInt16
    /// Index of the impact sample in `samples`.
    public var impactIndex: Int
    /// Sensor axes → world (z up) at `samples[0]`, from the racket's orientation filter.
    public var startOrientation: simd_quatf
    /// 1 kHz samples in sensor axes, as `RacketProtocol.convert` produces them.
    public var samples: [IMUSample]
    /// The racket's boot number in acked mode (firmware 1.6+), else nil.
    public var boot: UInt16?
    /// Captured while the link was busy or down, and sent late.
    public var backlog = false

    public init(seq: UInt16, impactIndex: Int, startOrientation: simd_quatf, samples: [IMUSample], boot: UInt16? = nil) {
        self.seq = seq
        self.impactIndex = impactIndex
        self.startOrientation = startOrientation
        self.samples = samples
        self.boot = boot
    }

    /// Names one window across reconnects and reboots (acked mode); seq alone restarts at every boot.
    public var key: WindowKey { WindowKey(boot: boot, seq: seq) }
}

public struct WindowKey: Hashable, Sendable {
    public var boot: UInt16?
    public var seq: UInt16
}

/// A source that finds hits itself and sends only the samples around each one: the racket in impact mode.
/// Callbacks arrive on an arbitrary queue.
public protocol ImpactSource: AnyObject {
    var onImpactWindow: ((ImpactWindow) -> Void)? { get set }
    var onPose: ((RacketProtocol.Pose) -> Void)? { get set }
}

/// A racket that computes each shot itself (firmware 1.6+): it needs the app's calibration and profile, and sends a
/// `ShotSummary` before each window.
public protocol ShotSummarySource: AnyObject {
    var onShotSummary: ((RacketProtocol.ShotSummary) -> Void)? { get set }
    /// `RacketProtocol.shotConfigPayload`; the source sends it now and again after every reconnect.
    func setShotConfig(_ payload: Data)
}

/// Collects hits' window chunks into `ImpactWindow`s. In plain impact mode one window arrives at a time and a new
/// one abandons an unfinished one. In acked mode (chunks carry a boot number) several can be in flight, chunks the
/// racket resends fill the gaps, and `missing` says what to ask for.
public struct ImpactWindowAssembler {
    private struct Partial {
        var chunks: [RacketProtocol.WindowChunk?]
        var updated: Double
    }
    private var partials: [WindowKey: Partial] = [:]
    /// Windows abandoned because a chunk never arrived.
    public private(set) var incomplete = 0

    public init() {}

    /// Returns the window once its last chunk is in. `time` turns racket micros into seconds; `now` (any clock)
    /// timestamps partial windows for `missing`.
    public mutating func add(_ chunk: RacketProtocol.WindowChunk, h3lisRange: UInt8, now: Double = 0,
                             time: (UInt32) -> Double) -> ImpactWindow? {
        guard chunk.total > 0, chunk.index < chunk.total else { return nil }
        let key = WindowKey(boot: chunk.boot, seq: chunk.seq)
        if chunk.boot == nil {
            // Plain impact mode: windows arrive one after another and are never resent.
            for (k, p) in partials where k != key {
                if p.chunks.contains(where: { $0 != nil }) { incomplete += 1 }
                partials[k] = nil
            }
        } else if partials[key] == nil, partials.count >= 8,
                  let stale = partials.min(by: { $0.value.updated < $1.value.updated })?.key {
            partials[stale] = nil
            incomplete += 1
        }
        var p = partials[key] ?? Partial(chunks: Array(repeating: nil, count: chunk.total), updated: now)
        if p.chunks.count != chunk.total { p.chunks = Array(repeating: nil, count: chunk.total) }
        p.chunks[chunk.index] = chunk
        p.updated = now
        guard p.chunks.allSatisfy({ $0 != nil }) else {
            partials[key] = p
            return nil
        }
        partials[key] = nil
        let parts = p.chunks.compactMap { $0 }
        let scale = RacketProtocol.mpuGyroLSBPerDps / 2   // window gyro is always at 8.2 LSB/dps
        var samples: [IMUSample] = []
        samples.reserveCapacity(parts.reduce(0) { $0 + $1.samples.count })
        for part in parts {
            let t0 = time(part.t0Micros)
            for (k, raw) in part.samples.enumerated() {
                samples.append(RacketProtocol.convert(raw, time: t0 + Double(k) * 0.001, h3lisRange: h3lisRange,
                                                      gyroLSBPerDps: scale))
            }
        }
        guard parts[0].impact < samples.count else { return nil }
        var window = ImpactWindow(seq: chunk.seq, impactIndex: parts[0].impact,
                                  startOrientation: parts[0].startOrientation, samples: samples, boot: chunk.boot)
        window.backlog = parts.contains { $0.flags & RacketProtocol.flagBacklog != 0 }
        return window
    }

    /// Acked-mode windows with chunks missing and nothing new for `quietFor` seconds, with the missing chunk
    /// indexes. Marks them as just asked about, so each gap is requested once per `quietFor`.
    public mutating func missing(now: Double, quietFor: Double) -> [(key: WindowKey, chunks: [Int])] {
        var out: [(key: WindowKey, chunks: [Int])] = []
        for (key, p) in partials where key.boot != nil && now - p.updated >= quietFor {
            out.append((key, p.chunks.indices.filter { p.chunks[$0] == nil }))
            partials[key]?.updated = now
        }
        return out.sorted { $0.key.seq < $1.key.seq }
    }
}
