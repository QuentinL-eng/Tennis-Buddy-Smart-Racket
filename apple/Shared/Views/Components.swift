import RacketKit
import SwiftUI

/// Top-down drawing of the string bed with impact dots or a heat map.
/// Coordinates: impact x (across, cm) → horizontal, impact y (toward tip, cm) → up.
struct StringBedView: View {
    var shots: [ShotMetrics]
    var heatMap = false
    var highlight: ShotMetrics?

    private let halfWidthCm = 12.4, halfLengthCm = 16.2

    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width / (2 * halfWidthCm + 3), size.height / (2 * halfLengthCm + 3))
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: center.x + x * scale, y: center.y - y * scale)
            }
            let head = CGRect(x: center.x - halfWidthCm * scale, y: center.y - halfLengthCm * scale,
                              width: 2 * halfWidthCm * scale, height: 2 * halfLengthCm * scale)
            let headPath = Path(ellipseIn: head)
            ctx.fill(headPath, with: .color(.primary.opacity(0.04)))

            // Strings (16 mains × 19 crosses).
            var strings = Path()
            for i in -7...8 {
                let x = center.x + (Double(i) - 0.5) * 1.5 * scale
                strings.move(to: CGPoint(x: x, y: head.minY)); strings.addLine(to: CGPoint(x: x, y: head.maxY))
            }
            for i in -9...9 {
                let y = center.y + Double(i) * 1.6 * scale
                strings.move(to: CGPoint(x: head.minX, y: y)); strings.addLine(to: CGPoint(x: head.maxX, y: y))
            }
            ctx.drawLayer { layer in
                layer.clip(to: headPath)
                layer.stroke(strings, with: .color(.primary.opacity(0.12)), lineWidth: 0.6)
            }
            ctx.stroke(headPath, with: .color(.primary.opacity(0.7)), lineWidth: max(3, scale * 0.9))

            // Sweet spot.
            let r = ShotMetrics.sweetSpotRadiusCm * scale
            let sweet = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(sweet, with: .color(.green.opacity(0.10)))
            ctx.stroke(sweet, with: .color(.green.opacity(0.6)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))

            if heatMap {
                ctx.drawLayer { layer in
                    layer.clip(to: headPath)
                    layer.addFilter(.blur(radius: scale * 1.6))
                    for s in shots {
                        let p = point(s.impactXcm, s.impactYcm)
                        let rr = 2.2 * scale
                        layer.fill(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: 2 * rr, height: 2 * rr)),
                                   with: .color(.orange.opacity(0.35)))
                    }
                }
            } else {
                for s in shots {
                    let p = point(s.impactXcm, s.impactYcm)
                    let rr = max(3, 0.75 * scale)
                    let isHighlight = s.id == highlight?.id
                    let dot = Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: 2 * rr, height: 2 * rr))
                    ctx.fill(dot, with: .color((s.isSweetSpot ? Color.green : Color.red).opacity(isHighlight ? 1 : 0.55)))
                    if isHighlight { ctx.stroke(dot, with: .color(.primary), lineWidth: 2) }
                }
            }
        }
        .aspectRatio(2 * halfWidthCm / (2 * halfLengthCm + 6), contentMode: .fit)
        .accessibilityLabel("String bed with \(shots.count) impacts")
    }
}

/// A labeled number tile.
struct StatTile: View {
    var label: String
    var value: String
    var unit: String = ""
    var symbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(label)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
    }
}

/// The card shown after every shot. The edge flashes green (sweet spot) or red (mishit),
/// a nod to the original project's green/red shot LEDs.
struct ShotCardView: View {
    var shot: ShotMetrics
    var flashID: UUID
    @State private var glow = 0.0
    @AppStorage(UnitSystem.storageKey) private var useMetric = false
    private var units: UnitSystem { UnitSystem(metric: useMetric) }

    var body: some View {
        let tint: Color = shot.isSweetSpot ? .green : .red
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(shot.type.label, systemImage: shot.type.symbol).font(.headline)
                Spacer()
                Text(shot.isSweetSpot ? "Sweet spot" : "Off center")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(tint.opacity(0.18), in: .capsule)
                    .foregroundStyle(tint)
            }
            if !shot.hasMotion {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(shot.isSweetSpot ? "Sweet spot" : "Off center")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text(shot.isSweetSpot ? "Clean contact" : "About \(units.lengthText(shot.impactDistanceCm)) from the sweet spot")
                            .font(.subheadline)
                        Label("Heard by the racket's mic · motion sensors offline", systemImage: "waveform.badge.mic")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    StringBedView(shots: [shot], highlight: shot).frame(width: 90)
                }
            } else {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(units.speedValue(shot.ballSpeedKmh))
                            .font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("\(units.speedUnit) ball speed (est.)").font(.caption).foregroundStyle(.secondary)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            metric("Swing", units.speedText(shot.swingSpeedKmh))
                            metric("Spin", "\(Int(shot.spinRPM.rounded())) rpm \(shot.spin.label.lowercased())")
                        }
                        GridRow {
                            metric("Face", angle(shot.faceAngleDeg, pos: "open", neg: "closed"))
                            metric("Path", angle(shot.swingPathDeg, pos: "up", neg: "down"))
                        }
                    }
                }
                Spacer(minLength: 0)
                StringBedView(shots: [shot], highlight: shot).frame(width: 90)
            }
            }
            if shot.gyroSaturated {
                Label("Gyro maxed out: speed is a lower bound", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(tint.opacity(0.25 + glow * 0.75), lineWidth: 2 + glow * 4)
        }
        .shadow(color: tint.opacity(glow * 0.6), radius: 18 * glow)
        .onChange(of: flashID, initial: true) { _, _ in
            glow = 1
            withAnimation(.easeOut(duration: 1.2)) { glow = 0 }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
        }
    }

    private func angle(_ deg: Double, pos: String, neg: String) -> String {
        let d = Int(deg.rounded())
        return d == 0 ? "0°" : "\(abs(d))° \(d > 0 ? pos : neg)"
    }
}

extension TimeInterval {
    var clock: String {
        let s = Int(self)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}


/// The racket's own verdict from its on-device sweet-spot model (heard from the impact sound).
struct VerdictBadge: View {
    var verdict: RacketProtocol.ShotVerdict
    var date: Date

    var body: some View {
        let tint: Color = verdict.isSweet ? .green : .red
        HStack(spacing: 10) {
            Image(systemName: "waveform.badge.mic").foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(verdict.isSweet ? "Sweet spot" : "About \(verdict.offCenterPercent)% off the sweet spot")
                    .font(.subheadline.weight(.semibold))
                Text("On-racket AI · \(verdict.confidencePercent)% sure")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 14))
        .id(date)
        .transition(.opacity)
    }
}
