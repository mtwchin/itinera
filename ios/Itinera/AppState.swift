import Combine
import Foundation

enum LocalDataCleanupError: LocalizedError, Sendable {
    case incomplete

    var errorDescription: String? {
        "Your server data was deleted, but some local files could not be removed. Restart Itinera and clear downloaded trips again."
    }
}

@MainActor
final class AppState: ObservableObject {
    let apiClient: APIClient
    let tripProgressStore: TripProgressStore

    @Published private(set) var pendingJobs: [PendingJobRecord] = []
    @Published private(set) var cachedTrips: [SavedItinerary] = []
    @Published private(set) var tripCacheRefreshedAt: Date?
    @Published private(set) var persistenceError: String?
    @Published private(set) var offlineCacheError: String?
    @Published private(set) var libraryRevision = 0

    private let pendingJobStore: PendingJobStore
    private let pendingSubmissionStore: PendingSubmissionStore
    private let completedTripCache: CompletedTripCache

    init(
        apiClient: APIClient,
        pendingJobStore: PendingJobStore,
        pendingSubmissionStore: PendingSubmissionStore,
        completedTripCache: CompletedTripCache = .live(),
        tripProgressStore: TripProgressStore = .live()
    ) {
        self.apiClient = apiClient
        self.pendingJobStore = pendingJobStore
        self.pendingSubmissionStore = pendingSubmissionStore
        self.completedTripCache = completedTripCache
        self.tripProgressStore = tripProgressStore
    }

    static func live() -> AppState {
        let configuration = APIConfiguration.live()
        let session = URLSession(configuration: configuration.makeSessionConfiguration())
        let credentialStore = KeychainCredentialStore()
        let apiClient = APIClient(
            configuration: configuration,
            session: session,
            credentialStore: credentialStore
        )
        return AppState(
            apiClient: apiClient,
            pendingJobStore: .live(),
            pendingSubmissionStore: .live(),
            completedTripCache: .live(),
            tripProgressStore: .live()
        )
    }

    func loadCachedTrips() async {
        do {
            let snapshot = try await completedTripCache.load()
            publishCache(snapshot)
            offlineCacheError = nil
        } catch {
            offlineCacheError = "Offline trips could not be loaded on this iPhone."
        }
    }

    /// Fetches the authoritative library and updates its protected offline copy.
    /// The caller can continue displaying `cachedTrips` if this throws.
    func refreshTripLibrary() async throws -> [SavedItinerary] {
        let remoteTrips = try await apiClient.savedItineraries(
            includeArchived: true
        )
        let activeTrips = remoteTrips.filter { $0.archivedAt == nil }
        do {
            let snapshot = try await completedTripCache.replace(with: remoteTrips)
            publishCache(snapshot)
            offlineCacheError = nil
        } catch {
            offlineCacheError = "Trips loaded, but the offline copy could not be updated."
        }
        return activeTrips
    }

    /// Makes a newly generated result available offline with authoritative
    /// library metadata when the server is reachable. Generation remains
    /// recoverable offline when the follow-up library request fails.
    func cacheCompletedTrip(jobID: String, itinerary: Itinerary) async {
        let trip: SavedItinerary
        do {
            if var authoritative = try await apiClient.savedItineraries()
                .first(where: { $0.jobId == jobID }) {
                authoritative.status = .succeeded
                authoritative.result = authoritative.result ?? itinerary
                authoritative.error = nil
                trip = authoritative
            } else {
                trip = await fallbackCompletedTrip(
                    jobID: jobID,
                    itinerary: itinerary
                )
            }
        } catch {
            trip = await fallbackCompletedTrip(
                jobID: jobID,
                itinerary: itinerary
            )
        }

        await persistCompletedTrip(
            trip,
            failureMessage: "This trip is ready, but its offline copy could not be saved."
        )
        markLibraryChanged()
    }

    /// Applies a server-accepted revision to the same protected snapshot used
    /// by Today and Trips before notifying library observers.
    @discardableResult
    func reviseTrip(
        jobID: String,
        expectedVersion: Int,
        operations: [TripRevisionOperation]
    ) async throws -> ItineraryRevisionResponse {
        let response = try await apiClient.reviseTrip(
            jobID,
            expectedVersion: expectedVersion,
            operations: operations
        )
        var trip = await fallbackCompletedTrip(
            jobID: jobID,
            itinerary: response.result
        )
        trip.status = .succeeded
        trip.result = response.result
        trip.error = nil
        trip.version = response.toVersion

        await persistCompletedTrip(
            trip,
            failureMessage: "The revision was saved, but its offline copy could not be updated."
        )
        markLibraryChanged()
        return response
    }

    private func fallbackCompletedTrip(
        jobID: String,
        itinerary: Itinerary
    ) async -> SavedItinerary {
        let publishedTrip = cachedTrips.first { $0.jobId == jobID }
        let storedSnapshot = try? await completedTripCache.load()
        let storedTrip = publishedTrip ?? storedSnapshot?.trips.first {
            $0.jobId == jobID
        }
        if var storedTrip {
            storedTrip.status = .succeeded
            storedTrip.result = itinerary
            storedTrip.error = nil
            return storedTrip
        }

        let pending = pendingJobs.first { $0.jobID == jobID }
        return SavedItinerary(
            jobId: jobID,
            status: .succeeded,
            title: pending?.title,
            sourcePublicItineraryId: nil,
            city: nil,
            country: nil,
            arrivalDate: nil,
            departureDate: nil,
            result: itinerary,
            error: nil,
            createdAt: ISO8601DateFormatter().string(
                from: pending?.createdAt ?? Date()
            )
        )
    }

    private func persistCompletedTrip(
        _ trip: SavedItinerary,
        failureMessage: String
    ) async {
        do {
            let snapshot = try await completedTripCache.upsert(trip)
            publishCache(snapshot)
            offlineCacheError = nil
        } catch {
            offlineCacheError = failureMessage
        }
    }

    @discardableResult
    func renameTrip(jobID: String, title: String) async throws -> TripMutationResponse {
        let response = try await apiClient.updateTrip(jobID, title: title)
        do {
            let snapshot = try await completedTripCache.rename(
                jobID: jobID,
                title: response.title ?? title
            )
            if let snapshot {
                publishCache(snapshot)
            }
            offlineCacheError = nil
        } catch {
            offlineCacheError = "The trip was renamed, but its offline copy could not be updated."
        }
        markLibraryChanged()
        return response
    }

    func archiveTrip(jobID: String) async throws {
        let response = try await apiClient.updateTrip(jobID, archived: true)
        do {
            let snapshot = try await completedTripCache.setArchivedAt(
                jobID: jobID,
                archivedAt: response.archivedAt
            )
            if let snapshot {
                publishCache(snapshot)
            }
            offlineCacheError = nil
        } catch {
            offlineCacheError = "The trip was archived, but its offline copy could not be updated."
        }
        markLibraryChanged()
    }

    func restoreTrip(_ trip: SavedItinerary) async throws {
        let response = try await apiClient.updateTrip(
            trip.jobId,
            archived: false
        )
        if trip.result != nil {
            var restored = trip
            restored.archivedAt = nil
            restored.title = response.title ?? restored.title
            restored.version = response.version
            do {
                let snapshot = try await completedTripCache.upsert(restored)
                publishCache(snapshot)
                offlineCacheError = nil
            } catch {
                offlineCacheError = "The trip was restored, but it isn't available offline yet."
            }
        }
        markLibraryChanged()
    }

    @discardableResult
    func duplicateTrip(jobID: String) async throws -> SavedItinerary {
        let duplicate = try await apiClient.duplicateTrip(jobID)
        if duplicate.result != nil {
            do {
                let snapshot = try await completedTripCache.upsert(duplicate)
                publishCache(snapshot)
            } catch {
                offlineCacheError = "The copy was created, but it isn't available offline yet."
            }
        }
        markLibraryChanged()
        return duplicate
    }

    func archivedTrips() async throws -> [SavedItinerary] {
        try await apiClient.savedItineraries(includeArchived: true)
            .filter { $0.archivedAt != nil }
    }

    func deleteTrip(jobID: String) async throws {
        try await apiClient.deleteTrip(jobID)
        await removeTripFromDeviceCaches(
            jobID: jobID,
            removeProgress: true
        )
        if pendingJobs.contains(where: { $0.jobID == jobID }) {
            await resolvePending(jobID: jobID)
        }
        markLibraryChanged()
    }

    private func removeTripFromDeviceCaches(
        jobID: String,
        removeProgress: Bool
    ) async {
        do {
            let snapshot = try await completedTripCache.remove(jobID: jobID)
            if let snapshot {
                publishCache(snapshot)
            }
            offlineCacheError = nil
        } catch {
            offlineCacheError = "The trip changed, but its offline copy could not be updated."
        }
        if removeProgress {
            try? await tripProgressStore.removeProgress(for: jobID)
        }
    }

    func clearDownloadedTripData() async throws {
        var cleanupFailed = false
        do {
            try await completedTripCache.removeAll()
        } catch {
            cleanupFailed = true
        }
        do {
            try await tripProgressStore.removeAll()
        } catch {
            cleanupFailed = true
        }
        cachedTrips = []
        tripCacheRefreshedAt = nil
        offlineCacheError = nil
        if cleanupFailed {
            throw LocalDataCleanupError.incomplete
        }
    }

    func deleteMyData() async throws {
        try await apiClient.deleteMyData()

        // The server deletion has already committed. Attempt every local
        // cleanup independently so one corrupt file cannot leave other trip
        // data or scheduled notifications behind.
        var cleanupFailed = false
        do {
            try await clearDownloadedTripData()
        } catch {
            cleanupFailed = true
        }
        do {
            try await pendingSubmissionStore.removeAll()
        } catch {
            cleanupFailed = true
        }
        do {
            pendingJobs = try await pendingJobStore.replace(with: [])
        } catch {
            pendingJobs = []
            cleanupFailed = true
        }
        ItineraLocalDataCleaner.clearTripDraftAndLocks()
        await GenerationNotificationManager.shared.removeAllItineraNotifications()

        persistenceError = nil
        markLibraryChanged()
        if cleanupFailed {
            throw LocalDataCleanupError.incomplete
        }
    }

    func connectAppleAccount(identityToken: String) async throws {
        try await apiClient.connectAppleAccount(identityToken: identityToken)
        _ = try await refreshTripLibrary()
        markLibraryChanged()
    }

    func loadPendingJobs() async {
        do {
            pendingJobs = try await pendingJobStore.all()
            persistenceError = nil
        } catch {
            persistenceError = "Pending trips could not be loaded."
        }
    }

    func registerPending(jobID: String, title: String? = nil) async {
        do {
            pendingJobs = try await pendingJobStore.add(jobID: jobID, title: title)
            persistenceError = nil
        } catch {
            persistenceError = "This pending trip could not be saved on this device."
        }
    }

    func submitItinerary(
        _ request: GenerateItineraryRequest,
        title: String
    ) async throws -> JobAccepted {
        let submission = try await pendingSubmissionStore.record(
            for: request,
            title: title
        )
        let accepted: JobAccepted
        do {
            accepted = try await apiClient.createItinerary(
                submission.request,
                idempotencyKey: submission.idempotencyKey
            )
        } catch let error as APIError where error.shouldDiscardPendingSubmission {
            try? await pendingSubmissionStore.remove(
                idempotencyKey: submission.idempotencyKey
            )
            throw error
        }
        await registerPending(jobID: accepted.jobId, title: submission.title)
        do {
            try await pendingSubmissionStore.remove(
                idempotencyKey: submission.idempotencyKey
            )
        } catch {
            persistenceError = "The accepted trip could not be cleared from the retry queue."
        }
        return accepted
    }

    func resumePendingSubmissions() async {
        let submissions: [PendingSubmissionRecord]
        do {
            submissions = try await pendingSubmissionStore.all()
        } catch {
            persistenceError = "Pending trip submissions could not be loaded."
            return
        }

        for submission in submissions {
            do {
                let accepted = try await apiClient.createItinerary(
                    submission.request,
                    idempotencyKey: submission.idempotencyKey
                )
                await registerPending(jobID: accepted.jobId, title: submission.title)
                try await pendingSubmissionStore.remove(
                    idempotencyKey: submission.idempotencyKey
                )
            } catch is CancellationError {
                return
            } catch let error as APIError where error.shouldDiscardPendingSubmission {
                try? await pendingSubmissionStore.remove(
                    idempotencyKey: submission.idempotencyKey
                )
            } catch {
                // Retain the request and its idempotency key for a later retry.
            }
        }
    }

    func resolvePending(jobID: String) async {
        do {
            pendingJobs = try await pendingJobStore.remove(jobID: jobID)
            persistenceError = nil
        } catch {
            persistenceError = "This pending trip could not be updated on this device."
        }
    }

    func reconcilePending(with remoteTrips: [SavedItinerary]) async {
        do {
            var recordsByID: [String: PendingJobRecord] = [:]
            for record in try await pendingJobStore.all() {
                recordsByID[record.jobID] = record
            }
            for trip in remoteTrips {
                switch trip.status {
                case .pending, .running:
                    if recordsByID[trip.jobId] == nil {
                        recordsByID[trip.jobId] = PendingJobRecord(
                            jobID: trip.jobId,
                            title: trip.displayTitle.isEmpty ? nil : trip.displayTitle,
                            createdAt: Self.parseDate(trip.createdAt) ?? Date()
                        )
                    }
                case .succeeded, .failed:
                    recordsByID.removeValue(forKey: trip.jobId)
                }
            }
            pendingJobs = try await pendingJobStore.replace(with: Array(recordsByID.values))
            persistenceError = nil
        } catch {
            persistenceError = "Pending trips could not be reconciled."
        }
    }

    func markLibraryChanged() {
        libraryRevision &+= 1
    }

    private func publishCache(_ snapshot: CompletedTripCacheSnapshot?) {
        cachedTrips = snapshot?.trips.filter { $0.archivedAt == nil } ?? []
        tripCacheRefreshedAt = snapshot?.refreshedAt
    }

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
