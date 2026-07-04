import SwiftUI

/// Main watch interface showing connection status and server info.
struct ContentView: View {
    @State private var serverURL: String = ""
    @State private var isRegistered = false
    @State private var lastCheck = "—"

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Header
                Image(systemName: isRegistered ? "checkmark.icloud" : "icloud.slash")
                    .font(.title)
                    .foregroundColor(isRegistered ? .green : .red)
                    .padding(.top, 8)

                Text("Watch Approval")
                    .font(.headline)

                Text(isRegistered ? "Connected" : "Not Connected")
                    .font(.caption)
                    .foregroundColor(isRegistered ? .green : .secondary)

                Divider()

                // Server info
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(serverURL.isEmpty ? "Using default" : serverURL)
                        .font(.caption2)
                        .lineLimit(2)

                    Text("Last check: \(lastCheck)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                Divider()

                // Quick test button
                Button(action: checkConnection) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Check Connection")
                    }
                }
                .buttonStyle(.bordered)

                // Instructions
                Text("Notifications will appear here when Claude Code needs approval.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .onAppear {
            loadConfig()
            checkConnection()
        }
    }

    private func loadConfig() {
        if let url = ProcessInfo.processInfo.environment["WATCH_SERVER_URL"] {
            serverURL = url
        } else {
            serverURL = "192.168.1.100:8420"
        }
    }

    private func checkConnection() {
        Task {
            let ok = await checkServer()
            await MainActor.run {
                isRegistered = ok
                lastCheck = ok ? "OK" : "Failed"
            }
        }
    }

    private func checkServer() async -> Bool {
        guard let url = URL(string: "\(serverURL.hasPrefix("http") ? serverURL : "http://\(serverURL)")/health") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return false
            }
            return true
        } catch {
            return false
        }
    }
}

#Preview {
    ContentView()
}
