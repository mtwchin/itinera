import Foundation

// MARK: - Itinerary (API response)

/// Coordinates as returned by the API. `lat`/`lng` of 0 means "unknown".
struct Coordinates: Codable, Hashable {
    var lat: Double
    var lng: Double

    var isValid: Bool {
        (lat != 0 || lng != 0)
            && (-90...90).contains(lat)
            && (-180...180).contains(lng)
    }
}

/// One activity in a day. Every field is optional because the itinerary is
/// LLM-generated and occasionally omits fields.
struct Activity: Codable, Hashable {
    var time: String?
    var name: String?
    var type: String?
    var duration: String?
    var description: String?
    var address: String?
    var coordinates: Coordinates?

    var displayName: String { name ?? "Activity" }

    var systemImageName: String {
        switch type?.lowercased() {
        case "food": return "fork.knife"
        case "culture": return "building.columns"
        case "nature": return "leaf"
        case "shopping": return "bag"
        default: return "mappin.and.ellipse"
        }
    }
}

struct DayPlan: Codable, Hashable {
    var day: Int
    var theme: String?
    var activities: [Activity]?

    var allActivities: [Activity] { activities ?? [] }
}

struct AccommodationInfo: Codable, Hashable {
    var morningStart: String?
    var eveningReturn: String?
    var transportationTips: String?
}

struct Itinerary: Codable, Hashable {
    var itinerary: [DayPlan]
    var tips: [String]?
    var accommodationInfo: AccommodationInfo?
    var estimatedBudget: String?
}

/// A trending place surfaced alongside the generated itinerary.
struct TrendingPlace: Codable, Hashable {
    var name: String?
    var type: String?
    var description: String?
    var address: String?
    var views: Int?
    var engagement: Int?
    var coordinates: Coordinates?

    var displayName: String { name ?? "Popular spot" }

    var systemImageName: String {
        switch type?.lowercased() {
        case "food": return "fork.knife"
        case "culture": return "building.columns"
        case "nature": return "leaf"
        case "shopping": return "bag"
        default: return "mappin.and.ellipse"
        }
    }
}

// MARK: - Generation request

struct AccommodationRequest: Codable {
    var address: String
    var lat: Double
    var lng: Double
}

struct GenerateItineraryRequest: Codable {
    var city: String
    var country: String
    var accommodation: AccommodationRequest
    var arrivalDate: String
    var departureDate: String
    var budget: String
    var lengthOfStay: Int
    var wakeUpTime: String
    var groupSize: Int
    var foodPreferences: String
    var mustDo: String
}

// MARK: - Saved trips (local persistence)

struct SavedTrip: Codable, Identifiable, Hashable {
    var id: UUID
    var destination: String
    var startDate: Date
    var endDate: Date
    var budget: String
    var createdAt: Date
    var itinerary: Itinerary
    // Optional so trips saved by earlier versions still decode.
    var trendingPlaces: [TrendingPlace]? = nil

    var dayCount: Int { itinerary.itinerary.count }
}

// MARK: - API envelope

struct APIEnvelope<Payload: Codable>: Codable {
    var success: Bool
    var data: Payload?
    var error: String?
}
