import SwiftUI

struct SettingsView: View {
    @ObservedObject var bridge: BridgeStore
    @State private var testing = false
    @State private var clearing = false
    var body: some View {
        VStack(spacing: 0) {
            HeaderStrip(title: "Settings", subtitle: "Bridge connection and trusted devices", online: bridge.reachable)
            ErrorBanner(bridge: bridge)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Bridge URL").font(.headline)
                        TextField("http://host:8180", text: $bridge.baseURL).commandField().keyboardType(.URL)
                        Text("Bridge token").font(.headline)
                        SecureField("X-Bridge-Token", text: $bridge.token).commandField()
                        Button(testing ? "Testing…" : "Test connection") {
                            Task { testing = true; await bridge.testConnection(); testing = false }
                        }.frame(minHeight: 44).buttonStyle(.borderedProminent).disabled(testing)
                        MonoOutput(text: bridge.health)
                    }.controlCard()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Trusted devices").font(.headline)
                            Spacer()
                            Button("Refresh") { Task { await refreshTrust() } }.frame(minHeight: 44)
                        }
                        if bridge.trust.values.filter(\.trusted).isEmpty {
                            Text("No trusted devices.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(bridge.trust.keys.sorted().filter { bridge.trust[$0]?.trusted == true }, id: \.self) { addr in
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(bridge.trust[addr]?.label ?? "")
                                    Text(addr).font(.caption.monospaced()).textSelection(.enabled)
                                }
                                Spacer()
                                Button("Remove", role: .destructive) { Task { await bridge.removeTrust(addr) } }
                                    .frame(minHeight: 44).buttonStyle(.bordered)
                            }
                        }
                    }.controlCard()
                    Button("Clear saved actions (\(bridge.actions.count))", role: .destructive) { clearing = true }
                        .frame(minHeight: 44).buttonStyle(.bordered)
                }.padding(12)
            }
        }.background(Color.black.opacity(0.92))
        .task { await refreshTrust() }
        .alert("Clear all saved actions?", isPresented: $clearing) {
            Button("Clear", role: .destructive) { bridge.clearActions() }
            Button("Cancel", role: .cancel) { }
        }
    }
    private func refreshTrust() async {
        do { try await bridge.refreshTrust() } catch { bridge.report(error) }
    }
}
