import SwiftUI
import UIKit

/// On-device configuration + status. This screen is why the app lives on the phone:
/// you can set the relay URL/secret and see the device token without squinting at a watch.
struct ContentView: View {
    @AppStorage("serverURL") private var serverURL: String = ""
    @AppStorage("sharedSecret") private var sharedSecret: String = ""
    @AppStorage("deviceToken") private var deviceToken: String = ""

    @State private var status: Status = .unknown
    @State private var checking = false

    enum Status { case unknown, ok, failed
        var color: Color { self == .ok ? .green : (self == .failed ? .red : .secondary) }
        var label: String { self == .ok ? "Connected" : (self == .failed ? "Not reachable" : "—") }
        var icon: String { self == .ok ? "checkmark.icloud.fill" : (self == .failed ? "icloud.slash.fill" : "icloud") }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: status.icon).foregroundStyle(status.color)
                        Text(status.label).foregroundStyle(status.color)
                        Spacer()
                        if checking { ProgressView() }
                    }
                } header: { Text("Relay Status") }

                Section {
                    TextField("http://192.168.1.100:8420", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Shared secret (optional)", text: $sharedSecret)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Your Cathode machine's address. On your home Wi‑Fi use its LAN IP; add Tailscale later to reach it from anywhere.")
                }

                Section {
                    Button {
                        Task { await checkConnection() }
                    } label: {
                        Label("Test Connection", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        UIApplication.shared.registerForRemoteNotifications()
                        if !deviceToken.isEmpty {
                            Task { await ServerClient.shared.registerDevice(token: deviceToken) }
                        }
                    } label: {
                        Label("Re-register for Notifications", systemImage: "bell.badge")
                    }
                }

                Section {
                    if deviceToken.isEmpty {
                        Text("Not yet registered")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(deviceToken)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                } header: {
                    Text("APNs Device Token")
                } footer: {
                    Text("Sent to the relay on launch. Long‑press to copy for manual testing.")
                }
            }
            .navigationTitle("Cathode Approvals")
        }
        .task { await checkConnection() }
    }

    private func checkConnection() async {
        checking = true
        let ok = await ServerClient.shared.health()
        status = ok ? .ok : .failed
        checking = false
    }
}

#Preview {
    ContentView()
}
