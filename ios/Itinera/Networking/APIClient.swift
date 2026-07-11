import Foundation

enum APIError: LocalizedError {
    case badBaseURL
    case rateLimited
    case server(String)
    case network

    var errorDescription: String? {
        switch self {
        case .badBaseURL:
            return "The server address is invalid. Check it in About > Developer."
        case .rateLimited:
            return "You've hit the hourly limit. Please try again a little later."
        case .server(let message):
            return message
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        }
    }
}

struct APIClient {
    /// Runtime override (About > Developer) wins, then the Info.plist value,
    /// then localhost for development.
    static var baseURL: URL {
        let override = UserDefaults.standard.string(forKey: "apiBaseURL") ?? ""
        if !override.isEmpty, let url = URL(string: override) {
            return url
        }
        if let configured = Bundle.main.object(forInfoDictionaryKey: "ItineraAPIBaseURL") as? String,
           let url = URL(string: configured) {
            return url
        }
        return URL(string: "http://localhost:5000")!
    }

    func generateItinerary(_ request: GenerateItineraryRequest) async throws -> Itinerary {
        try await post(path: "api/generate-itinerary", body: request)
    }

    private func post<Body: Codable, Response: Codable>(
        path: String,
        body: Body
    ) async throws -> Response {
        var urlRequest = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 180
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw APIError.network
        }

        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            throw APIError.rateLimited
        }

        let envelope: APIEnvelope<Response>
        do {
            envelope = try JSONDecoder().decode(APIEnvelope<Response>.self, from: data)
        } catch {
            throw APIError.server("The server returned an unexpected response.")
        }

        guard envelope.success, let payload = envelope.data else {
            throw APIError.server(envelope.error ?? "The server couldn't complete the request.")
        }
        return payload
    }
}
