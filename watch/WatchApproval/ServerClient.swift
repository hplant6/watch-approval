import Foundation

/// HTTP client for communicating with the Watch Approval relay server.
actor ServerClient {

    static let shared = ServerClient()

    /// Base URL of the relay server. Change this to your server's address.
    /// For local testing on the same network, use your desktop's LAN IP.
    /// For production, use a public URL or VPS address.
    private let baseURL: String = {
        if let env = ProcessInfo.processInfo.environment["WATCH_SERVER_URL"] {
            return env
        }
        // Default: desktop on local network. Replace with your server's IP.
        return "http://192.168.1.100:8420"
    }()

    /// Shared secret for authentication, if configured.
    private let secret: String = {
        ProcessInfo.processInfo.environment["WATCH_SECRET"] ?? ""
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    // MARK: - API Calls

    /// Register the device token for push notifications.
    func registerDevice(token: String) async {
        let body = ["device_token": token]
        let result = await post(path: "/api/register", body: body)
        if result {
            print("[WatchApproval] Device registered with server")
        } else {
            print("[WatchApproval] Failed to register device")
        }
    }

    /// Send an approval/deny decision for a request.
    func respond(requestId: String, decision: String) async -> Bool {
        let body = ["decision": decision]
        return await post(path: "/api/respond/\(requestId)", body: body)
    }

    // MARK: - HTTP Helpers

    private func post(path: String, body: [String: String]) async -> Bool {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            print("[WatchApproval] Invalid URL: \(baseURL)\(path)")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            print("[WatchApproval] Request failed: \(error.localizedDescription)")
            return false
        }
    }
}
