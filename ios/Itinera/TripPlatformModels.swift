import Foundation

enum TripRevisionOperation: Encodable, Sendable {
    case addActivity(day: Int, position: Int?, activity: Activity)
    case removeActivity(day: Int, activityIndex: Int)
    case reorderActivity(day: Int, fromIndex: Int, toIndex: Int)
    case replaceActivity(day: Int, activityIndex: Int, activity: Activity)
    case regenerateDay(day: Int, theme: String, activities: [Activity])

    private enum CodingKeys: String, CodingKey {
        case type, day, position, activity, activityIndex, fromIndex, toIndex
        case theme, activities
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addActivity(let day, let position, let activity):
            try container.encode("add_activity", forKey: .type)
            try container.encode(day, forKey: .day)
            try container.encodeIfPresent(position, forKey: .position)
            try container.encode(activity, forKey: .activity)
        case .removeActivity(let day, let activityIndex):
            try container.encode("remove_activity", forKey: .type)
            try container.encode(day, forKey: .day)
            try container.encode(activityIndex, forKey: .activityIndex)
        case .reorderActivity(let day, let fromIndex, let toIndex):
            try container.encode("reorder_activity", forKey: .type)
            try container.encode(day, forKey: .day)
            try container.encode(fromIndex, forKey: .fromIndex)
            try container.encode(toIndex, forKey: .toIndex)
        case .replaceActivity(let day, let activityIndex, let activity):
            try container.encode("replace_activity", forKey: .type)
            try container.encode(day, forKey: .day)
            try container.encode(activityIndex, forKey: .activityIndex)
            try container.encode(activity, forKey: .activity)
        case .regenerateDay(let day, let theme, let activities):
            try container.encode("regenerate_day", forKey: .type)
            try container.encode(day, forKey: .day)
            try container.encode(theme, forKey: .theme)
            try container.encode(activities, forKey: .activities)
        }
    }
}

struct ItineraryRevisionCreate: Encodable, Sendable {
    let expectedVersion: Int
    let operations: [TripRevisionOperation]
}

struct ItineraryRevisionResponse: Codable, Sendable, Identifiable {
    let id: String
    let jobId: String
    let fromVersion: Int
    let toVersion: Int
    let operations: [[String: JSONValue]]
    let result: Itinerary
    let createdAt: String
}

enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct TripReservation: Codable, Identifiable, Sendable {
    let id: String
    var title: String
    var confirmationCode: String?
    var startsAt: String?
    var endsAt: String?
    var address: String?
    var url: String?
    var notes: String?
    let createdAt: String
    let updatedAt: String
}

struct TripReservationCreate: Encodable, Sendable {
    var title: String
    var confirmationCode: String?
    var startsAt: String?
    var endsAt: String?
    var address: String?
    var url: String?
    var notes: String?
}

struct TripChecklistItem: Codable, Identifiable, Sendable {
    let id: String
    var title: String
    var isCompleted: Bool
    var dueAt: String?
    var position: Int
    let createdAt: String
    let updatedAt: String
}

struct TripChecklistItemCreate: Encodable, Sendable {
    var title: String
    var dueAt: String? = nil
    var position: Int = 0
}

struct TripChecklistItemUpdate: Encodable, Sendable {
    var title: String? = nil
    var isCompleted: Bool? = nil
    var dueAt: String? = nil
    var position: Int? = nil
}

struct TripExpense: Codable, Identifiable, Sendable {
    let id: String
    var title: String
    var amountMinor: Int64
    var currency: String
    var category: String?
    var paidBy: String?
    var incurredAt: String?
    var notes: String?
    let createdAt: String
    let updatedAt: String
}

struct TripExpenseCreate: Encodable, Sendable {
    var title: String
    var amountMinor: Int64
    var currency: String
    var category: String?
    var paidBy: String?
    var incurredAt: String? = nil
    var notes: String?
}

struct TripCollaborator: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    let role: String
    let createdAt: String
}

struct CollaborationInvite: Codable, Identifiable, Sendable {
    let id: String
    let token: String
    let email: String?
    let role: String
    let expiresAt: String
}

struct CollaborationInviteCreate: Encodable, Sendable {
    let email: String?
    let role: String
    let expiresInHours: Int
}

struct CollaborationInviteAccept: Encodable, Sendable {
    let token: String
}

struct PlaceReport: Codable, Identifiable, Sendable {
    let id: String
    let activityName: String
    let category: String
    let details: String?
    let status: String
    let createdAt: String
}

struct PlaceReportCreate: Encodable, Sendable {
    let activityName: String
    let category: String
    let details: String?
}
