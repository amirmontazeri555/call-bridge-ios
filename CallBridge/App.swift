import SwiftUI
import CallKit

// TwinCall iOS: connects to the Windows relay (ws://<ip>:9877),
// reports incoming SIM calls as real CallKit calls, and sends
// ANSWER/END back over the same WS (relay forwards via UDP to Android).

struct CallEvent: Codable {
    let event: String
    let dir: String?
    let number: String?
    let state: String?
    let id: String?
    let sim: String? // reserved for dual-SIM: "sim1"/"sim2" label from Android
}

// MARK: - CallKit bridge

final class CallKitBridge: NSObject, CXProviderDelegate {
    let provider: CXProvider
    let callController = CXCallController()
    var onCommand: ((String) -> Void)? // sends JSON over WS to the relay
    var onLog: ((String) -> Void)?    // surfaces errors in the app UI

    private var activeCallUUID: UUID?

    override init() {
        let cfg = CXProviderConfiguration(localizedName: "TwinCall")
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.phoneNumber]
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func reportIncoming(number: String, sim: String?) {
        // one live bridge-call at a time; end any previous one
        if let uuid = activeCallUUID {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
            activeCallUUID = nil
        }
        let uuid = UUID()
        activeCallUUID = uuid
        let handle = CXHandle(type: .phoneNumber, value: number)
        let update = CXCallUpdate()
        update.remoteHandle = handle
        update.hasVideo = false
        if let sim, !sim.isEmpty {
            update.localizedCallerName = sim // e.g. "سیم ۱ — ۰۹۱۲…"
        }
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                self?.onLog?("⚠️ CallKit: \(error.localizedDescription)")
            }
        }
    }

    func endActive(reason: CXCallEndedReason = .remoteEnded) {
        if let uuid = activeCallUUID {
            provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
            activeCallUUID = nil
        }
    }

    // MARK: CXProviderDelegate — user taps CallKit UI

    func providerDidReset(_ provider: CXProvider) {
        activeCallUUID = nil
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        onCommand?(Self.json("ANSWER"))
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        onCommand?(Self.json("END"))
        endActive(reason: .declinedElsewhere)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAnswerCallAction) {
        onCommand?(Self.json("MISSED"))
        action.fulfill()
    }

    private static func json(_ cmd: String) -> String {
        "{\"cmd\":\"\(cmd)\"}"
    }
}

// MARK: - Store

final class CallStore: ObservableObject {
    @Published var serverIP: String = UserDefaults.standard.string(forKey: "server_ip") ?? ""
    @Published var status: String = "متصل نیست"
    @Published var connected = false
    @Published var events: [String] = []

    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private let bridge = CallKitBridge()

    init() {
        bridge.onCommand = { [weak self] json in
            self?.sendRaw(json)
        }
        bridge.onLog = { [weak self] line in
            self?.log(line)
        }
    }

    func connect() {
        disconnect()
        let ip = serverIP.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { status = "آدرس سرور را وارد کن"; return }
        guard let url = URL(string: "ws://\(ip):9877") else { status = "آدرس نامعتبر"; return }
        UserDefaults.standard.set(ip, forKey: "server_ip")
        status = "در حال اتصال به \(ip)…"
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.task?.sendPing { error in
                if error != nil { DispatchQueue.main.async { self?.markDown() } }
            }
        }
    }

    func disconnect() {
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        bridge.endActive()
        markDown()
    }

    private func markDown() {
        connected = false
        status = "متصل نیست"
    }

    private func sendRaw(_ text: String) {
        task?.send(.string(text)) { error in
            if let error { print("WS send failed: \(error)") }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async { self.markDown() }
            case .success(let msg):
                if case .string(let text) = msg {
                    DispatchQueue.main.async { self.handle(text) }
                }
                self.receive()
            }
        }
    }

    private func handle(_ text: String) {
        connected = true
        status = "متصل ✅"
        if let data = text.data(using: .utf8),
           let ev = try? JSONDecoder().decode(CallEvent.self, from: data) {
            if ev.event == "CALL_ADDED", ev.state == "RINGING", let num = ev.number {
                bridge.reportIncoming(number: num, sim: ev.sim)
            }
            if ev.state == "DISCONNECTED" || ev.state == "ACTIVE" {
                bridge.endActive()
            }
            log("\(ev.event) \(ev.number ?? "") \(ev.state ?? "") \(ev.sim ?? "")")
        } else {
            log(text)
        }
    }

    private func log(_ line: String) {
        events.insert("\(Date().formatted(date: .omitted, time: .standard)) — \(line)", at: 0)
        if events.count > 50 { events.removeLast(events.count - 50) }
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var store = CallStore()

    var body: some View {
        VStack(spacing: 16) {
            Text(store.status)
                .foregroundStyle(store.connected ? .green : .secondary)

            HStack {
                TextField("IP رله، مثل 192.168.100.42", text: $store.serverIP)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Button("اتصال") { store.connect() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            List(store.events, id: \.self) { Text($0).font(.caption) }
            if store.events.isEmpty {
                Text("تماس‌ها به‌صورت CallKit واقعی زنگ می‌زنند.\nروی ویندوز: python relay.py")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
        }
        .padding(.top)
    }
}

@main
struct CallBridgeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
