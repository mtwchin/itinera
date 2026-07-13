import Foundation

struct TripMutationResponse: Codable, Equatable, Sendable {
    let jobId: String
    let title: String?
    let archivedAt: String?
    let version: Int
}

struct TripUpdateRequest: Codable, Equatable, Sendable {
    let title: String?
    let archived: Bool?
}
