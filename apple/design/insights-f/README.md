# Insights page redesign (option F, "Metric explorer")

Replaces the body of `Shared/Views/InsightsView.swift`.
Picture: `insights-f.png`. Static HTML of the same screen: `insights-f.html`. All numbers in both are sample data.

## The idea

One page, three controls, one chart.

1. **Time dropdown** (top right): Last 7 days, Last 30 days, Last 90 days, This year, All time.
2. **Shot type chips**: All, Forehand, Backhand, Serve, Volley. Never show Calibration.
3. **Metric tabs** (scroll sideways, underline marks the pick): Ball speed, Swing speed, Spin, Face, Path, Contact, Shots, Heart rate, Sweet spot.

Everything below the tabs follows those three picks. Sweet spot is one tab, not the star.

## Layout, top to bottom

| Block | What it shows |
|---|---|
| Header | "Insights" title, time dropdown pill |
| Shot type chips | Selected chip = accent fill, black text. Others = outline. 44 pt high |
| Metric tabs | Text tabs, 3 pt accent underline on the pick |
| Big number | Average for the period (56 pt bold), unit, delta pill, then "Top · Low · vs previous period" line |
| Range chart | One bar per session: slowest to fastest shot. Dot = session average |
| By stroke | One bar per stroke for the picked metric. Hidden when a stroke chip is picked |
| Sessions | Last 3 sessions: date, shot count, duration, average, top. Tap opens `SessionDetailView` |
| Coach row | One tappable row. Opens the coach screen (see "Moved out of this page") |

## Look

Same dark look as the rest of the app. Accent is the app's `AccentColor` (lime).

| Token | Value |
|---|---|
| Background | `#0B0C09` |
| Card | `#171913`, radius 18–22 |
| Track | `#2A2E20` |
| Text | `#F3F5EC` |
| Muted text | `#A9AE9A` |
| Better | `#5EDC8A`, shown as ▲/▼ plus words, never color alone |
| Neutral | `#2A2E20` pill, `#C9CDBB` text |
| Worse | `#FF9A8D` |

In SwiftUI use system colors where they exist (`.background.secondary`, `.secondary`, `Color.accentColor`) so light mode keeps working. The hex values above are the dark-mode intent.

## Data: where each number comes from

All of it already exists. No new fields.

| Tab | Per shot | Per session range bar | Better is |
|---|---|---|---|
| Ball speed | `ballSpeedKmh` | min, max, mean of motion shots | higher |
| Swing speed | `swingSpeedKmh` | same | higher |
| Spin | `spinRPM` | same | higher (topspin) or neutral |
| Face | `faceAngleDeg` (+ = open) | same | closer to 0 |
| Path | `swingPathDeg` (+ = low to high) | same | no verdict, just show it |
| Contact | `impactDistanceCm` | same | lower |
| Shots | count | no range. Plain bars | higher |
| Heart rate | none | no range. One dot from `SessionRecord.averageHeartRate` (skip if 0) | no verdict |
| Sweet spot | `isSweetSpot` | no range. One dot from `ShotSummary.sweetSpotPercent` | higher |

Rules:
- Use `session.shots` filtered by the stroke chip and `type != .calibration`.
- Speed, spin, face and path only count shots where `hasMotion` is true. Mic-only shots have no motion data.
- Convert at the edge with `UnitSystem` (`speed`, `speedUnit`, `length`, `lengthUnit`). Stored values stay metric.
- Delta = this period's average minus the previous period's average. The previous period is the same length, directly before.
- "Top" and "Low" are the max and min shot in the period. For Shots, Heart rate and Sweet spot, drop that line.
- By stroke: group the same shots by `ShotType`, one average each. Skip a stroke with fewer than 5 shots.
- If a session has no shots for the current picks, leave it out of the chart.

## SwiftUI sketch (not compiled)

```swift
enum InsightMetric: String, CaseIterable, Identifiable {
    case ballSpeed, swingSpeed, spin, face, path, contact, shots, heartRate, sweetSpot
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ballSpeed: "Ball speed"; case .swingSpeed: "Swing speed"; case .spin: "Spin"
        case .face: "Face"; case .path: "Path"; case .contact: "Contact"
        case .shots: "Shots"; case .heartRate: "Heart rate"; case .sweetSpot: "Sweet spot"
        }
    }
    /// Value for one shot, already in display units. nil = shot has no value for this metric.
    func value(_ s: ShotMetrics, _ u: UnitSystem) -> Double? {
        switch self {
        case .ballSpeed: s.hasMotion ? u.speed(s.ballSpeedKmh) : nil
        case .swingSpeed: s.hasMotion ? u.speed(s.swingSpeedKmh) : nil
        case .spin: s.hasMotion ? s.spinRPM : nil
        case .face: s.hasMotion ? s.faceAngleDeg : nil
        case .path: s.hasMotion ? s.swingPathDeg : nil
        case .contact: u.length(s.impactDistanceCm)
        case .shots, .heartRate, .sweetSpot: nil   // session-level, handled separately
        }
    }
}

enum InsightPeriod: String, CaseIterable { case week, month, quarter, year, all
    var days: Int? { switch self { case .week: 7; case .month: 30; case .quarter: 90; case .year: 365; case .all: nil } }
}

struct SessionPoint: Identifiable {
    var id: UUID; var date: Date
    var low: Double; var high: Double; var avg: Double
    var shotCount: Int; var duration: TimeInterval
}
```

Chart:

```swift
Chart(points) { p in
    RuleMark(x: .value("Session", p.date, unit: .day),
             yStart: .value("Low", p.low), yEnd: .value("High", p.high))
        .lineStyle(StrokeStyle(lineWidth: 16, lineCap: .round))
        .foregroundStyle(Color.accentColor.opacity(0.28))
    PointMark(x: .value("Session", p.date, unit: .day), y: .value("Average", p.avg))
        .symbolSize(90)
        .foregroundStyle(Color.accentColor)
}
.chartYAxisLabel(units.speedUnit)   // swap per metric
.frame(height: 210)
```

Put the filtering and averaging in a small `InsightsModel` (plain struct or `@Observable`) so it can be unit tested without views. Add a test next to `Tests/CoachTests.swift`.

## Moved out of this page

The current Insights page also holds things that do not fit here. They need a new home:

| Today in `InsightsView.swift` | Suggested home |
|---|---|
| `coachChat` (ask box, quick questions, drill planner) | New Coach screen, pushed from the Coach row |
| `museSettings` (API key form) | Same Coach screen, under a "Coach engine" section |
| `CoachCard` | Stays in `SessionDetailView`. Not part of this page |

The Coach screen can reuse the current `coachChat` and `museSettings` code as is.

## Empty and edge states

- No sessions at all: keep today's `ContentUnavailableView("No data yet", …)`.
- Period has no shots for the picks: show "No \(stroke) shots in this period" in place of the chart.
- One session only: show the bar and dot, hide the delta pill.
- Heart rate without Watch data: hide the tab.

## Open choices

- Should "Sweet spot" stay as a tab, or become a tile on the Sessions rows?
- Should the Face and Path tabs use a centered axis (0° in the middle) instead of the plain range chart?
- Does the dropdown need a custom date range?
