import Foundation

// Mirrors backend/schemas/itinerary.py. The API uses snake_case; we decode
// with .convertFromSnakeCase so property names are camelCase here.

struct Coordinates: Codable, Hashable {
    var lat: Double
    var lng: Double
}

struct Accommodation: Codable, Hashable {
    var address: String
    var lat: Double
    var lng: Double
}

struct GenerateItineraryRequest: Codable {
    var city: String
    var country: String
    var accommodation: Accommodation
    var arrivalDate: String    // yyyy-MM-dd
    var departureDate: String  // yyyy-MM-dd
    var groupSize: Int
    var wakeUpTime: String
    var foodPreferences: String?
    var mustDo: String?
    var budget: String
}

struct Activity: Codable, Hashable, Identifiable {
    var time: String
    var name: String
    var type: String
    var duration: String
    var description: String
    var address: String
    var coordinates: Coordinates

    var id: String { "\(time)-\(name)" }
}

struct ItineraryDay: Codable, Hashable, Identifiable {
    var day: Int
    var theme: String
    var activities: [Activity]

    var id: Int { day }
}

struct AccommodationInfo: Codable, Hashable {
    var morningStart: String
    var eveningReturn: String
    var transportationTips: String
}

struct Itinerary: Codable, Hashable {
    var itinerary: [ItineraryDay]
    var tips: [String]
    var accommodationInfo: AccommodationInfo
    var estimatedBudget: String
}

struct JobAccepted: Codable {
    var jobId: String
    var streamUrl: String
    var statusUrl: String
}

enum JobState: String, Codable {
    case pending, running, succeeded, failed
}

struct JobStatusResponse: Codable {
    var jobId: String
    var status: JobState
    var result: Itinerary?
    var error: String?
}

struct SavedItinerary: Codable, Identifiable {
    var jobId: String
    var status: JobState
    var city: String?
    var country: String?
    var arrivalDate: String?
    var departureDate: String?
    var result: Itinerary?
    var error: String?
    var createdAt: String

    var id: String { jobId }

    var title: String {
        [city, country].compactMap { $0 }.joined(separator: ", ")
    }
}
