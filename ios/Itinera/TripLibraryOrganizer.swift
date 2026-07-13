import Foundation

enum TripLibraryGroup: String, CaseIterable, Identifiable, Sendable {
    case active
    case upcoming
    case generating
    case saved
    case past
    case needsAttention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return "Happening now"
        case .upcoming: return "Upcoming"
        case .generating: return "In progress"
        case .saved: return "Saved guides"
        case .past: return "Past trips"
        case .needsAttention: return "Needs attention"
        }
    }

    var eyebrow: String {
        switch self {
        case .active: return "TODAY"
        case .upcoming: return "UP NEXT"
        case .generating: return "GENERATING"
        case .saved: return "LIBRARY"
        case .past: return "HISTORY"
        case .needsAttention: return "REVIEW"
        }
    }
}

enum TripLibraryOrganizer {
    static func groups(
        for trips: [SavedItinerary],
        searchText: String,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [(group: TripLibraryGroup, trips: [SavedItinerary])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? trips
            : trips.filter { matches($0, query: query) }

        let grouped = Dictionary(grouping: filtered) {
            group(for: $0, today: today, calendar: calendar)
        }
        return TripLibraryGroup.allCases.compactMap { group in
            guard let values = grouped[group], !values.isEmpty else { return nil }
            return (group, values.sorted(by: newestFirst))
        }
    }

    static func group(
        for trip: SavedItinerary,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> TripLibraryGroup {
        switch trip.status {
        case .pending, .running:
            return .generating
        case .failed:
            return .needsAttention
        case .succeeded:
            break
        }

        var destinationCalendar = calendar
        if let identifier = trip.result?.timeZoneIdentifier,
           let timeZone = TimeZone(identifier: identifier) {
            destinationCalendar.timeZone = timeZone
        }

        guard
            let arrival = localDate(
                trip.arrivalDate,
                calendar: destinationCalendar
            ),
            let departure = localDate(
                trip.departureDate,
                calendar: destinationCalendar
            )
        else {
            return .saved
        }

        let startOfToday = destinationCalendar.startOfDay(for: today)
        if startOfToday < arrival { return .upcoming }
        if startOfToday > departure { return .past }
        return .active
    }

    static func localDate(
        _ value: String?,
        calendar: Calendar = .current
    ) -> Date? {
        guard let value else { return nil }
        let pieces = value.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = pieces[0]
        components.month = pieces[1]
        components.day = pieces[2]
        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        guard
            resolved.year == pieces[0],
            resolved.month == pieces[1],
            resolved.day == pieces[2]
        else {
            return nil
        }
        return calendar.startOfDay(for: date)
    }

    private static func matches(
        _ trip: SavedItinerary,
        query: String
    ) -> Bool {
        let searchable = [
            trip.displayTitle,
            trip.city ?? "",
            trip.country ?? "",
            trip.arrivalDate ?? "",
            trip.departureDate ?? ""
        ] + (trip.result?.itinerary.flatMap { day in
            [day.theme] + day.activities.flatMap { [$0.name, $0.address] }
        } ?? [])
        return searchable.contains {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    private static func newestFirst(
        _ lhs: SavedItinerary,
        _ rhs: SavedItinerary
    ) -> Bool {
        if lhs.createdAt == rhs.createdAt { return lhs.jobId < rhs.jobId }
        return lhs.createdAt > rhs.createdAt
    }
}
