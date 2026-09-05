import SwiftUI
import AppKit

/// Where the heartbeat goes and the shared secret that authorises it.
///
/// Read from `~/.config/presence/config.json` rather than the environment —
/// a menubar app launched from Finder or launchd doesn't inherit a shell.
struct Config {
    let endpoint: URL
    let secret: String

    static func load() -> Config? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/presence/config.json")

        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
            let endpoint = json["endpoint"].flatMap(URL.init(string:)),
            let secret = json["secret"]
        else { return nil }

        return Config(endpoint: endpoint, secret: secret)
    }
}

@MainActor
final class PresenceModel: ObservableObject {
    /// Paced against the server's 300s staleness window: three beats fit
    /// inside it, so two can fail (flaky wifi, a suspended deploy) before the
    /// site says offline.
    ///
    /// Deliberately slow. Upstash's free tier bills per command, and the app
    /// reports sleep, wake and quit explicitly — so a faster beat would buy
    /// almost no accuracy while multiplying the monthly spend.
    private static let interval: TimeInterval = 60

    /// Idle long enough that I'm not at the desk, short enough to be honest.
    private static let afkAfter: TimeInterval = 5 * 60

    @Published private(set) var statusText = "Starting…"
    @Published private(set) var isOnline = false
    @Published var enabled = true {
        didSet { enabled ? start() : stop() }
    }

    private let config = Config.load()
    private var timer: Timer?

    init() {
        guard config != nil else {
            statusText = "No config at ~/.config/presence/config.json"
            return
        }
        start()
        observeSleep()
    }

    private func start() {
        beat()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in self.beat() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        send(body: ["offline": true], then: "Paused")
    }

    /// Sleeping the lid would otherwise leave a stale "online" for the rest of
    /// the TTL, so clear it on the way down and beat again on the way back up.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.send(body: ["offline": true], then: "Asleep") }
        }

        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in if self.enabled { self.beat() } }
        }
    }

    /// Seconds since the last keypress or mouse move. `hidSystemState` covers
    /// physical input only, so a long build or video playback still reads AFK.
    private var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .init(rawValue: ~0)!)
    }

    /// Localised name of the frontmost app. `NSWorkspace` gives us this without
    /// Accessibility permission — that's only needed for window titles.
    private var frontmostApp: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    private func beat() {
        let afk = idleSeconds > Self.afkAfter

        var body: [String: Any] = ["afk": afk]
        // Don't report an app while away — it's just whatever was open when
        // I walked off.
        if !afk, let app = frontmostApp { body["app"] = app }

        send(body: body, then: afk ? "Idle" : "Online")
    }

    private func send(body: [String: Any], then label: String) {
        guard let config else { return }

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // Shorter than the beat interval so a hung request can't overlap the
        // next one.
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                if error != nil {
                    self.statusText = "Unreachable"
                    self.isOnline = false
                } else if code == 401 {
                    self.statusText = "Rejected — check the secret"
                    self.isOnline = false
                } else if (200..<300).contains(code) {
                    self.statusText = label
                    self.isOnline = label == "Online" || label == "Idle"
                } else {
                    self.statusText = "Error \(code)"
                    self.isOnline = false
                }
            }
        }.resume()
    }
}

@main
struct PresenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PresenceModel()

    var body: some Scene {
        MenuBarExtra("Presence", systemImage: model.isOnline ? "circle.fill" : "circle") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Presence")
                    .font(.headline)

                Text(model.statusText)
                    .foregroundStyle(model.isOnline ? .green : .secondary)

                Divider()

                Toggle("Broadcasting", isOn: $model.enabled)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding()
            .frame(width: 220)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftPM executables default to a regular app — no dock icon wanted here.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Quitting should read as offline on the site immediately, not 90s later.
    func applicationWillTerminate(_ notification: Notification) {
        guard let config = Config.load() else { return }

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["offline": true])

        // Termination won't wait on an async task, so block briefly on this one.
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 2)
    }
}
