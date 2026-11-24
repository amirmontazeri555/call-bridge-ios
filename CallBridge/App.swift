import SwiftUI

// call-bridge iOS: connects to the Windows relay (ws://<ip>:9877)
// and shows incoming call events from the Android phone.

struct CallEvent: Codable {
    let event: String
    let dir: String?
    let number: String?
    let state: String?
    let id: String?
}

final class CallStore: ObservableObject {
    @Published var serverIP: String = UserDefaults.standard.string(forKey: "server_ip") ?? ""
    @Published var status: String = "متصل نیست"
    @Published var connected = false
    @Published var incomingNumber: String? = nil
    @Published var events: [String] = []

    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?

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
        markDown()
    }

    private func markDown() {
        connected = false
        status = "متصل نیست"
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
        let display: String
        if let data = text.data(using: .utf8),
           let ev = try? JSONDecoder().decode(CallEvent.self, from: data) {
            if ev.event == "CALL_ADDED", ev.state == "RINGING" {
                incomingNumber = ev.number
            }
            if ev.state == "DISCONNECTED" {
                incomingNumber = nil
            }
            display = "\(ev.event) \(ev.number ?? "") \(ev.state ?? "")"
        } else {
            display = text
        }
        events.insert("\(Date().formatted(date: .omitted, time: .standard)) — \(display)", at: 0)
        if events.count > 50 { events.removeLast(events.count - 50) }
    }
}

struct ContentView: View {
    @StateObject private var store = CallStore()

    var body: some View {
        VStack(spacing: 16) {
            if let num = store.incomingNumber {
                VStack(spacing: 8) {
                    Text("📞 تماس ورودی")
                        .font(.largeTitle).bold()
                    Text(num)
                        .font(.title)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(Color.red.opacity(0.85))
                .foregroundStyle(.white)
                .cornerRadius(20)
                .padding(.horizontal)
            }
            Text(store.status)
                .foregroundStyle(store.connected ? .green : .secondary)

            HStack {
                TextField("IP ویندوز، مثل 192.168.1.5", text: $store.serverIP)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Button("اتصال") { store.connect() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            List(store.events, id: \.self) { Text($0).font(.caption) }
            if store.events.isEmpty {
                Text("هنوز رویدادی نرسیده.\nروی ویندوز: python relay.py")
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
