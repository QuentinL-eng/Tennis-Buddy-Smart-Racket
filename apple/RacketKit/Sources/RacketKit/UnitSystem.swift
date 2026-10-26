import Foundation

/// Display units. Stored metrics stay metric (km/h, cm); views convert at the edge.
/// Imperial is the default; the "useMetric" setting switches everything to metric.
public struct UnitSystem: Sendable, Equatable {
    public static let storageKey = "useMetric"
    public var metric: Bool

    public init(metric: Bool) { self.metric = metric }

    /// Current setting from UserDefaults (default imperial).
    public static var current: UnitSystem { UnitSystem(metric: UserDefaults.standard.bool(forKey: storageKey)) }

    public var speedUnit: String { metric ? "km/h" : "mph" }
    public var lengthUnit: String { metric ? "cm" : "in" }

    public func speed(_ kmh: Double) -> Double { metric ? kmh : kmh / 1.609344 }
    public func length(_ cm: Double) -> Double { metric ? cm : cm / 2.54 }

    /// Whole-number speed, e.g. "87".
    public func speedValue(_ kmh: Double) -> String { "\(Int(speed(kmh).rounded()))" }
    /// Speed with unit, e.g. "87 mph".
    public func speedText(_ kmh: Double) -> String { "\(speedValue(kmh)) \(speedUnit)" }
    /// Length with one decimal and unit, e.g. "1.6 in".
    public func lengthText(_ cm: Double) -> String { String(format: "%.1f %@", length(cm), lengthUnit) }
}
