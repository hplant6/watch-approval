import Foundation

/// HTTP client for the Watch Approval relay server.
///
/// The server URL and shared secret are configured on-device (ContentView writes
/// them to UserDefaults) — that on-device config is the whole point of putting this
/// on the phone instead of the watch. Falls back to an env var, then a LAN default.
actor ServerClient {

    static let shared = ServerClient()

    private var baseURL: String {
        if let u = UserDefaults.standard.string(forKey: "serverURL"), !u.isEmpty {
            return u.hasPrefix("http") ? u : "http://\(u)"
        }
        if let env = ProcessInfo.processInfo.environment["WATCH_SERVER_URL"] { return env }
        return "http://192.168.1.100:8420" // ← change in-app, or leave for LAN testing
    }

    private var secret: String {
        UserDefaults.standard.string(forKey: "sharedSecret")
            ?? ProcessInfo.processInfo.environment["WATCH_SECRET"]
            ?? ""
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: - API

    /// Register this device's APNs token so the relay can push to it.
    func registerDevice(token: String) async {
        let ok = await post(path: "/api/register", body: ["device_token": token])
        print(ok ? "[Approvals] Device registered with server" : "[Approvals] Device registration failed")
    }

    /// Send an approve/deny decision for a pending request.
    @discardableResult
    func respond(requestId: String, decision: String) async -> Bool {
        await post(path: "/api/respond/\(requestId)", body: ["decision": decision])
    }

    /// Lightweight reachability check for the config screen.
    func health() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func post(path: String, body: [String: String]) async -> Bool {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            print("[Approvals] Invalid URL: \(baseURL)\(path)")
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !secret.isEmpty {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
        } catch {
            print("[Approvals] Request to \(path) failed: \(error.localizedDescription)")
            return false
        }
    }
}
