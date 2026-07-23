import Foundation

// Mirrors backend/schemas/itinerary.py. The API uses snake_case; we decode
// with .convertFromSnakeCase so property names are camelCase here.

struct Coordinates: Codable, Hashable, Sendable {
    var lat: Double
    var lng: Double
}

struct Accommodation: Codable, Hashable, Sendable {
    var address: String
    var lat: Double
    var lng: Double
}

enum TripTransportationOption: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case walking = "Walking"
    case transit = "Transit"
    case driving = "Driving"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .walking: return "figure.walk"
        case .transit: return "bus.fill"
        case .driving: return "car.fill"
        }
    }

    var detail: String {
        switch self {
        case .walking: return "Favor walkable stops and short hops"
        case .transit: return "Use trains, metro, buses, and ferries"
        case .driving: return "Allow car-friendly routes and parking time"
        }
    }

    static func normalizedRawValues(_ values: [String]?) -> [String] {
        let knownValues = Set(allCases.map(\.rawValue))
        let normalized = (values ?? [])
            .filter { knownValues.contains($0) }
        return normalized.isEmpty ? allCases.map(\.rawValue) : ordered(normalized)
    }

    static func selection(fromStoredValue value: String) -> Set<Self> {
        if value == "Mixed" || value.isEmpty {
            return Set(allCases)
        }
        let values = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let selection = Set(values.compactMap(Self.init(rawValue:)))
        return selection.isEmpty ? Set(allCases) : selection
    }

    static func ordered(_ values: some Sequence<String>) -> [String] {
        let selected = Set(values)
        return allCases.map(\.rawValue).filter(selected.contains)
    }
}

enum TripInterestCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case artAndDesign = "Art & design"
    case history = "History"
    case foodAndDrink = "Food & drink"
    case natureAndOutdoors = "Nature & outdoors"
    case architecture = "Architecture"
    case localCulture = "Local culture"
    case shopping = "Shopping"
    case nightlife = "Nightlife"
    case wellness = "Wellness"
    case familyActivities = "Family activities"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .artAndDesign: return "paintpalette.fill"
        case .history: return "building.columns.fill"
        case .foodAndDrink: return "fork.knife"
        case .natureAndOutdoors: return "leaf.fill"
        case .architecture: return "building.2.fill"
        case .localCulture: return "person.3.fill"
        case .shopping: return "bag.fill"
        case .nightlife: return "moon.stars.fill"
        case .wellness: return "figure.mind.and.body"
        case .familyActivities: return "figure.2.and.child.holdinghands"
        }
    }

    static func selection(fromStoredValue value: String) -> Set<Self> {
        Set(
            value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap(Self.init(rawValue:))
        )
    }
}

enum TripAccessibilityCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case stepFree = "Step-free routes"
    case wheelchair = "Wheelchair access"
    case limitedWalking = "Limited walking"
    case frequentRests = "Frequent rest breaks"
    case accessibleRestrooms = "Accessible restrooms"
    case hearingSupport = "Hearing support"
    case visualSupport = "Visual support"
    case sensoryFriendly = "Sensory-friendly"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .stepFree: return "figure.roll"
        case .wheelchair: return "wheelchair"
        case .limitedWalking: return "figure.walk.motion"
        case .frequentRests: return "chair.lounge.fill"
        case .accessibleRestrooms: return "figure.dress.line.vertical.figure"
        case .hearingSupport: return "ear.badge.waveform"
        case .visualSupport: return "eye.fill"
        case .sensoryFriendly: return "waveform.path"
        }
    }

    static func selection(fromStoredValue value: String) -> Set<Self> {
        Set(
            value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap(Self.init(rawValue:))
        )
    }
}

struct GenerateItineraryRequest: Codable, Equatable, Sendable {
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
    var pace: String = "Balanced"
    var transportationModes: [String] = TripTransportationOption.allCases.map(\.rawValue)
    var travelingWithChildren: Bool = false
    var interests: [String] = []
    var accessibilityCategories: [String] = []
    var accessibilityNeeds: String? = nil
    var fixedReservations: [FixedReservationInput] = []
    var unavailableTimes: [UnavailableTimeInput] = []
    var timezone: String? = nil

    private enum CodingKeys: String, CodingKey {
        case city, country, accommodation, arrivalDate, departureDate
        case groupSize, wakeUpTime, foodPreferences, mustDo, budget
        case pace, transportationModes, travelingWithChildren, interests
        case accessibilityCategories, accessibilityNeeds, fixedReservations
        case unavailableTimes, timezone
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case transportationPreference
    }
}

extension GenerateItineraryRequest {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        city = try container.decode(String.self, forKey: .city)
        country = try container.decode(String.self, forKey: .country)
        accommodation = try container.decode(Accommodation.self, forKey: .accommodation)
        arrivalDate = try container.decode(String.self, forKey: .arrivalDate)
        departureDate = try container.decode(String.self, forKey: .departureDate)
        groupSize = try container.decode(Int.self, forKey: .groupSize)
        wakeUpTime = try container.decode(String.self, forKey: .wakeUpTime)
        foodPreferences = try container.decodeIfPresent(
            String.self,
            forKey: .foodPreferences
        )
        mustDo = try container.decodeIfPresent(String.self, forKey: .mustDo)
        budget = try container.decode(String.self, forKey: .budget)

        // These planning fields were added after pending submissions first
        // shipped. Defaults keep an older persisted request replayable with its
        // original idempotency key instead of dropping the whole retry queue.
        pace = try container.decodeIfPresent(String.self, forKey: .pace)
            ?? "Balanced"
        if let values = try container.decodeIfPresent(
            [String].self,
            forKey: .transportationModes
        ) {
            transportationModes = TripTransportationOption.normalizedRawValues(values)
        } else {
            let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let legacyValue = try legacyContainer.decodeIfPresent(
                String.self,
                forKey: .transportationPreference
            ) ?? "Mixed"
            transportationModes = TripTransportationOption.ordered(
                TripTransportationOption.selection(fromStoredValue: legacyValue)
                    .map(\.rawValue)
            )
        }
        travelingWithChildren = try container.decodeIfPresent(
            Bool.self,
            forKey: .travelingWithChildren
        ) ?? false
        interests = try container.decodeIfPresent([String].self, forKey: .interests)
            ?? []
        accessibilityCategories = try container.decodeIfPresent(
            [String].self,
            forKey: .accessibilityCategories
        ) ?? []
        accessibilityNeeds = try container.decodeIfPresent(
            String.self,
            forKey: .accessibilityNeeds
        )
        fixedReservations = try container.decodeIfPresent(
            [FixedReservationInput].self,
            forKey: .fixedReservations
        ) ?? []
        unavailableTimes = try container.decodeIfPresent(
            [UnavailableTimeInput].self,
            forKey: .unavailableTimes
        ) ?? []
        timezone = try container.decodeIfPresent(String.self, forKey: .timezone)
    }
}

struct FixedReservationInput: Codable, Equatable, Sendable {
    var title: String
    var startsAt: String
    var endsAt: String? = nil
    var address: String? = nil
}

struct UnavailableTimeInput: Codable, Equatable, Sendable {
    var date: String
    var startsAt: String
    var endsAt: String
}

struct Activity: Codable, Hashable, Identifiable, Sendable {
    var activityId: String? = nil
    var time: String
    var name: String
    var type: String
    var duration: String
    var description: String
    var address: String
    var coordinates: Coordinates
    var placeId: String? = nil
    var source: String? = nil
    var sourcePlatforms: [String]? = nil
    var retrievedAt: String? = nil
    var verificationState: String? = nil
    var openingHours: [String]? = nil
    var phone: String? = nil
    var websiteUrl: String? = nil
    var reservationUrl: String? = nil
    var estimatedCost: String? = nil
    var accessibilityNotes: String? = nil

    var id: String {
        if let activityId, !activityId.isEmpty {
            return activityId
        }
        return "\(time)-\(name)-\(coordinates.lat)-\(coordinates.lng)"
    }

    private enum CodingKeys: String, CodingKey {
        case activityId = "id"
        case time, name, type, duration, description, address, coordinates
        case placeId, source, sourcePlatforms, retrievedAt, verificationState, openingHours
        case phone, websiteUrl, reservationUrl, estimatedCost, accessibilityNotes
    }
}

struct ItineraryDay: Codable, Hashable, Identifiable, Sendable {
    var day: Int
    var date: String? = nil
    var theme: String
    var activities: [Activity]

    var id: Int { day }
}

struct AccommodationInfo: Codable, Hashable, Sendable {
    var morningStart: String
    var eveningReturn: String
    var transportationTips: String
}

struct Itinerary: Codable, Hashable, Sendable {
    var itinerary: [ItineraryDay]
    var tips: [String]
    var accommodationInfo: AccommodationInfo
    var estimatedBudget: String
    var timeZoneIdentifier: String? = nil

    private enum CodingKeys: String, CodingKey {
        case itinerary, tips, accommodationInfo, estimatedBudget
        case timeZoneIdentifier = "timezone"
    }
}

struct JobAccepted: Codable, Sendable {
    var jobId: String
    var streamUrl: String
    var statusUrl: String
    var replayed: Bool?
}

enum JobState: String, Codable, Sendable {
    case pending, running, succeeded, failed
}

struct JobStatusResponse: Codable, Sendable {
    var jobId: String
    var status: JobState
    var result: Itinerary?
    var error: String?
    var errorCode: String? = nil
    var version: Int = 1

    private enum CodingKeys: String, CodingKey {
        case jobId, status, result, error, errorCode, version
    }
}

extension JobStatusResponse {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try container.decode(String.self, forKey: .jobId)
        status = try container.decode(JobState.self, forKey: .status)
        result = try container.decodeIfPresent(Itinerary.self, forKey: .result)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }
}

struct SavedItinerary: Codable, Identifiable, Sendable {
    var jobId: String
    var status: JobState
    var title: String?
    var sourcePublicItineraryId: String?
    var city: String?
    var country: String?
    var arrivalDate: String?
    var departureDate: String?
    var result: Itinerary?
    var error: String?
    var errorCode: String? = nil
    var archivedAt: String? = nil
    var version: Int = 1
    var createdAt: String

    private enum CodingKeys: String, CodingKey {
        case jobId, status, title, sourcePublicItineraryId, city, country
        case arrivalDate, departureDate, result, error, errorCode, archivedAt, version
        case createdAt
    }

    var id: String { jobId }

    var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return [city, country].compactMap { $0 }.joined(separator: ", ")
    }
}

extension SavedItinerary {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try container.decode(String.self, forKey: .jobId)
        status = try container.decode(JobState.self, forKey: .status)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        sourcePublicItineraryId = try container.decodeIfPresent(
            String.self,
            forKey: .sourcePublicItineraryId
        )
        city = try container.decodeIfPresent(String.self, forKey: .city)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        arrivalDate = try container.decodeIfPresent(String.self, forKey: .arrivalDate)
        departureDate = try container.decodeIfPresent(
            String.self,
            forKey: .departureDate
        )
        result = try container.decodeIfPresent(Itinerary.self, forKey: .result)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        archivedAt = try container.decodeIfPresent(String.self, forKey: .archivedAt)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }
}

struct PopularItinerarySummary: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var summary: String
    var city: String
    var country: String
    var locationKey: String
    var durationDays: Int
    var saveCount: Int
    var isSaved: Bool

    var locationName: String {
        [city, country]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

struct PopularItineraryDetail: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var summary: String
    var city: String
    var country: String
    var locationKey: String
    var durationDays: Int
    var saveCount: Int
    var isSaved: Bool
    var result: Itinerary
}

struct SavePopularItineraryResponse: Codable, Sendable {
    var created: Bool
    var savedItinerary: SavedItinerary
}
