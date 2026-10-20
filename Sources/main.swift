import AppKit
import ServiceManagement

struct UsageWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: Double?

    var remaining: Int {
        guard usedPercent.isFinite else { return 0 }
        return Int((100 - min(100, max(0, usedPercent))).rounded())
    }
}

struct Limits: Decodable {
    let primary: UsageWindow?
    let secondary: UsageWindow?
    var fiveHour: UsageWindow? { [primary, secondary].compactMap { $0 }.first { $0.windowDurationMins == 300 } }
    var weekly: UsageWindow? { [primary, secondary].compactMap { $0 }.first { $0.windowDurationMins == 10080 } }
}

struct UsageResult: Decodable {
    let rateLimits: Limits?
    let rateLimitsByLimitId: [String: Limits]?
    var limits: Limits? { rateLimitsByLimitId?["codex"] ?? rateLimits }
}

enum Text {
    static let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    static func get(_ en: String, _ zh: String) -> String { chinese ? zh : en }
}

// All state is confined to the main queue. Pipe callbacks only forward bytes.
final class UsageClient {
    var onLimits: ((Limits) -> Void)?
    var onStatus: ((String) -> Void)?
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var buffer = Data()
    private var session = UUID()
    private var initialized = false
    private var requestID = 1
    private var pendingID: Int?
    private var deadline: Date?
    private var pollTimer: Timer?
    private var reconnectTimer: Timer?

    func start() {
        stop()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        connect()
    }

    func stop() {
        pollTimer?.invalidate()
        reconnectTimer?.invalidate()
        pollTimer = nil
        reconnectTimer = nil
        disconnect()
    }

    func refresh() {
        if let deadline, deadline < Date() {
            retry(Text.get("Connection timed out", "连接超时"))
            return
        }
        guard initialized, pendingID == nil else { return }
        requestID += 1
        pendingID = requestID
        deadline = Date().addingTimeInterval(25)
        send(["id": requestID, "method": "account/rateLimits/read",
              "params": ["excludeResetCreditDetails": true]])
    }

    private func connect() {
        reconnectTimer = nil
        guard let executable = Self.findCodex() else {
            retry(Text.get("Install ChatGPT / Codex CLI, then sign in", "请安装 ChatGPT / Codex CLI 并登录"))
            return
        }
        onStatus?(Text.get("Connecting…", "连接中…"))
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = ["app-server", "--stdio"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = errors
        process = task
        stdinHandle = input.fileHandleForWriting
        stdoutHandle = output.fileHandleForReading
        stderrHandle = errors.fileHandleForReading
        let currentSession = session
        stdoutHandle?.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            DispatchQueue.main.async {
                guard let self, self.session == currentSession, !bytes.isEmpty else { return }
                self.consume(bytes)
            }
        }
        // Drain stderr so the child cannot block. Never persist account diagnostics.
        stderrHandle?.readabilityHandler = { handle in _ = handle.availableData }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.session == currentSession else { return }
                self.retry(Text.get("Reconnecting…", "正在重连…"))
            }
        }
        do {
            try task.run()
            deadline = Date().addingTimeInterval(25)
            send(["id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "codex-glance", "version": "1.0.0"],
                "capabilities": ["experimentalApi": true]
            ]])
        } catch {
            retry(Text.get("Cannot start Codex", "无法启动 Codex"))
        }
    }

    private func disconnect() {
        session = UUID()
        initialized = false
        pendingID = nil
        deadline = nil
        requestID = 1
        buffer.removeAll()
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? stdinHandle?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
    }

    private func retry(_ status: String) {
        guard reconnectTimer == nil else { return }
        disconnect()
        onStatus?(status)
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }

    private func send(_ message: [String: Any]) {
        guard let handle = stdinHandle,
              let bytes = try? JSONSerialization.data(withJSONObject: message) else { return }
        do { try handle.write(contentsOf: bytes + Data([10])) }
        catch { retry(Text.get("Reconnecting…", "正在重连…")) }
    }

    private func consume(_ bytes: Data) {
        buffer.append(bytes)
        guard buffer.count < 4 * 1024 * 1024 else {
            retry(Text.get("Reconnecting…", "正在重连…"))
            return
        }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ message: [String: Any]) {
        if message["method"] as? String == "account/rateLimits/updated" {
            refresh()
            return
        }
        guard let id = message["id"] as? Int else { return }
        if message["error"] != nil {
            retry(Text.get("Sign in to Codex or retry later", "请登录 Codex 或稍后重试"))
            return
        }
        if id == 1, message["result"] != nil {
            initialized = true
            deadline = nil
            send(["method": "initialized"])
            refresh()
            return
        }
        guard id == pendingID else { return }
        pendingID = nil
        deadline = nil
        guard let result = message["result"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: result),
              let usage = try? JSONDecoder().decode(UsageResult.self, from: data),
              let limits = usage.limits else {
            onStatus?(Text.get("Usage unavailable", "暂时无法读取额度"))
            return
        }
        onLimits?(limits)
    }

    static func findCodex() -> String? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["CODEX_GLANCE_CODEX_PATH"] {
            candidates.append(override)
        }
        for root in ["/Applications", home + "/Applications"] {
            for name in ["ChatGPT", "Codex"] {
                let base = "\(root)/\(name).app/Contents/Resources"
                candidates += [base + "/codex-cli/bin/codex",
                               base + "/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                               base + "/codex"]
            }
        }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex"]
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(String(directory) + "/codex")
        }
        return candidates.first { manager.isExecutableFile(atPath: $0) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let client = UsageClient()
    private let fiveHour = NSMenuItem()
    private let weekly = NSMenuItem()
    private let status = NSMenuItem()
    private let login = NSMenuItem()
    private var lastUpdate: Date?
    private var staleTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        item.button?.title = "Codex ◉ 5H --%  |  W --%"
        let menu = NSMenu()
        menu.delegate = self
        for row in [fiveHour, weekly, status] { row.isEnabled = false }
        fiveHour.title = Text.get("5 hours: connecting…", "5 小时：连接中…")
        weekly.title = Text.get("Weekly: connecting…", "每周：连接中…")
        status.title = Text.get("Connecting…", "连接中…")
        menu.addItem(NSMenuItem(title: "Codex Glance", action: nil, keyEquivalent: ""))
        menu.addItem(fiveHour)
        menu.addItem(weekly)
        menu.addItem(.separator())
        menu.addItem(status)
        menu.addItem(action(Text.get("Refresh now", "立即刷新"), #selector(refresh), "r"))
        login.title = Text.get("Launch at login", "登录时启动")
        login.target = self
        login.action = #selector(toggleLogin)
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(action(Text.get("GitHub · Help & updates", "GitHub · 帮助与更新"), #selector(openProject)))
        menu.addItem(action(Text.get("Quit Codex Glance", "退出 Codex Glance"), #selector(quit), "q"))
        item.menu = menu
        client.onLimits = { [weak self] limits in self?.display(limits) }
        client.onStatus = { [weak self] message in self?.displayStatus(message) }
        client.start()
        staleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, let lastUpdate = self.lastUpdate,
                  Date().timeIntervalSince(lastUpdate) > 60 else { return }
            self.displayStatus(Text.get("Reconnecting · data is stale", "正在重连 · 数据已过期"))
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.client.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        staleTimer?.invalidate()
        client.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func action(_ title: String, _ selector: Selector, _ key: String = "") -> NSMenuItem {
        let row = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        row.target = self
        return row
    }

    private func display(_ limits: Limits) {
        lastUpdate = Date()
        let short = limits.fiveHour.map { String($0.remaining) } ?? "--"
        let long = limits.weekly.map { String($0.remaining) } ?? "--"
        item.button?.title = "Codex ◉ 5H \(short)%  |  W \(long)%"
        item.button?.toolTip = Text.get("Remaining allowance · updates every 20 seconds", "剩余额度 · 每 20 秒刷新")
        fiveHour.title = detail(Text.get("5 hours", "5 小时"), limits.fiveHour)
        weekly.title = detail(Text.get("Weekly", "每周"), limits.weekly)
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        status.title = Text.get("Updated ", "更新于 ") + formatter.string(from: Date())
    }

    private func displayStatus(_ message: String) {
        item.button?.title = "Codex ◌ 5H --%  |  W --%"
        item.button?.toolTip = message
        fiveHour.title = Text.get("5 hours: unavailable", "5 小时：暂不可用")
        weekly.title = Text.get("Weekly: unavailable", "每周：暂不可用")
        status.title = message
    }

    private func detail(_ label: String, _ window: UsageWindow?) -> String {
        guard let window else { return label + Text.get(": unavailable", "：暂不可用") }
        var value = "\(label): \(window.remaining)%" + Text.get(" remaining", " 剩余")
        if let timestamp = window.resetsAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            value += Text.get(" · resets ", " · 重置 ") + formatter.string(from: Date(timeIntervalSince1970: timestamp))
        }
        return value
    }

    @objc private func refresh() { client.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openProject() {
        NSWorkspace.shared.open(URL(string: "https://github.com/taizi0125/codex-glance")!)
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = Text.get("Could not change login setting", "无法更改登录启动设置")
            alert.informativeText = Text.get("Move Codex Glance to Applications, then try again or add it in System Settings → General → Login Items.", "请将 Codex Glance 移到应用程序文件夹后重试，或在系统设置 → 通用 → 登录项中添加。")
            alert.runModal()
        }
    }
}

func runSelfTests() throws {
    let json = #"{"rateLimits":{"primary":{"usedPercent":32,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":16,"windowDurationMins":10080,"resetsAt":1800100000}}}"#
    let result = try JSONDecoder().decode(UsageResult.self, from: Data(json.utf8))
    precondition(result.limits?.fiveHour?.remaining == 68)
    precondition(result.limits?.weekly?.remaining == 84)
    let empty = try JSONDecoder().decode(UsageResult.self, from: Data(#"{"rateLimits":{"primary":null,"secondary":null}}"#.utf8))
    precondition(empty.limits?.fiveHour == nil && empty.limits?.weekly == nil)
    let swapped = Limits(primary: UsageWindow(usedPercent: 140, windowDurationMins: 10080, resetsAt: nil),
                         secondary: UsageWindow(usedPercent: -2, windowDurationMins: 300, resetsAt: nil))
    precondition(swapped.fiveHour?.remaining == 100 && swapped.weekly?.remaining == 0)
    let mapped = try JSONDecoder().decode(UsageResult.self, from: Data(#"{"rateLimits":null,"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":50,"windowDurationMins":300},"secondary":null}}}"#.utf8))
    precondition(mapped.limits?.fiveHour?.remaining == 50)
    print("PASS: remaining percentages, null windows, duration mapping, clamping, codex bucket")
}

if CommandLine.arguments.contains("--self-test") {
    try runSelfTests()
} else if CommandLine.arguments.contains("--check") {
    // Prints only availability, never account identifiers or raw protocol messages.
    let client = UsageClient()
    var done = false
    client.onLimits = { limits in
        guard limits.fiveHour != nil || limits.weekly != nil else { return }
        print("PASS: received allowance data from local Codex")
        done = true
    }
    client.onStatus = { _ in }
    client.start()
    let until = Date().addingTimeInterval(35)
    while !done && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    client.stop()
    if !done { fputs("Could not read usage within 35 seconds. Check Codex sign-in.\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
