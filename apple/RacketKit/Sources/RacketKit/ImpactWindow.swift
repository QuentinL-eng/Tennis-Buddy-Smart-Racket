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

    public init(seq: UInt16, impactIndex: Int, startOrientation: simd_quatf, samples: [IMUSample]) {
        self.seq = seq
        self.impactIndex = impactIndex
        self.startOrientation = startOrientation
        self.samples = samples
    }
}

/// A source that finds hits itself and sends only the samples around each one: the racket in impact mode.
/// Callbacks arrive on an arbitrary queue.
public protocol ImpactSource: AnyObject {
    var onImpactWindow: ((ImpactWindow) -> Void)? { get set }
    var onPose: ((RacketProtocol.Pose) -> Void)? { get set }
}

/// Collects a hit's window chunks, which arrive in order, into one `ImpactWindow`.
public struct ImpactWindowAssembler {
    private var seq: UInt16?
    private var chunks: [RacketProtocol.WindowChunk?] = []
    /// Windows abandoned because a chunk never arrived.
    public private(set) var incomplete = 0

    public init() {}

    /// Returns the window once its last chunk is in. `time` turns racket micros into seconds.
    public mutating func add(_ chunk: RacketProtocol.WindowChunk, h3lisRange: UInt8,
                             time: (UInt32) -> Double) -> ImpactWindow? {
        guard chunk.total > 0, chunk.index < chunk.total else { return nil }
        if chunk.seq != seq || chunks.count != chunk.total {
            if seq != nil, chunks.contains(where: { $0 != nil }) { incomplete += 1 }
            seq = chunk.seq
            chunks = Array(repeating: nil, count: chunk.total)
        }
        chunks[chunk.index] = chunk
        guard chunks.allSatisfy({ $0 != nil }) else { return nil }
        let parts = chunks.compactMap { $0 }
        seq = nil
        chunks = []
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
        return ImpactWindow(seq: chunk.seq, impactIndex: parts[0].impact, startOrientation: parts[0].startOrientation,
                            samples: samples)
    }
}
