import Foundation
import OpenWaterCore
import SwiftUI

/// The units this television shows its numbers in.
///
/// The screens used to read `UnitPreferences.forThisDevice` — the box's
/// region, and nothing a rider could change. That put a household in Texas
/// in Fahrenheit and a household in Kiel in Celsius, which is right often
/// enough, and left wind in knots for everybody, which is right for the sport
/// and wrong for the sofa: somebody who has never sailed reads "12 kn" and has
/// to ask. So the two things worth asking about are asked about, in Settings,
/// and kept here — one object in the environment rather than an `AppStorage`
/// in every view that prints a number, because there are a dozen of those and
/// they have to move together.
///
/// Distance is not offered. The only distances on this box are "how far is
/// the camera" and "how high is the wave", and the region's answer is right
/// for both.
///
/// Wind arrives everywhere in this app as knots — the model, the instruments,
/// the palette's thresholds — and stays that way inside. Only the printed
/// number is converted, which is why `wind(_:)` exists rather than a change to
/// any reading.
@MainActor
@Observable
final class TVUnits {

    static let speedKey = "tv.units.speed"
    static let temperatureKey = "tv.units.temperature"

    /// The units a rider may choose between. Metres per second is left out:
    /// nobody in a living room asks for it, and a fourth segment makes the
    /// three that matter smaller.
    static let speeds: [SpeedUnit] = [.knots, .mph, .kmh]

    var speed: SpeedUnit {
        didSet { UserDefaults.standard.set(speed.rawValue, forKey: Self.speedKey) }
    }

    var temperature: TemperatureUnit {
        didSet { UserDefaults.standard.set(temperature.rawValue, forKey: Self.temperatureKey) }
    }

    init() {
        let device = UnitPreferences.forThisDevice
        let defaults = UserDefaults.standard
        speed = defaults.string(forKey: Self.speedKey).flatMap(SpeedUnit.init(rawValue:)) ?? device.speed
        temperature = defaults.string(forKey: Self.temperatureKey)
            .flatMap(TemperatureUnit.init(rawValue:)) ?? device.temperatureUnit
    }

    /// Everything `Format` wants, in one struct: the two the rider set, and
    /// the distance the box's region decides.
    var preferences: UnitPreferences {
        UnitPreferences(speed: speed,
                        distance: UnitPreferences.forThisDevice.distance,
                        temperature: temperature)
    }

    var speedSymbol: String { speed.symbol }

    /// A wind the model or an instrument gave in knots, in the rider's unit.
    func wind(_ knots: Double) -> Double {
        speed.convert(fromMetresPerSecond: SpeedUnit.knots.toMetresPerSecond(knots))
    }

    /// The number alone, rounded — for the places the symbol is drawn
    /// separately at its own size.
    func windValue(_ knots: Double) -> String {
        "\(Int(wind(knots).rounded()))"
    }

    /// Number and symbol: "12 mph".
    func windLabel(_ knots: Double) -> String {
        "\(windValue(knots)) \(speedSymbol)"
    }
}
