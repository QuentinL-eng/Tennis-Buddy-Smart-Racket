import Foundation
import MWDATDisplay

/// Everything the glasses HUD shows, flattened to strings so this file needs no SwiftUI (its `Text`, `Button` and
/// `Image` would clash with the Display DSL).
struct GlassesHUDSnapshot: Equatable {
    var elapsed = ""
    var shots = 0
    var sweetSpotPercent = 0
    /// "Forehand" / "112 km/h · Sweet spot" for the latest hit.
    var lastShotTitle: String?
    var lastShotDetail: String?
    var lastShotSweet = false
    var points: String?
    var score: String?
    var drill: String?
    var summary = false
}

enum GlassesHUD {
    /// The in-session card. Tapping "End" asks for confirmation first, since the glasses are easy to brush.
    static func session(_ s: GlassesHUDSnapshot, confirmingEnd: Bool,
                        onEnd: @escaping @Sendable () -> Void,
                        onConfirm: @escaping @Sendable () -> Void,
                        onCancel: @escaping @Sendable () -> Void) -> FlexBox {
        FlexBox(direction: .column, spacing: 10) {
            FlexBox(direction: .row, spacing: 8, alignment: .start, crossAlignment: .center) {
                Icon(name: .clock)
                Text(s.elapsed, style: .meta, color: .secondary)
            }
            if let title = s.lastShotTitle {
                Text(title, style: .heading)
                if let detail = s.lastShotDetail {
                    Text(detail, style: .body, color: s.lastShotSweet ? .primary : .secondary)
                }
            } else {
                Text("Ready", style: .heading)
                Text("Hit a ball to see your shot", style: .body, color: .secondary)
            }
            Text("\(s.shots) shots · \(s.sweetSpotPercent)% sweet spot", style: .meta, color: .secondary)
            if let score = s.score { Text(score, style: .body) }
            if let points = s.points { Text(points, style: .meta, color: .secondary) }
            if let drill = s.drill { Text(drill, style: .meta, color: .secondary) }
            if confirmingEnd {
                ButtonGroup {
                    Button(label: "End session", style: .primary, iconName: .checkmark, onClick: onConfirm)
                    Button(label: "Keep going", style: .secondary, onClick: onCancel)
                }
            } else {
                ButtonGroup {
                    Button(label: "End", style: .outline, onClick: onEnd)
                }
            }
        }
        .padding(20)
        .background(.card)
    }

    /// Shown for a few seconds when the session ends.
    static func summary(_ s: GlassesHUDSnapshot) -> FlexBox {
        FlexBox(direction: .column, spacing: 10) {
            FlexBox(direction: .row, spacing: 8, alignment: .start, crossAlignment: .center) {
                Icon(name: .checkmarkCircle)
                Text("Session saved", style: .heading)
            }
            Text("\(s.shots) shots · \(s.sweetSpotPercent)% sweet spot", style: .body)
            Text(s.elapsed, style: .meta, color: .secondary)
        }
        .padding(20)
        .background(.card)
    }

    static func message(_ title: String, _ detail: String) -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            Text(title, style: .heading)
            Text(detail, style: .body, color: .secondary)
        }
        .padding(20)
        .background(.card)
    }
}
