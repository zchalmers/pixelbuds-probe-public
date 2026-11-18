import SwiftUI

struct ContentView: View {
    @StateObject private var bridge = BridgeStore()
    @StateObject private var probe = Probe()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            BudsView(bridge: bridge)
                .tabItem { Label("Buds", systemImage: "earbuds") }
            ExploreView(bridge: bridge, probe: probe)
                .tabItem { Label("Explore", systemImage: "dot.radiowaves.left.and.right") }
            SettingsView(bridge: bridge)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .preferredColorScheme(.dark)
        .tint(.cyan)
        .alert("First write to this device", isPresented: Binding(
            get: { bridge.pendingWrite != nil },
            set: { if !$0 { bridge.pendingWrite = nil } }
        )) {
            if let pending = bridge.pendingWrite {
                Button("Trust and write", role: .destructive) {
                    Task { await bridge.confirm(pending, probe: probe) }
                }
            }
            Button("Cancel", role: .cancel) { bridge.pendingWrite = nil }
        } message: {
            Text("Trust \(bridge.pendingWrite?.action.addr ?? "device") on the bridge and retry this write once?")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { probe.stopScan() }
        }
    }
}

struct HeaderStrip: View {
    let title: String
    let subtitle: String
    var online = false
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(online ? Color.green : Color.gray).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
    }
}
struct ErrorBanner: View {
    @ObservedObject var bridge: BridgeStore
    var body: some View {
        if let error = bridge.error {
            HStack(alignment: .top) {
                Text(error).font(.caption).textSelection(.enabled)
                Spacer()
                Button("Dismiss") { bridge.error = nil }.frame(minHeight: 44)
            }
            .foregroundStyle(.red).padding(12).background(Color.red.opacity(0.08))
        }
    }
}
struct MonoOutput: View {
    let text: String
    var body: some View {
        Text(text.isEmpty ? "No output yet" : text)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(Color.white.opacity(0.04))
    }
}
extension View {
    func controlCard() -> some View {
        self.padding(12).background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    func commandField() -> some View {
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
            .font(.system(size: 13, design: .monospaced)).textFieldStyle(.roundedBorder)
    }
}

struct BudsView: View {
    @ObservedObject var bridge: BridgeStore
    @State private var raw = "{\"args\":[\"get\",\"anc\"]}"
    private let bands = ["low_bass", "bass", "mid", "treble", "upper_treble"]
    private var summary: String {
        guard let battery = bridge.status?.parsed.battery, !battery.isEmpty else {
            return bridge.reachable ? "Bridge reachable • battery unavailable" : "Bridge not checked or unreachable"
        }
        return "Bridge reachable • " + ["left", "right", "case"].map {
            "\($0.capitalized) \(battery[$0].map { "\($0.percent)%" } ?? "—")"
        }.joined(separator: " · ")
    }
    var body: some View {
        VStack(spacing: 0) {
            HeaderStrip(title: "Pixel Buds", subtitle: summary, online: bridge.reachable)
            ErrorBanner(bridge: bridge)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button { Task { await bridge.refresh() } } label: {
                        HStack {
                            Label(bridge.busy ? "Working…" : "Refresh", systemImage: "arrow.clockwise")
                            Spacer()
                            if bridge.busy { ProgressView() }
                        }.frame(minHeight: 44)
                    }.buttonStyle(.borderedProminent).disabled(bridge.busy)
                    batteryCard
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Noise control").font(.headline)
                        Picker("Noise control", selection: Binding(get: { bridge.anc }, set: { mode in
                            Task { await bridge.command(["set", "anc", mode]) }
                        })) {
                            ForEach(["off", "active", "aware", "adaptive"], id: \.self) { Text($0.capitalized).tag($0) }
                        }.pickerStyle(.segmented).frame(minHeight: 44)
                        Toggle("Multipoint", isOn: Binding(get: { bridge.multipoint }, set: { enabled in
                            Task { await bridge.command(["set", "multipoint", String(enabled)]) }
                        })).frame(minHeight: 44)
                        if bridge.status?.parsed.multipoint == nil { Text("Multipoint state unavailable").font(.caption).foregroundStyle(.secondary) }
                        Toggle("On-head detection", isOn: Binding(get: { bridge.ohd }, set: { enabled in
                            Task { await bridge.command(["set", "ohd", String(enabled)]) }
                        })).frame(minHeight: 44)
                        if bridge.status?.ohd == nil { Text("On-head state unavailable").font(.caption).foregroundStyle(.secondary) }
                    }.controlCard().disabled(bridge.busy)
                    eqCard
                    infoCard
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Raw command").font(.headline)
                        TextField("{\"args\":[…]}", text: $raw, axis: .vertical).commandField()
                        Button("Run command") { Task { await bridge.rawCommand(raw) } }
                            .frame(minHeight: 44).buttonStyle(.borderedProminent).disabled(bridge.busy)
                        Text("Response, verbatim").font(.caption).foregroundStyle(.secondary)
                        MonoOutput(text: bridge.output)
                    }.controlCard()
                }.padding(12)
            }
        }.background(Color.black.opacity(0.92))
        .task { await bridge.testConnection(); await bridge.refresh() }
    }
    private var batteryCard: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(["left", "right", "case"], id: \.self) { key in
                VStack(spacing: 8) {
                    Text(key.capitalized).font(.subheadline)
                    Text(bridge.status?.parsed.battery?[key].map { "\($0.percent)%" } ?? "—")
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    Text(bridge.status?.parsed.battery?[key]?.state ?? "Unknown")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            }
        }.controlCard()
    }
    private var eqCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Equalizer").font(.headline)
            ForEach(0..<5, id: \.self) { index in
                VStack(spacing: 0) {
                    HStack {
                        Text(bands[index]).font(.caption.monospaced())
                        Spacer()
                        Text(String(format: "%+.1f dB", bridge.eq[index])).font(.caption.monospaced())
                    }
                    Slider(value: $bridge.eq[index], in: -6...6, step: 0.5)
                        .frame(minHeight: 44).accessibilityLabel(bands[index])
                }
            }
            Button("Apply EQ") {
                let values = bridge.eq.map { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0) }
                Task { await bridge.command(["set", "eq"] + values) }
            }.frame(minHeight: 44).buttonStyle(.borderedProminent)
        }.controlCard().disabled(bridge.busy)
    }
    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gesture control").font(.headline)
            if let gestures = bridge.status?.parsed.gesture_control, !gestures.isEmpty {
                ForEach(gestures.keys.sorted(), id: \.self) { key in Text("\(key): \(gestures[key] ?? "")").font(.caption.monospaced()) }
            } else { Text("Unavailable").foregroundStyle(.secondary) }
            Text("Firmware").font(.headline)
            ForEach(["left", "right", "case"], id: \.self) { key in
                Text("\(key.capitalized): \(bridge.status?.parsed.software?[key].map { "\($0.version) (\($0.build))" } ?? "Unavailable")")
                    .font(.caption.monospaced())
            }
        }.frame(maxWidth: .infinity, alignment: .leading).controlCard()
    }
}
