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

// MARK: - UI (pure AppKit)

func resetText(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = max(0, Int(d.timeIntervalSinceNow))
    let h = s / 3600, m = (s % 3600) / 60
    return L.resets(h >= 24 ? h / 24 : 0, h >= 24 ? h % 24 : h, m)
}

func label(_ size: CGFloat, _ weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: "")
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    return l
}

final class BarView: NSView {
    var percent: Double = 0 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }
    override func draw(_ r: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        NSColor.labelColor.withAlphaComponent(0.12).setFill(); track.fill()
        let w = max(6, bounds.width * CGFloat(min(max(percent, 0), 100)) / 100)
        let color: NSColor = percent >= 90 ? .systemRed : percent >= 70 ? .systemOrange : .systemGreen
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height), xRadius: 3, yRadius: 3).fill()
    }
}

final class RowView: NSStackView {
    let name = label(12), pct = label(15, .semibold), bar = BarView(), reset = label(10, color: .secondaryLabelColor)
    init(title: String) {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 5
        name.stringValue = title
        pct.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        let top = NSStackView(views: [name, NSView(), pct])
        top.orientation = .horizontal; top.alignment = .firstBaseline
        addArrangedSubview(top); addArrangedSubview(bar); addArrangedSubview(reset)
        top.widthAnchor.constraint(equalToConstant: 218).isActive = true
        bar.widthAnchor.constraint(equalToConstant: 218).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ w: Window?) {
        pct.stringValue = w == nil ? "–" : "\(Int(w!.percent.rounded()))%"
        bar.percent = w?.percent ?? 0
        reset.stringValue = resetText(w?.resetsAt)
    }
}

final class PanelView: NSStackView {
    let plan = label(10, .medium), five = RowView(title: L.session), week = RowView(title: L.week)
    let status = label(11, color: .secondaryLabelColor)
    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 14
        edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        let title = label(13, .semibold); title.stringValue = "Claude"
        let head = NSStackView(views: [title, NSView(), plan])
        head.orientation = .horizontal
        status.maximumNumberOfLines = 3
        status.preferredMaxLayoutWidth = 218
        status.lineBreakMode = .byWordWrapping
        for v in [head, five, week, status] { addArrangedSubview(v) }
        head.widthAnchor.constraint(equalToConstant: 218).isActive = true
        render(nil, nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    func render(_ u: Usage?, _ e: UsageError?) {
        plan.stringValue = u?.plan ?? ""
        plan.isHidden = u == nil
        five.isHidden = u == nil; week.isHidden = u == nil
        five.set(u?.fiveHour); week.set(u?.sevenDay)
        status.stringValue = e?.message ?? (u == nil ? L.loading : "")
        status.textColor = e == nil ? .secondaryLabelColor : .systemRed
        status.isHidden = status.stringValue.isEmpty
    }
}

// MARK: - App

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let panel = PanelView()
    var timer: Timer?
    var menuOpen = false
    var lastFetch = Date.distantPast
    var usage: Usage?
    var error: UsageError?

    func applicationDidFinishLaunching(_ n: Notification) {
        let content = NSMenuItem()
        panel.setFrameSize(panel.fittingSize)
        content.view = panel
        menu.addItem(content)
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: L.refresh, action: #selector(forceRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: L.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu

        if let b = item.button {
            b.title = "…"
            b.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }
        refresh()
        // every 5 minutes, with 30 s tolerance so macOS can coalesce wake-ups
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 30
    }

    @objc func mouseEntered(with e: NSEvent) { if !menuOpen { item.button?.performClick(nil) } }
    @objc func forceRefresh() { refresh() }

    func refresh() {
        lastFetch = Date()
        Task {
            do { usage = try await fetchUsage(); error = nil }
            catch { self.error = (error as? UsageError) ?? .network }
            update()
        }
    }

    func menuWillOpen(_ m: NSMenu) {
        menuOpen = true
        if Date().timeIntervalSince(lastFetch) > 60 { refresh() }
    }
    func menuDidClose(_ m: NSMenu) { menuOpen = false }

    func update() {
        panel.render(usage, error)
        panel.setFrameSize(panel.fittingSize)
        if let p = usage?.fiveHour?.percent { item.button?.title = "\(Int(p.rounded()))%" }
        else { item.button?.title = error == nil ? "…" : "!" }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
