import SwiftUI
import CallKit
import UserNotifications
import AVFoundation
import AudioToolbox

// TwinCall iOS: connects to the Windows relay (ws://<ip>:9877) and reports
// incoming SIM calls. CallKit first (works with a paid dev account);
// on entitlement error -> fallback: app-placed ringing + lock-screen
// notification with Answer/Decline actions. Commands go back over WS.

struct CallEvent: Codable {
    let event: String
    let dir: String?
    let number: String?
    let state: String?
    let id: String?
    let sim: String? // dual-SIM label from Android, e.g. "سیم ۱"
}

// MARK: - Ringer (fallback sound + vibration)

final class Ringer: NSObject {
    private var player: AVAudioPlayer?
    private var vibeTimer: Timer?

    func start() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        // generate a ring tone programmatically (no asset needed)
        player = makeTonePlayer()
        player?.numberOfLoops = -1
        player?.play()
        vibeTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        vibeTimer?.invalidate()
        vibeTimer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func makeTonePlayer() -> AVAudioPlayer? {
        // two-tone ring pattern, 1.5s loop, generated in memory
        let sampleRate = 22050.0
        let dur = 1.5
        let n = Int(sampleRate * dur)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let f = (Int(t / 0.4) % 2 == 0) ? 440.0 : 480.0 // alternating tones
            let env = (t.truncatingRemainder(dividingBy: 0.4) < 0.3) ? 1.0 : 0.0 // pause between bursts
            let wave = Float(sin(2.0 * Double.pi * f * t))
            samples[i] = Float(env) * 0.25 * wave
        }
        var data = Data()
        // minimal WAV header (PCM 16-bit mono)
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); le32(UInt32(36 + n * 2)); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); le32(16); le16(1); le16(1); le32(UInt32(sampleRate))
        le32(UInt32(sampleRate) * 2); le16(2); le16(16)
        data.append(contentsOf: "data".utf8); le32(UInt32(n * 2))
        for s in samples { le16(UInt16(Int16(max(-1, min(1, s))) * Int16(Int16.max))) }
        return try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
    }
}

// MARK: - Incoming call handling (CallKit + fallback)

final class IncomingCallCenter: NSObject, CXProviderDelegate, UNUserNotificationCenterDelegate {
    let provider = CXProvider(configuration: {
        let cfg = CXProviderConfiguration(localizedName: "TwinCall")
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.phoneNumber]
        return cfg
    }())
    var onCommand: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    var onFallbackRing: (() -> Void)?
    var onFallbackStop: (() -> Void)?

    private var activeCallUUID: UUID?
    var currentNumber: String?
    private var callKitOK = false // flips true after one successful report

    override init() {
        super.init()
        provider.setDelegate(self, queue: nil)
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: incoming event

    func reportIncoming(number: String, sim: String?) {
        currentNumber = number
        let uuid = UUID()
        activeCallUUID = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        update.hasVideo = false
        if let sim, !sim.isEmpty { update.localizedCallerName = sim }
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            guard let self else { return }
            if let error {
                self.onLog?("⚠️ CallKit: \(error.localizedDescription) — fallback")
                self.callKitOK = false
                self.activeCallUUID = nil
                self.fallbackNotify(number: number, sim: sim)
                self.onFallbackRing?()
            } else {
                self.callKitOK = true
            }
        }
    }

    func eventEnded() {
        if callKitOK, let uuid = activeCallUUID {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        }
        activeCallUUID = nil
        stopFallback()
    }

    // MARK: fallback: notification + in-app ringing

    private func fallbackNotify(number: String, sim: String?) {
        let content = UNMutableNotificationContent()
        content.title = "📞 تماس ورودی"
        content.body = sim?.isEmpty == false ? "\(number) — \(sim!)" : number
        content.sound = .default
        content.categoryIdentifier = "INCOMING"
        content.userInfo = ["number": number]
        let req = UNNotificationRequest(identifier: "incoming", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func stopFallback() {
        onFallbackStop?()
        let nc = UNUserNotificationCenter.current()
        nc.removeDeliveredNotifications(withIdentifiers: ["incoming"])
        nc.removeAllPendingNotificationRequests()
    }

    // MARK: notification actions (Answer / Decline)

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "ANSWER" {
            onCommand?(commandJSON("ANSWER"))
            stopFallback()
        } else if response.actionIdentifier == "END"
                    || response.actionIdentifier == UNNotificationDismissActionIdentifier {
            onCommand?(commandJSON("END"))
            stopFallback()
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    static func registerCategories() {
        let answer = UNNotificationAction(identifier: "ANSWER", title: "پاسخ")
        let end = UNNotificationAction(identifier: "END", title: "قطع")
        let cat = UNNotificationCategory(identifier: "INCOMING", actions: [answer, end], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    // MARK: CXProviderDelegate (used when CallKit works)

    func providerDidReset(_ provider: CXProvider) { activeCallUUID = nil }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        onCommand?(commandJSON("ANSWER"))
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        onCommand?(commandJSON("END"))
        action.fulfill()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAnswerCallAction) {
        onCommand?(commandJSON("MISSED"))
        action.fulfill()
    }

    private func commandJSON(_ cmd: String) -> String {
        "{\"cmd\":\"\(cmd)\",\"number\":\"\(currentNumber ?? "")\"}"
    }
}

// MARK: - Store

final class CallStore: ObservableObject {
    @Published var serverIP: String = UserDefaults.standard.string(forKey: "server_ip") ?? ""
    @Published var status: String = "متصل نیست"
    @Published var connected = false
    @Published var events: [String] = []
    @Published var incomingNumber: String? = nil // in-app ringing card (fallback)

    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private let center = IncomingCallCenter()
    private let ringer = Ringer()

    init() {
        center.onCommand = { [weak self] json in self?.sendRaw(json) }
        center.onLog = { [weak self] line in self?.log(line) }
        center.onFallbackRing = { [weak self] in
            self?.incomingNumber = self?.center.currentNumber
            self?.ringer.start()
        }
        center.onFallbackStop = { [weak self] in
            self?.incomingNumber = nil
            self?.ringer.stop()
        }
        IncomingCallCenter.registerCategories()
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
        center.eventEnded()
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
                center.reportIncoming(number: num, sim: ev.sim)
            }
            if ev.state == "DISCONNECTED" || ev.state == "ACTIVE" {
                center.eventEnded()
            }
            log("\(ev.event) \(ev.number ?? "") \(ev.state ?? "") \(ev.sim ?? "")")
        } else {
            log(text)
        }
    }

    // in-app fallback buttons
    func answerIncoming() {
        sendRaw("{\"cmd\":\"ANSWER\",\"number\":\"\(center.currentNumber ?? "")\"}")
        incomingNumber = nil
        ringer.stop()
    }

    func endIncoming() {
        sendRaw("{\"cmd\":\"END\",\"number\":\"\(center.currentNumber ?? "")\"}")
        incomingNumber = nil
        ringer.stop()
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
            if let num = store.incomingNumber {
                VStack(spacing: 12) {
                    Text("📞 تماس ورودی").font(.largeTitle).bold()
                    Text(num).font(.title).textSelection(.enabled)
                    HStack(spacing: 24) {
                        Button {
                            store.answerIncoming()
                        } label: {
                            Text("پاسخ").font(.title2).bold()
                                .frame(width: 100, height: 60)
                                .background(Color.green)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                        Button {
                            store.endIncoming()
                        } label: {
                            Text("قطع").font(.title2).bold()
                                .frame(width: 100, height: 60)
                                .background(Color.red)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    }
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
                TextField("IP رله، مثل 192.168.100.42", text: $store.serverIP)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Button("اتصال") { store.connect() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            List(store.events, id: \.self) { Text($0).font(.caption) }
            if store.events.isEmpty {
                Text("تماس‌ها زنگ می‌خورند (CallKit یا اعلان).\nروی ویندوز: python relay.py")
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
