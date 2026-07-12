import Foundation

enum APIError: LocalizedError {
    case badStatus(Int, String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body):
            return "Server error (\(code)): \(body)"
        case .generationFailed(let message):
            return message
        }
    }
}

struct APIClient {
    static let shared = APIClient()

    // Override with your deployed backend URL for TestFlight/App Store builds.
    var baseURL = URL(string: "http://localhost:8000")!

    private var deviceID: String {
        let key = "itinera.device-id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError.badStatus(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try decoder.decode(T.self, from: data)
    }

    func createItinerary(_ payload: GenerateItineraryRequest) async throws -> JobAccepted {
        let body = try encoder.encode(payload)
        return try await send(request("/api/itineraries", method: "POST", body: body), as: JobAccepted.self)
    }

    func jobStatus(_ jobID: String) async throws -> JobStatusResponse {
        try await send(request("/api/itineraries/\(jobID)"), as: JobStatusResponse.self)
    }

    func savedItineraries() async throws -> [SavedItinerary] {
        try await send(request("/api/itineraries"), as: [SavedItinerary].self)
    }

    /// Polls the job until it succeeds or fails.
    func awaitItinerary(_ jobID: String, pollInterval: Duration = .seconds(2)) async throws -> Itinerary {
        while true {
            let status = try await jobStatus(jobID)
            switch status.status {
            case .succeeded:
                if let itinerary = status.result { return itinerary }
                throw APIError.generationFailed("Job succeeded but returned no itinerary")
            case .failed:
                throw APIError.generationFailed(status.error ?? "Generation failed")
            case .pending, .running:
                try await Task.sleep(for: pollInterval)
            }
        }
    }
}
