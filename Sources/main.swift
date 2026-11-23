import SwiftUI
import AppKit

// MARK: - Model

struct Window { let percent: Double; let resetsAt: Date? }
struct Usage { let plan: String; let fiveHour: Window?; let sevenDay: Window? }

enum UsageError: Error {
    case noCredentials, expired, network
    var message: String {
        switch self {
        case .noCredentials: return "Not signed in. Run Claude Code and log in."
        case .expired: return "Session expired. Open Claude Code to refresh."
        case .network: return "Can't reach Anthropic."
        }
    }
}

// MARK: - Fetch (token read from Claude Code's keychain item; never stored or logged)

func readCredentials() -> (token: String, plan: String)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else { return nil }
    return (token, (oauth["subscriptionType"] as? String) ?? "unknown")
}

func parseWindow(_ any: Any?) -> Window? {
    guard let d = any as? [String: Any], let u = d["utilization"] as? Double else { return nil }
    var date: Date?
    if let s = d["resets_at"] as? String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        date = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
    return Window(percent: u, resetsAt: date)
}

func fetchUsage() async throws -> Usage {
    guard let c = readCredentials() else { throw UsageError.noCredentials }
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.timeoutInterval = 15
    req.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          let http = resp as? HTTPURLResponse else { throw UsageError.network }
    if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.expired }
    guard http.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.network }
    return Usage(plan: c.plan.capitalized, fiveHour: parseWindow(json["five_hour"]), sevenDay: parseWindow(json["seven_day"]))
}

// MARK: - State

@MainActor final class Store: ObservableObject {
    @Published var usage: Usage?
    @Published var error: UsageError?
    var onChange: (() -> Void)?

    func refresh() {
        Task {
            do { usage = try await fetchUsage(); error = nil }
            catch { self.error = (error as? UsageError) ?? .network }
            onChange?()
        }
    }
}

// MARK: - UI

func resetText(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = max(0, Int(d.timeIntervalSinceNow))
    let h = s / 3600, m = (s % 3600) / 60
    if h >= 24 { return "resets in \(h / 24)d \(h % 24)h" }
    return h > 0 ? "resets in \(h)h \(m)m" : "resets in \(m)m"
}

struct Row: View {
    let title: String; let w: Window?
    var body: some View {
        let p = w?.percent ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(w == nil ? "–" : "\(Int(p.rounded()))%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            ProgressView(value: min(max(p, 0), 100), total: 100)
                .tint(p >= 90 ? .red : p >= 70 ? .orange : .accentColor)
            Text(resetText(w?.resetsAt)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let u = store.usage { Text(u.plan).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if let u = store.usage {
                Row(title: "Session (5h)", w: u.fiveHour)
                Row(title: "Week", w: u.sevenDay)
            }
            if let e = store.error { Text(e.message).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Button("Refresh") { store.refresh() }.buttonStyle(.link)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.link)
            }.font(.system(size: 11))
        }
        .padding(14).frame(width: 240)
    }
}

// MARK: - App

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView(store: store))
        if let b = item.button {
            b.title = "…"
            b.image = nil
            b.target = self
            b.action = #selector(toggle)
            b.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }
        store.onChange = { [weak self] in self?.updateTitle() }
        store.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
    }

    @objc func mouseEntered(with e: NSEvent) { if !popover.isShown { show() } }

    @objc func toggle() { popover.isShown ? popover.performClose(nil) : show() }

    func show() {
        guard let b = item.button else { return }
        store.refresh()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }

    func updateTitle() {
        if let p = store.usage?.fiveHour?.percent { item.button?.title = "\(Int(p.rounded()))%" }
        else { item.button?.title = store.error == nil ? "…" : "!" }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
