import SwiftUI
import AppKit

// MARK: - Localization (en, fr, de, it, ru, es)

enum L {
    static let lang: String = {
        let c = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"
        return ["fr", "de", "it", "ru", "es"].contains(c) ? c : "en"
    }()
    // order: en, fr, de, it, ru, es
    static func t(_ en: String, _ fr: String, _ de: String, _ it: String, _ ru: String, _ es: String) -> String {
        switch lang { case "fr": return fr; case "de": return de; case "it": return it; case "ru": return ru; case "es": return es; default: return en }
    }
    static var session: String { t("Session · 5h", "Session · 5h", "Sitzung · 5 Std", "Sessione · 5h", "Сессия · 5 ч", "Sesión · 5h") }
    static var week: String { t("Week · 7d", "Semaine · 7j", "Woche · 7 T", "Settimana · 7g", "Неделя · 7 дн", "Semana · 7d") }
    static var loading: String { t("Loading…", "Chargement…", "Lädt…", "Caricamento…", "Загрузка…", "Cargando…") }
    static var refresh: String { t("Refresh", "Actualiser", "Aktualisieren", "Aggiorna", "Обновить", "Actualizar") }
    static var quit: String { t("Quit", "Quitter", "Beenden", "Esci", "Выйти", "Salir") }
    static var noCreds: String { t("Not signed in. Log in once with Claude Code.", "Non connecté. Connecte-toi une fois avec Claude Code.", "Nicht angemeldet. Einmal in Claude Code anmelden.", "Non connesso. Accedi una volta con Claude Code.", "Нет входа. Войдите один раз в Claude Code.", "Sin sesión. Inicia sesión una vez con Claude Code.") }
    static var expired: String { t("Session expired. Use Claude Code once to refresh.", "Session expirée. Utilise Claude Code une fois pour la renouveler.", "Sitzung abgelaufen. Claude Code einmal nutzen.", "Sessione scaduta. Usa Claude Code una volta.", "Сессия истекла. Запустите Claude Code один раз.", "Sesión caducada. Usa Claude Code una vez.") }
    static var network: String { t("Can't reach Anthropic.", "Impossible de joindre Anthropic.", "Anthropic nicht erreichbar.", "Anthropic non raggiungibile.", "Нет связи с Anthropic.", "No se puede contactar con Anthropic.") }
    static func resets(_ d: Int, _ h: Int, _ m: Int) -> String {
        let u = (d: t("d", "j", "T", "g", "д", "d"), h: t("h", "h", "Std", "h", "ч", "h"), m: t("min", "min", "Min", "min", "мин", "min"))
        let body = d > 0 ? "\(d)\(u.d) \(h)\(u.h)" : h > 0 ? "\(h)\(u.h) \(m)\(u.m)" : "\(m)\(u.m)"
        return t("resets in ", "remise à zéro dans ", "Reset in ", "reset tra ", "сброс через ", "se reinicia en ") + body
    }
}

// MARK: - Model

struct Window { let percent: Double; let resetsAt: Date? }
struct Usage { let plan: String; let fiveHour: Window?; let sevenDay: Window? }

enum UsageError: Error {
    case noCredentials, expired, network
    var message: String {
        switch self {
        case .noCredentials: return L.noCreds
        case .expired: return L.expired
        case .network: return L.network
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
    return L.resets(h >= 24 ? h / 24 : 0, h >= 24 ? h % 24 : h, m)
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
                Row(title: L.session, w: u.fiveHour)
                Row(title: L.week, w: u.sevenDay)
            } else if store.error == nil {
                Text(L.loading).font(.system(size: 11)).foregroundStyle(.secondary)
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
        let refresh = NSMenuItem(title: L.refresh, action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(NSMenuItem(title: L.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
