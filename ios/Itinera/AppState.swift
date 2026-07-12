import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    let apiClient: APIClient

    @Published private(set) var pendingJobs: [PendingJobRecord] = []
    @Published private(set) var persistenceError: String?
    @Published private(set) var libraryRevision = 0

    private let pendingJobStore: PendingJobStore
    private let pendingSubmissionStore: PendingSubmissionStore

    init(
        apiClient: APIClient,
        pendingJobStore: PendingJobStore,
        pendingSubmissionStore: PendingSubmissionStore
    ) {
        self.apiClient = apiClient
        self.pendingJobStore = pendingJobStore
        self.pendingSubmissionStore = pendingSubmissionStore
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
            pendingSubmissionStore: .live()
        )
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

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
