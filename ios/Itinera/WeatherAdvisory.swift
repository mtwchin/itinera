import CoreLocation
import Foundation
import WeatherKit

struct WeatherAdvisory: Equatable, Sendable {
    let summary: String
    let temperature: String
    let precipitationChance: Double

    var recommendsIndoorPlan: Bool {
        precipitationChance >= 0.4
    }
}

@MainActor
enum TripWeatherService {
    static func advisory(for activity: Activity) async throws -> WeatherAdvisory {
        let location = CLLocation(
            latitude: activity.coordinates.lat,
            longitude: activity.coordinates.lng
        )
        async let current = WeatherService.shared.weather(
            for: location,
            including: .current
        )
        async let daily = WeatherService.shared.weather(
            for: location,
            including: .daily
        )
        let (currentWeather, dailyForecast) = try await (current, daily)
        return WeatherAdvisory(
            summary: currentWeather.condition.description,
            temperature: currentWeather.temperature.formatted(),
            precipitationChance: dailyForecast.forecast.first?.precipitationChance ?? 0
        )
    }
}
