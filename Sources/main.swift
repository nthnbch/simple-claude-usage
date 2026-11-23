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

struct Bar: View {
    let percent: Double
    var color: Color { percent >= 90 ? .red : percent >= 70 ? .orange : .green }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color).frame(width: max(6, g.size.width * min(max(percent, 0), 100) / 100))
            }
        }.frame(height: 6)
    }
}

struct Row: View {
    let title: String; let w: Window?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(w == nil ? "–" : "\(Int((w?.percent ?? 0).rounded()))%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Bar(percent: w?.percent ?? 0)
            Text(resetText(w?.resetsAt)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Claude").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let u = store.usage {
                    Text(u.plan).font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
            }
            if let u = store.usage {
                Row(title: "Session · 5h", w: u.fiveHour)
                Row(title: "Week · 7d", w: u.sevenDay)
            } else if store.error == nil {
                Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let e = store.error { Text(e.message).font(.system(size: 11)).foregroundStyle(.red) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: 250, alignment: .leading)
    }
}

// MARK: - App

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var menuOpen = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let host = NSHostingView(rootView: ContentView(store: store))
        host.frame = NSRect(origin: .zero, size: NSSize(width: 250, height: 190))
        let content = NSMenuItem()
        content.view = host
        menu.addItem(content)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu

        if let b = item.button {
            b.title = "…"
            b.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }
        store.onChange = { [weak self] in self?.update() }
        store.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
    }

    @objc func mouseEntered(with e: NSEvent) { if !menuOpen { item.button?.performClick(nil) } }
    @objc func refresh() { store.refresh() }
    func menuWillOpen(_ m: NSMenu) { menuOpen = true; store.refresh() }
    func menuDidClose(_ m: NSMenu) { menuOpen = false }

    func update() {
        if let h = menu.items.first?.view {
            let size = h.fittingSize
            h.setFrameSize(NSSize(width: 250, height: size.height))
        }
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
