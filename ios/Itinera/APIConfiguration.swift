import Foundation

enum APIConfigurationError: LocalizedError, Equatable, Sendable {
    case missingBaseURL
    case invalidBaseURL

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            "This build is missing its Itinera service address."
        case .invalidBaseURL:
            "This build has an invalid Itinera service address."
        }
    }
}

struct APIConfiguration: Sendable {
    static let infoPlistKey = "ItineraAPIBaseURL"
    static let debugEnvironmentKey = "ITINERA_API_BASE_URL"

    let baseURL: URL
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval

    init(
        baseURL: URL,
        requestTimeout: TimeInterval = 15,
        resourceTimeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }

    static func live(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> APIConfiguration {
        #if DEBUG
        if let override = environment[debugEnvironmentKey],
           let url = validatedURL(override, allowsInsecureLocalhost: true) {
            return APIConfiguration(baseURL: url)
        }
        #endif

        return try configured(
            baseURLValue: bundle.object(forInfoDictionaryKey: infoPlistKey) as? String,
            allowsInsecureLocalhost: _isDebugAssertConfiguration()
        )
    }

    static func configured(
        baseURLValue: String?,
        allowsInsecureLocalhost: Bool
    ) throws -> APIConfiguration {
        guard let baseURLValue else {
            throw APIConfigurationError.missingBaseURL
        }
        guard let url = validatedURL(
            baseURLValue,
            allowsInsecureLocalhost: allowsInsecureLocalhost
        ) else {
            throw APIConfigurationError.invalidBaseURL
        }
        return APIConfiguration(baseURL: url)
    }

    func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        return configuration
    }

    private static func validatedURL(
        _ rawValue: String,
        allowsInsecureLocalhost: Bool
    ) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        if url.scheme == "https" { return url }
        if allowsInsecureLocalhost,
           url.scheme == "http",
           ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "") {
            return url
        }
        return nil
    }
}
