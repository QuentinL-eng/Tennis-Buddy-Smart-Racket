import Foundation
import simd

/// One accepted detection with its capture time, in the form the tracker wants.
struct FlightSample: Equatable {
    let tNs: UInt64
    let u: Double
    let v: Double
    let radius: Double
    let confidence: Double
}

struct FlightState: Equatable {
    var position: SIMD3<Double>
    var velocity: SIMD3<Double>

    var speed: Double { simd_length(velocity) }
}

/// A fitted flight, and the crossing of the configured plane when the ball is
/// still heading towards it.
struct FlightPrediction: Equatable {
    let tNs: UInt64
    let state: FlightState
    let rmsPx: Double
    let radiusBiasPx: Double
    let observations: Int
    let intercept: SIMD3<Double>?
    let interceptTimeS: Double?
    let planeDistanceM: Double
}

/// Fits a gravity-plus-drag trajectory to the last window of detections and
/// predicts where it crosses a plane in front of the camera.
///
/// The estimator here mirrors `src/tennisrobot/estimator.py`, with the frame
/// changed from world to camera: depth comes only from apparent radius, and the
/// residuals are pixel centre and radius so the fit cannot trade one for the
/// other. Spin and wind stay at zero, because one camera cannot observe them.
///
/// The plane is at `z = planeDistanceM` in camera coordinates — perpendicular to
/// the optical axis. That is all a phone can know on its own: a strike plane
/// expressed in court coordinates needs the camera pose, which lives on the PC.
final class FlightTracker {
    struct Config: Equatable {
        var minObservations = 10
        var maxObservations = 60
        /// 0.18 s, about 43 samples at 240 fps. A shorter baseline cannot pin
        /// down velocity: at 0.05 s with 0.5 px of centre noise this model
        /// predicted a crossing metres from the truth while still passing the
        /// speed gate, which is the failure mode worth refusing outright.
        var minSpanS = 0.18
        /// Real flights fit at 0.7-0.9 px. A ball that is not flying — held, or
        /// resting — cannot follow a ballistic path at all and lands near 6 px,
        /// so this gate is what separates "tracking" from "a yellow blob on a
        /// string" rather than a loose sanity bound.
        var maxCenterRmsPx = 3.0
        var minSpeedMps = 3.0
        var maxSpeedMps = 45.0
        var minDepthM = 0.3
        var maxDepthM = 10.0
        /// Plane perpendicular to the optical axis, in front of the camera.
        var planeDistanceM = 1.0
        /// Refit every N samples; at 240 fps that is 60 Hz.
        var refitEvery = 4
        var maxIterations = 6
        var centerSigmaPx = 0.7
        var radiusSigmaPx = 1.0
        /// Longer than any plausible flight from detection to the plane.
        var predictionHorizonS = 2.0
        /// A gap this long ends the current track and starts a new one.
        var maxGapS = 0.05
        /// How far a candidate may be from the previous accepted detection and
        /// still be the same ball. A 12 m/s ball at 1.5 m moves about 25 px per
        /// frame, so this is loose enough for a fast ball and tight enough to
        /// reject an unrelated yellow blob elsewhere in the frame.
        var maxAssociationPx = 80.0
        /// The same ball cannot double or halve in projected size in one frame.
        var minRadiusRatio = 0.5
        var maxRadiusRatio = 2.0
    }

    private(set) var config: Config
    private(set) var fitCount = 0

    private var samples: [FlightSample] = []
    /// Last detection this track accepted, for candidate association.
    private var lastSample: FlightSample?
    /// Every candidate of the previous frame, used to prefer a moving blob when a
    /// track starts. A bright static object otherwise wins on confidence and the
    /// real ball is never followed at all.
    private var previousCandidates: [FlightSample] = []
    /// Why the last fit was refused. Silence on a device is the hardest thing to
    /// debug, so the reason is kept and logged at a readable rate.
    private(set) var lastRejection: String?
    private var lastLogNs: UInt64 = 0
    private var sinceLastFit = 0
    private var lastState: FlightState?
    private var lastStateNs: UInt64 = 0
    private var rejectedFits = 0

    init(config: Config = Config()) {
        self.config = config
    }

    var sampleCount: Int { samples.count }
    var rejectedFitCount: Int { rejectedFits }

    func update(config: Config) {
        self.config = config
    }

    func reset() {
        samples.removeAll(keepingCapacity: true)
        lastSample = nil
        previousCandidates = []
        lastRejection = nil
        sinceLastFit = 0
        lastState = nil
        lastStateNs = 0
        fitCount = 0
        rejectedFits = 0
    }

    /// Feed every candidate of one frame. The tracker picks the candidate that
    /// continues the current track, because "highest confidence" is not the same
    /// as "the ball": a bright decoy elsewhere in the frame can win that contest
    /// frame by frame and tear the track apart.
    func add(_ candidates: [FlightSample], camera: CameraModel, model: FlightModel) -> FlightPrediction? {
        defer { previousCandidates = candidates }
        guard let chosen = associate(candidates) else { return nil }
        return add(chosen, camera: camera, model: model)
    }

    /// Nearest candidate to the last accepted detection, within the gates. Nil
    /// when nothing matches, which lets the gap rule end the track instead of
    /// gluing it to a different blob.
    func associate(_ candidates: [FlightSample]) -> FlightSample? {
        guard !candidates.isEmpty else { return nil }
        guard let last = lastSample else {
            // No track yet. Start only on a candidate that moved between the last
            // two frames: a ball does, a bright static object does not. Waiting a
            // frame costs 4 ms and stops the brightest blob in the scene from
            // owning the track from the start.
            guard !previousCandidates.isEmpty else { return nil }
            return Self.mostRecentlyMoving(candidates, than: previousCandidates)
        }
        var best: FlightSample?
        var bestDistance = Double.infinity
        for candidate in candidates {
            let dx = candidate.u - last.u
            let dy = candidate.v - last.v
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance <= config.maxAssociationPx else { continue }
            let ratio = candidate.radius / max(last.radius, 0.25)
            guard ratio >= config.minRadiusRatio, ratio <= config.maxRadiusRatio else { continue }
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }

    /// The candidate that moved a plausible amount since the previous frame,
    /// taking the smallest such movement. Static blobs sit within a pixel of
    /// themselves; a ball at 240 fps does not. Among movers, the closest
    /// continuation is the least likely to be a random flicker.
    static func mostRecentlyMoving(
        _ candidates: [FlightSample],
        than previous: [FlightSample],
        minimumPx: Double = 1.5,
        maximumPx: Double = 80
    ) -> FlightSample? {
        guard !previous.isEmpty else { return nil }
        var best: FlightSample?
        var bestMove = maximumPx
        for candidate in candidates {
            var nearest = Double.infinity
            for prior in previous {
                let dx = prior.u - candidate.u
                let dy = prior.v - candidate.v
                nearest = min(nearest, (dx * dx + dy * dy).squareRoot())
            }
            guard nearest >= minimumPx, nearest < bestMove else { continue }
            bestMove = nearest
            best = candidate
        }
        return best
    }

    /// Feed one detection that has already been chosen. Returns a prediction when
    /// a fit was due and passed the gates.
    func add(_ sample: FlightSample, camera: CameraModel, model: FlightModel) -> FlightPrediction? {
        if let previous = samples.last {
            let gap = Double(sample.tNs &- previous.tNs) / 1e9
            if sample.tNs >= previous.tNs && gap > config.maxGapS {
                reset()
            }
        }

        samples.append(sample)
        lastSample = sample
        if samples.count > config.maxObservations {
            samples.removeFirst(samples.count - config.maxObservations)
        }

        sinceLastFit += 1
        guard samples.count >= config.minObservations,
              sinceLastFit >= max(1, config.refitEvery)
        else { return nil }

        guard let span = spanSeconds(), span >= config.minSpanS else { return nil }
        sinceLastFit = 0
        guard let fitted = fit(camera: camera, model: model) else {
            rejectedFits += 1
            lastState = nil
            note("fit failed", at: sample.tNs)
            return nil
        }

        let speed = fitted.state.speed
        let depth = fitted.state.position.z
        if fitted.rmsPx > config.maxCenterRmsPx {
            rejectedFits += 1
            lastState = nil
            note(String(format: "rms %.1f px > %.1f (%d obs, span %.2f s)",
                        fitted.rmsPx, config.maxCenterRmsPx, samples.count, span), at: sample.tNs)
            return nil
        }
        if speed < config.minSpeedMps || speed > config.maxSpeedMps {
            rejectedFits += 1
            lastState = nil
            note(String(format: "speed %.1f m/s outside %.1f..%.1f",
                        speed, config.minSpeedMps, config.maxSpeedMps), at: sample.tNs)
            return nil
        }
        guard depth >= config.minDepthM, depth <= config.maxDepthM else {
            rejectedFits += 1
            lastState = nil
            note(String(format: "depth %.2f m outside %.1f..%.1f",
                        depth, config.minDepthM, config.maxDepthM), at: sample.tNs)
            return nil
        }

        fitCount += 1
        lastState = fitted.state
        lastStateNs = samples[samples.count - 1].tNs

        let crossing = intercept(from: fitted.state, model: model)
        lastRejection = nil
        note(String(format: "fit ok rms %.1f px speed %.1f m/s depth %.2f m%s",
                    fitted.rmsPx, speed, depth, crossing == nil ? " (no plane crossing)" : ""),
             at: sample.tNs)
        return FlightPrediction(
            tNs: lastStateNs,
            state: fitted.state,
            rmsPx: fitted.rmsPx,
            radiusBiasPx: fitted.radiusBiasPx,
            observations: samples.count,
            intercept: crossing?.point,
            interceptTimeS: crossing?.timeS,
            planeDistanceM: config.planeDistanceM
        )
    }

    /// At most two lines a second, so the console stays readable.
    private func note(_ message: String, at tNs: UInt64) {
        lastRejection = message
        guard tNs &- lastLogNs > 500_000_000 else { return }
        lastLogNs = tNs
        NSLog("TennisCamera tracker: %@", message)
    }

    // MARK: - Fit

    private struct Fitted {
        let state: FlightState
        let rmsPx: Double
        let radiusBiasPx: Double
    }

    private func spanSeconds() -> Double? {
        guard let first = samples.first, let last = samples.last, last.tNs > first.tNs else { return nil }
        return Double(last.tNs - first.tNs) / 1e9
    }

    private func fit(camera: CameraModel, model: FlightModel) -> Fitted? {
        guard let newest = samples.last else { return nil }
        let t0 = Double(newest.tNs) / 1e9

        var times = [Double](repeating: 0, count: samples.count)
        var us = [Double](repeating: 0, count: samples.count)
        var vs = [Double](repeating: 0, count: samples.count)
        var rs = [Double](repeating: 0, count: samples.count)
        for (index, sample) in samples.enumerated() {
            times[index] = Double(sample.tNs) / 1e9 - t0
            us[index] = sample.u
            vs[index] = sample.v
            rs[index] = sample.radius
        }

        // Warm start from the previous fit when it is close enough in time,
        // otherwise from the radius-derived linear fit.
        var initial: FlightState
        if let previous = lastState, lastStateNs > 0, lastStateNs <= newest.tNs,
           Double(newest.tNs - lastStateNs) / 1e9 <= config.maxGapS {
            let dt = t0 - Double(lastStateNs) / 1e9
            let moved = model.step(position: previous.position, velocity: previous.velocity, dt: dt)
            initial = FlightState(position: moved.position, velocity: moved.velocity)
        } else if let guess = linearGuess(camera: camera, model: model) {
            initial = guess
        } else {
            return nil
        }

        var params = [
            initial.position.x, initial.position.y, initial.position.z,
            initial.velocity.x, initial.velocity.y, initial.velocity.z,
        ]
        guard var base = residual(
            params: params, times: times, us: us, vs: vs, rs: rs, camera: camera, model: model
        ) else { return nil }

        var cost = Self.dot(base, base)
        let steps: [Double] = [1e-3, 1e-3, 1e-3, 1e-2, 1e-2, 1e-2]
        var damping = 1e-3

        for _ in 1...config.maxIterations {
            var jacobian = [[Double]](repeating: [Double](repeating: 0, count: 6), count: base.count)
            for column in 0..<6 {
                var trial = params
                trial[column] += steps[column]
                guard let trialResidual = residual(
                    params: trial, times: times, us: us, vs: vs, rs: rs, camera: camera, model: model
                ), trialResidual.count == base.count else { continue }
                for row in 0..<base.count {
                    jacobian[row][column] = (trialResidual[row] - base[row]) / steps[column]
                }
            }

            var normal = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
            var gradient = [Double](repeating: 0, count: 6)
            for row in 0..<base.count {
                for a in 0..<6 {
                    gradient[a] += jacobian[row][a] * base[row]
                    for b in a..<6 {
                        normal[a][b] += jacobian[row][a] * jacobian[row][b]
                    }
                }
            }
            for a in 0..<6 {
                for b in 0..<a {
                    normal[a][b] = normal[b][a]
                }
            }
            let diagonal = (0..<6).map { max(normal[$0][$0], 1e-12) }

            var accepted = false
            var deltaNorm = Double.infinity
            for _ in 0..<8 {
                var damped = normal
                for a in 0..<6 {
                    damped[a][a] += damping * diagonal[a]
                }
                guard var delta = Self.solve(damped, gradient.map { -$0 }) else {
                    damping *= 10.0
                    continue
                }
                for a in 0..<3 {
                    delta[a] = min(max(delta[a], -0.75), 0.75)
                }
                for a in 3..<6 {
                    delta[a] = min(max(delta[a], -10.0), 10.0)
                }
                var trial = params
                for a in 0..<6 {
                    trial[a] += delta[a]
                }
                guard let trialResidual = residual(
                    params: trial, times: times, us: us, vs: vs, rs: rs, camera: camera, model: model
                ), trialResidual.count == base.count else {
                    damping *= 10.0
                    continue
                }
                let trialCost = Self.dot(trialResidual, trialResidual)
                if trialCost < cost {
                    let improvement = cost - trialCost
                    params = trial
                    base = trialResidual
                    cost = trialCost
                    damping = max(1e-9, damping / 3.0)
                    deltaNorm = delta.reduce(0) { $0 + $1 * $1 }.squareRoot()
                    accepted = true
                    if improvement <= 1e-6 * max(cost, 1e-12) {
                        deltaNorm = 0
                    }
                    break
                }
                damping *= 10.0
            }

            if !accepted || deltaNorm < 1e-6 {
                break
            }
        }

        // Residuals are scaled; convert back to pixels for the gates and report.
        var sumSquared = 0.0
        var radiusSum = 0.0
        for row in 0..<times.count {
            let du = base[row * 3] * config.centerSigmaPx
            let dv = base[row * 3 + 1] * config.centerSigmaPx
            let dr = base[row * 3 + 2] * config.radiusSigmaPx
            sumSquared += du * du + dv * dv
            radiusSum += dr
        }
        let rms = (sumSquared / Double(times.count)).squareRoot()
        guard rms.isFinite else { return nil }

        let state = FlightState(
            position: SIMD3<Double>(params[0], params[1], params[2]),
            velocity: SIMD3<Double>(params[3], params[4], params[5])
        )
        return Fitted(state: state, rmsPx: rms, radiusBiasPx: radiusSum / Double(times.count))
    }

    /// Residuals at every sample: `(du, dv, dr)` scaled by their sigmas, newest
    /// sample first. The state is carried backwards from the newest sample, so
    /// the fitted parameters are the state at that sample's time.
    private func residual(
        params: [Double],
        times: [Double],
        us: [Double],
        vs: [Double],
        rs: [Double],
        camera: CameraModel,
        model: FlightModel
    ) -> [Double]? {
        guard params.count == 6, !times.isEmpty else { return nil }
        var position = SIMD3<Double>(params[0], params[1], params[2])
        var velocity = SIMD3<Double>(params[3], params[4], params[5])
        var out = [Double](repeating: 0, count: times.count * 3)

        func evaluate(_ index: Int) -> Bool {
            guard let projected = camera.project(position, ballRadiusM: model.ball.radiusM) else {
                return false
            }
            out[index * 3] = (projected.u - us[index]) / config.centerSigmaPx
            out[index * 3 + 1] = (projected.v - vs[index]) / config.centerSigmaPx
            out[index * 3 + 2] = (projected.r - rs[index]) / config.radiusSigmaPx
            return true
        }

        guard evaluate(times.count - 1) else { return nil }
        if times.count > 1 {
            for index in stride(from: times.count - 2, through: 0, by: -1) {
                let dt = times[index] - times[index + 1]
                let stepped = model.step(position: position, velocity: velocity, dt: dt)
                position = stepped.position
                velocity = stepped.velocity
                guard evaluate(index) else { return nil }
            }
        }
        return out
    }

    /// Linear least squares on the per-sample 3D points, used to start the solve.
    private func linearGuess(camera: CameraModel, model: FlightModel) -> FlightState? {
        guard let newest = samples.last else { return nil }
        let t0 = Double(newest.tNs) / 1e9
        var times: [Double] = []
        var points: [SIMD3<Double>] = []
        for sample in samples {
            guard let depth = camera.depth(radiusPx: sample.radius, ballRadiusM: model.ball.radiusM),
                  depth >= config.minDepthM, depth <= config.maxDepthM
            else { continue }
            times.append(Double(sample.tNs) / 1e9 - t0)
            points.append(camera.backProject(u: sample.u, v: sample.v, depthM: depth))
        }
        guard times.count >= 3 else { return nil }

        let count = Double(times.count)
        let sumT = times.reduce(0, +)
        let sumT2 = times.reduce(0) { $0 + $1 * $1 }
        let denominator = count * sumT2 - sumT * sumT
        guard abs(denominator) > 1e-12 else { return nil }

        var position = SIMD3<Double>.zero
        var velocity = SIMD3<Double>.zero
        for axis in 0..<3 {
            let sumP = points.reduce(0.0) { $0 + $1[axis] }
            let sumPT = zip(points, times).reduce(0.0) { $0 + $1.0[axis] * $1.1 }
            position[axis] = (sumT2 * sumP - sumT * sumPT) / denominator
            velocity[axis] = (count * sumPT - sumT * sumP) / denominator
        }
        return FlightState(position: position, velocity: velocity)
    }

    // MARK: - Prediction

    /// Integrate forward until the ball crosses the plane in front of the camera.
    private func intercept(
        from state: FlightState,
        model: FlightModel
    ) -> (point: SIMD3<Double>, timeS: Double)? {
        let plane = config.planeDistanceM
        // Only a ball coming towards the camera plane has a crossing ahead.
        guard state.position.z > plane, state.velocity.z < -0.5 else { return nil }

        var position = state.position
        var velocity = state.velocity
        var time = 0.0
        let dt = 0.001

        while time < config.predictionHorizonS {
            let next = model.step(position: position, velocity: velocity, dt: dt)
            if next.position.z <= plane {
                let travelled = position.z - next.position.z
                let fraction = travelled > 1e-9 ? (position.z - plane) / travelled : 1.0
                let point = position + fraction * (next.position - position)
                return (SIMD3<Double>(point.x, point.y, plane), time + fraction * dt)
            }
            position = next.position
            velocity = next.velocity
            time += dt
            if position.z > 50 {
                return nil
            }
        }
        return nil
    }

    // MARK: - Small linear algebra

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var total = 0.0
        for index in 0..<min(a.count, b.count) {
            total += a[index] * b[index]
        }
        return total
    }

    /// Gaussian elimination with partial pivoting.
    private static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        guard n > 0, matrix.count == n, matrix.allSatisfy({ $0.count == n }) else { return nil }
        var a = matrix
        var b = rhs

        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<n where abs(a[row][column]) > abs(a[pivot][column]) {
                pivot = row
            }
            guard abs(a[pivot][column]) > 1e-14 else { return nil }
            if pivot != column {
                a.swapAt(pivot, column)
                b.swapAt(pivot, column)
            }
            if column + 1 < n {
                for row in (column + 1)..<n {
                    let factor = a[row][column] / a[column][column]
                    if factor == 0 { continue }
                    for c in column..<n {
                        a[row][c] -= factor * a[column][c]
                    }
                    b[row] -= factor * b[column]
                }
            }
        }

        var solution = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            if row + 1 < n {
                for c in (row + 1)..<n {
                    sum -= a[row][c] * solution[c]
                }
            }
            solution[row] = sum / a[row][row]
        }
        return solution
    }
}
