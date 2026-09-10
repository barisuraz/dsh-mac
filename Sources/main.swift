// DeepSeek Harness — native macOS wrapper
//
// A minimal AppKit + WKWebView shell that owns its own `dsh web` server process:
//
//   * spawns `dsh web --no-open --port <port>` in a login+interactive shell so it
//     inherits the user's PATH and environment exactly as a terminal would,
//   * waits for the harness to print its authenticated `dsh web: <url>` line,
//   * loads that URL (the `?token=` query mints the session cookie) in a webview
//     whose storage container belongs to this app — never Chrome, never Safari,
//   * terminates the server it started when the app quits.
//
// It implements no harness logic and talks to no API of its own. If the server is
// not listening, the window says so instead of showing a browser error page.
//
// Run with `--selftest` to print what the launcher resolved and exit.

import AppKit
import WebKit
import Darwin

// MARK: - Logging

/// Append-only diagnostics. The app is a GUI bundle, so stderr from Finder is
/// lost; everything goes to a file as well so a failed launch is inspectable.
final class Log {
    static let shared = Log()

    private let handle: FileHandle?
    private let lock = NSLock()
    private let path: String

    private init() {
        let env = ProcessInfo.processInfo.environment["DSH_WRAPPER_LOG"] ?? ""
        let url: URL
        if env.isEmpty {
            let library = FileManager.default
                .urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            url = library.appendingPathComponent("Logs/DeepSeekHarness/wrapper.log")
        } else {
            url = URL(fileURLWithPath: env)
        }
        path = url.path
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    /// Writes the file copy synchronously: an async write can be lost when the
    /// process dies immediately after logging, which is exactly the case worth
    /// recording. stderr comes last because it is the copy most likely to fail.
    func write(_ message: String) {
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        let data = Data(line.utf8)

        lock.lock()
        try? handle?.write(contentsOf: data)
        lock.unlock()

        FileHandle.standardError.write(data)
    }

    var logPath: String { path }
}

// MARK: - Locating the harness

enum Locator {
    /// Resolve the `dsh` launcher the way the user's own shell would.
    ///
    /// A Finder-launched bundle has a bare `PATH`, so a plain PATH lookup is not
    /// enough: the login+interactive shell reproduces the terminal environment,
    /// and the `npx` cache glob covers the common `npx @deepseek-ai/dsh` install
    /// even when no shell profile puts it on `PATH`.
    static func dshPath() -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment

        if let override = env["DSH_BIN"], !override.isEmpty, fm.isExecutableFile(atPath: override) {
            Log.shared.write("dsh: using DSH_BIN override \(override)")
            return override
        }

        if let out = runShell("command -v dsh") {
            let candidate = out
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("zsh:") }
            if let candidate, fm.isExecutableFile(atPath: candidate) {
                Log.shared.write("dsh: resolved via login shell -> \(candidate)")
                return candidate
            }
        }

        var candidates: [String] = []
        let home = NSHomeDirectory()
        let npxRoot = (home as NSString).appendingPathComponent(".npm/_npx")
        if let entries = try? fm.contentsOfDirectory(atPath: npxRoot) {
            for entry in entries {
                let candidate = "\(npxRoot)/\(entry)/node_modules/.bin/dsh"
                if fm.isExecutableFile(atPath: candidate) { candidates.append(candidate) }
            }
        }
        for candidate in [
            "/opt/homebrew/bin/dsh",
            "/usr/local/bin/dsh",
            "\(home)/.local/bin/dsh",
            "\(home)/.bun/bin/dsh",
        ] where fm.isExecutableFile(atPath: candidate) {
            candidates.append(candidate)
        }

        let newest = candidates.sorted { modificationTime($0) > modificationTime($1) }.first
        if let newest { Log.shared.write("dsh: resolved via fallback scan -> \(newest)") }
        return newest
    }

    private static func modificationTime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }

    /// Run one command in the user's login+interactive shell and return stdout.
    static func runShell(_ command: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            Log.shared.write("shell failed to start: \(error.localizedDescription)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// True when nothing is accepting connections on `127.0.0.1:<port>`.
    /// Without `SO_REUSEPORT` this correctly reports an active listener as busy.
    static func portIsFree(_ port: Int) -> Bool {
        guard port > 0, port < 65536 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}

// MARK: - Server process

/// Owns one `dsh web` child process for the lifetime of the window.
final class HarnessServer {
    /// URL line the web bundle prints once the server has bound its port:
    /// `dsh web: http://127.0.0.1:<port>/?token=<process token>`
    private static let readyMarker = "dsh web: "

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var generation = 0
    private var tail: [String] = []
    private var readySeen = false
    /// Set while stop() is deliberately ending the server, so the exit that
    /// follows is not reported to the user as a crash.
    private var shuttingDown = false

    var onReady: ((URL) -> Void)?
    var onFailure: ((String) -> Void)?

    private(set) var isRunning = false

    /// Shell supervisor wrapping the server process.
    ///
    /// `dsh` runs in the background so the shell survives to supervise it:
    ///   * the TERM/INT/HUP trap forwards a shutdown to the server, so quitting
    ///     the app stops the server rather than orphaning it,
    ///   * the polling loop notices when the wrapper app is gone — the only
    ///     recourse when the app was SIGKILLed — and stops the server too.
    ///
    /// The server's stdout/stderr stay attached to the app's pipes, so the
    /// readiness line and diagnostics still reach us.
    private static func supervisorScript(dsh: String, port: Int) -> String {
        let quoted = Locator.shellQuote(dsh)
        return """
            child=''
            forward() { [[ -n $child ]] && kill -TERM $child 2>/dev/null; }
            trap forward TERM INT HUP
            \(quoted) web --no-open --port \(port) &
            child=$!
            while kill -0 $child 2>/dev/null; do
              kill -0 $PPID 2>/dev/null || break
              sleep 1
            done
            forward
            wait $child 2>/dev/null
            exit $?
            """
    }

    func start(preferredPort: Int) {
        stop()

        guard let dsh = Locator.dshPath() else {
            onFailure?("""
                Could not find the `dsh` command.

                Install it with:  npm i -g @deepseek-ai/dsh
                Or point this app at an existing copy with the DSH_BIN environment variable.
                """)
            return
        }

        // A stable port keeps the webview origin (and its local storage) stable
        // across launches; when it is taken, `--port 0` lets the OS pick and the
        // printed URL tells us which one it chose.
        let port = Locator.portIsFree(preferredPort) ? preferredPort : 0
        if port == 0 && preferredPort != 0 {
            Log.shared.write("port \(preferredPort) is busy; asking the OS for a free port")
        }

        // The launcher is a shell that stays alive as the server's supervisor:
        // it forwards termination to `dsh`, and independently takes the server
        // down when this app disappears (including a SIGKILL, where no handler
        // of ours could ever run). A bare `exec` would leak the server instead.
        let command = Self.supervisorScript(dsh: dsh, port: port)
        Log.shared.write("starting: dsh web --no-open --port \(port) (supervised)")

        let child = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/zsh")
        child.arguments = ["-lic", command]
        child.standardOutput = stdout
        child.standardError = stderr
        child.standardInput = FileHandle.nullDevice

        generation += 1
        let token = generation
        readySeen = false
        shuttingDown = false
        tail.removeAll()
        scanBuffer.removeAll()

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.ingest(stdout: text, generation: token) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.ingest(stderr: text, generation: token) }
        }

        child.terminationHandler = { [weak self] exited in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.detachPipes()
                self.isRunning = false
                let status = exited.terminationStatus
                Log.shared.write("dsh exited with status \(status)")
                // A deliberate stop is not a crash: the user asked for it, and
                // on quit nothing would be left to display an error anyway.
                guard !self.shuttingDown else { return }
                guard !self.readySeen else {
                    self.onFailure?("The Harness server stopped unexpectedly (exit \(status)).\n\n\(self.recentLog())")
                    return
                }
                self.onFailure?("The Harness server exited during startup (exit \(status)).\n\n\(self.recentLog())")
            }
        }

        do {
            try child.run()
        } catch {
            onFailure?("Could not start the Harness: \(error.localizedDescription)")
            return
        }

        process = child
        stdoutPipe = stdout
        stderrPipe = stderr
        isRunning = true
        Log.shared.write("dsh started with pid \(child.processIdentifier)")

        // Startup ceiling: a hung or misconfigured harness must not leave a
        // spinner forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.generation == token, !self.readySeen else { return }
            self.onFailure?("The Harness did not report a listening port within 120s.\n\n\(self.recentLog())")
        }
    }

    func stop() {
        shuttingDown = true
        detachPipes()
        guard let child = process, child.isRunning else {
            process = nil
            isRunning = false
            return
        }
        Log.shared.write("stopping dsh pid \(child.processIdentifier)")
        child.terminate() // SIGTERM -> the supervisor forwards it to `dsh`

        // Grace period, then SIGKILL. Only ever this child: a `dsh` the user
        // started by hand is never touched.
        let deadline = Date().addingTimeInterval(6)
        while child.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if child.isRunning {
            Log.shared.write("dsh did not exit on SIGTERM; sending SIGKILL")
            kill(child.processIdentifier, SIGKILL)
        }
        process = nil
        isRunning = false
    }

    /// Stop reading the child's output, so a dying process cannot deliver
    /// callbacks into a window that is going away.
    private func detachPipes() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    func recentLog(lineCount: Int = 12) -> String {
        tail.suffix(lineCount).joined(separator: "\n")
    }

    // MARK: Output handling

    /// Every byte of stdout seen so far, so a readiness line that arrives split
    /// across two pipe reads is still recognized. Trimmed to a tail.
    private var scanBuffer = ""

    private func ingest(stdout text: String, generation token: Int) {
        guard token == generation else { return }
        append(text)
        guard !readySeen else { return }
        scanBuffer.append(text)
        if scanBuffer.count > 64_000 { scanBuffer = String(scanBuffer.suffix(8_000)) }
        guard let url = Self.readyURL(in: scanBuffer) else { return }
        readySeen = true
        Log.shared.write("ready at \(url.absoluteString)")
        onReady?(url)
    }

    /// Extract the authenticated URL from the server's output.
    ///
    /// The launch line reads `dsh web: http://127.0.0.1:<port>/?token=<token>`.
    /// Matching that prefix is the fast path; the fallback accepts any loopback
    /// URL carrying a `token` parameter, so a cosmetic rewording of the log line
    /// does not break the app. This string is the entire coupling surface
    /// between this wrapper and the harness — nothing else about it is assumed.
    static func readyURL(in text: String) -> URL? {
        if let range = text.range(of: readyMarker) {
            let rest = text[range.upperBound...]
            if let url = loopbackTokenURL(String(rest.prefix { !$0.isWhitespace })) { return url }
        }
        for candidate in text.split(whereSeparator: { $0.isWhitespace }) {
            guard candidate.contains("token=") else { continue }
            let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`),;"))
            if let url = loopbackTokenURL(trimmed) { return url }
        }
        return nil
    }

    /// Accept only a loopback http URL carrying an authentication token: a URL
    /// from harness output is untrusted input, and the app must never navigate
    /// itself anywhere else.
    private static func loopbackTokenURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "http", let host = url.host,
            host == "127.0.0.1" || host == "localhost",
            url.query?.contains("token=") == true
        else { return nil }
        return url
    }

    private func ingest(stderr text: String, generation token: Int) {
        guard token == generation else { return }
        append(text)
    }

    private func append(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            tail.append(String(line))
        }
        if tail.count > 400 { tail.removeFirst(tail.count - 400) }
    }
}

// MARK: - Status overlay

/// Shown while the server starts, and again if it fails. Replaces the browser's
/// own "cannot connect" page, which would be the only thing WKWebView could show.
final class StatusOverlay: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private(set) var retryButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center

        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 14

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        retryButton = NSButton(title: "Try Again", target: nil, action: nil)
        retryButton.bezelStyle = .rounded
        retryButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [spinner, title, detail, retryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func showWorking(_ message: String, detail detailText: String = "") {
        title.stringValue = message
        detail.stringValue = detailText
        retryButton.isHidden = true
        spinner.startAnimation(nil)
        isHidden = false
    }

    func showFailure(_ message: String, detail detailText: String) {
        title.stringValue = message
        detail.stringValue = detailText
        retryButton.isHidden = false
        spinner.stopAnimation(nil)
        isHidden = false
    }

    func hideOverlay() {
        spinner.stopAnimation(nil)
        isHidden = true
    }
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var overlay: StatusOverlay!
    private let server = HarnessServer()
    /// The token-bearing URL, kept so Reload re-authenticates rather than
    /// hitting a 401 on the clean root.
    private var authenticatedURL: URL?
    /// Retained so the signal handlers stay installed.
    private var signalSources: [DispatchSourceSignal] = []
    /// True from the moment a start begins until that start succeeds or fails.
    /// Retry and menu actions are cheap to trigger twice (a stray Return, a
    /// double click), and a second concurrent server would fight for the port.
    private var isStarting = false

    private var preferredPort: Int {
        let raw = ProcessInfo.processInfo.environment["DSH_WRAPPER_PORT"] ?? ""
        return Int(raw).flatMap { $0 > 0 && $0 < 65536 ? $0 : nil } ?? 3080
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.shared.write("launched; log at \(Log.shared.logPath)")
        installSignalHandlers()
        buildMenu()
        buildWindow()
        wireServer()
        startHarness("app launch")
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A logout or `kill` sends SIGTERM rather than a Cocoa quit, which would
    /// otherwise leave the harness child running with nothing to host it.
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                Log.shared.write("received signal \(number); shutting down")
                self?.server.stop()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
        Log.shared.write("quit")
    }

    // MARK: Setup

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        // This app's own storage container: cookies and local storage never touch
        // Chrome, Safari, or any other browser profile on the machine.
        configuration.websiteDataStore = .default()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.translatesAutoresizingMaskIntoConstraints = false

        overlay = StatusOverlay(frame: .zero)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.retryButton.target = self
        overlay.retryButton.action = #selector(retryStartup)

        let content = NSView()
        content.addSubview(webView)
        content.addSubview(overlay)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: content.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "DeepSeek Harness"
        window.contentView = content
        window.minSize = NSSize(width: 640, height: 480)
        window.setFrameAutosaveName("DeepSeekHarnessWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func wireServer() {
        server.onReady = { [weak self] url in
            guard let self else { return }
            self.isStarting = false
            self.authenticatedURL = url
            self.webView.load(URLRequest(url: url))
        }
        server.onFailure = { [weak self] reason in
            guard let self else { return }
            self.isStarting = false
            // Mirror to the log: the overlay is easy to miss, and a startup
            // failure is precisely what someone reads the log to explain.
            Log.shared.write("startup failure: \(reason)")
            let split = reason.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            self.overlay.showFailure(
                String(split.first ?? "The Harness could not start."),
                detail: split.count > 1 ? String(split[1]) : "")
        }
    }

    private func startHarness(_ reason: String, force: Bool = false) {
        if isStarting && !force {
            Log.shared.write("ignoring start request (\(reason)): one is already in flight")
            return
        }
        isStarting = true
        Log.shared.write("start requested by: \(reason)")
        overlay.showWorking("Starting DeepSeek Harness…", detail: "launching dsh web")
        server.start(preferredPort: preferredPort)
    }

    @objc private func retryStartup() { startHarness("retry button") }

    @objc private func restartHarness() { startHarness("restart command", force: true) }

    @objc private func reloadHarness() {
        guard let url = authenticatedURL else { return startHarness("reload with no server") }
        webView.load(URLRequest(url: url))
    }

    // MARK: Menu

    /// The Edit menu is not decoration: macOS routes Cmd+C/V/X through menu key
    /// equivalents, so without it a web text field cannot paste a prompt.
    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About DeepSeek Harness",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        let restart = NSMenuItem(
            title: "Restart Harness", action: #selector(restartHarness), keyEquivalent: "r")
        restart.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(restart)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide DeepSeek Harness",
            action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit DeepSeek Harness",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        // undo:/redo: live on the responder chain rather than a concrete class,
        // so they are built from their selector names.
        editMenu.addItem(
            withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Reload", action: #selector(reloadHarness), keyEquivalent: "r")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(zoomReset), keyEquivalent: "0")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func zoomIn() { webView.pageZoom = min(webView.pageZoom + 0.1, 3.0) }
    @objc private func zoomOut() { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc private func zoomReset() { webView.pageZoom = 1.0 }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.shared.write("navigation finished: \(webView.url?.absoluteString ?? "?")")
        overlay.hideOverlay()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportLoadFailure(error)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        reportLoadFailure(error)
    }

    private func reportLoadFailure(_ error: Error) {
        Log.shared.write("navigation failed: \(error.localizedDescription)")
        // The server being down is the expected cause, not a broken page.
        if !server.isRunning {
            overlay.showFailure(
                "The Harness server is not running.",
                detail: server.recentLog())
        }
    }

    /// Keep harness-internal navigation in this window; hand genuine external
    /// links to the user's default browser, exactly as a browser would.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, let host = url.host else {
            decisionHandler(.allow)
            return
        }
        let local = host == "127.0.0.1" || host == "localhost" || host == "::1"
        if !local, navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// Log the main-frame HTTP status. A 401 here is the tell-tale sign that the
    /// token exchange failed, which otherwise looks like a blank window.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
            let response = navigationResponse.response as? HTTPURLResponse
        {
            Log.shared.write("main frame \(response.statusCode) \(response.url?.absoluteString ?? "?")")
            if response.statusCode == 401 {
                overlay.showFailure(
                    "Authentication with the Harness failed (HTTP 401).",
                    detail: "The server rejected this window's session token. Use Restart Harness (⇧⌘R) to get a fresh one.")
            }
        }
        decisionHandler(.allow)
    }

    /// `target="_blank"` and `window.open` become same-window navigation for
    /// local pages rather than dead ends.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, let host = url.host,
            host == "127.0.0.1" || host == "localhost"
        {
            webView.load(navigationAction.request)
        } else if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

// MARK: - Entry point

/// Non-GUI diagnostics so the launcher logic can be checked from a terminal.
enum SelfTest {
    static func run() {
        print("log:            \(Log.shared.logPath)")
        print("dsh:            \(Locator.dshPath() ?? "NOT FOUND")")
        let preferred = Int(ProcessInfo.processInfo.environment["DSH_WRAPPER_PORT"] ?? "") ?? 3080
        print("preferred port: \(preferred) (\(Locator.portIsFree(preferred) ? "free" : "busy -> will request 0"))")
    }
}

/// Verifies, end to end, that the harness still honours the contract this app
/// depends on. Everything the wrapper assumes about DSH is checked here, so the
/// failure mode of an upstream change is a red CI run with a named cause rather
/// than a user staring at a window that never loads.
///
/// The contract is only three claims:
///   1. a `dsh` executable can be resolved,
///   2. `dsh web --no-open --port N` serves the GUI on loopback,
///   3. it prints a loopback URL carrying a `token` parameter.
enum ContractCheck {
    static func run() -> Never {
        print("dsh-mac contract check")

        guard let dsh = Locator.dshPath() else {
            print("  [FAIL] claim 1: no `dsh` executable could be resolved")
            print("         install it with: npm i -g @deepseek-ai/dsh")
            exit(1)
        }
        print("  [ ok ] claim 1: resolved dsh at \(dsh)")

        // Port 0 keeps the check from colliding with a harness the user is
        // already running.
        let server = HarnessServer()
        var ready: URL?
        var failure: String?
        server.onReady = { ready = $0 }
        server.onFailure = { failure = $0 }
        server.start(preferredPort: 0)

        wait(until: { ready != nil || failure != nil }, timeout: 90)

        guard let url = ready else {
            print("  [FAIL] claim 3: no authenticated URL was announced")
            print("         \(failure ?? "timed out waiting for the readiness line")")
            server.stop()
            exit(1)
        }
        print("  [ ok ] claim 3: announced \(redact(url))")

        // The announced URL must actually serve the GUI. The token exchange is
        // what makes this a real check: an unauthenticated root request 401s.
        let status = fetchStatus(url)
        server.stop()

        guard status == 200 else {
            print("  [FAIL] claim 2: the announced URL returned \(status.map(String.init) ?? "no response"), expected 200")
            print("         the token exchange may have changed")
            exit(1)
        }
        print("  [ ok ] claim 2: served HTTP 200 after the token exchange")
        print("contract holds")
        exit(0)
    }

    /// Never print a live session token into CI logs.
    private static func redact(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "http://127.0.0.1/"
        }
        components.query = nil
        return "\(components.string ?? "http://127.0.0.1/")?token=<redacted>"
    }

    /// Pump the main run loop: HarnessServer reports on the main queue, and this
    /// process has no NSApplication to drive it.
    private static func wait(until done: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
    }

    private static func fetchStatus(_ url: URL) -> Int? {
        var status: Int?
        let task = URLSession.shared.dataTask(with: url) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
        }
        task.resume()
        wait(until: { status != nil }, timeout: 30)
        return status
    }
}

/// Tests for {@link HarnessServer.readyURL}, the single piece of harness output
/// this app interprets. These run in CI so that a change to that log line fails
/// loudly here, rather than silently in someone's window.
enum ParserTests {
    static func run() -> Never {
        var failures = 0

        func expect(_ text: String, _ expected: String?, _ label: String) {
            let actual = HarnessServer.readyURL(in: text)?.absoluteString
            if actual == expected {
                print("  [ ok ] \(label)")
            } else {
                print("  [FAIL] \(label)\n         input:    \(text)\n         expected: \(expected ?? "nil")\n         actual:   \(actual ?? "nil")")
                failures += 1
            }
        }

        print("ready-line parser tests")

        // The documented shape.
        expect(
            "dsh web: http://127.0.0.1:3080/?token=abc123",
            "http://127.0.0.1:3080/?token=abc123",
            "parses the documented readiness line")

        // Real tokens are urlsafe base64 and contain - and _.
        expect(
            "dsh web: http://127.0.0.1:3080/?token=a-b_c-9X",
            "http://127.0.0.1:3080/?token=a-b_c-9X",
            "accepts urlsafe tokens")

        // A LAN suffix is appended when the server is reachable on the network;
        // the loopback URL must still win.
        expect(
            "dsh web: http://127.0.0.1:3080/?token=abc (LAN: http://192.168.1.5:3080/?token=abc)",
            "http://127.0.0.1:3080/?token=abc",
            "ignores the LAN suffix and keeps loopback")

        // The reworded-line fallback: this is what makes a cosmetic upstream
        // change survivable.
        expect(
            "Serving the harness at http://127.0.0.1:3080/?token=abc",
            "http://127.0.0.1:3080/?token=abc",
            "survives a reworded log line")

        // localhost is accepted as well as the literal address.
        expect(
            "listening on http://localhost:3080/?token=abc",
            "http://localhost:3080/?token=abc",
            "accepts localhost")

        // A URL already on its own line, as the output arrives over a pipe.
        expect(
            "dsh web: http://127.0.0.1:3080/?token=abc\n",
            "http://127.0.0.1:3080/?token=abc",
            "handles a trailing newline")

        // ---- refusals: a URL taken from process output is untrusted input ----

        expect(
            "dsh web: http://127.0.0.1:3080/",
            nil,
            "refuses a loopback URL with no token")

        expect(
            "dsh web: http://evil.example.com/?token=abc",
            nil,
            "refuses a non-loopback host")

        expect(
            "dsh web: file:///etc/passwd?token=abc",
            nil,
            "refuses a non-http scheme")

        expect(
            "still starting up",
            nil,
            "returns nothing before readiness")

        // A prompt echoing the contract must not be mistaken for readiness:
        // the token has to be a real parameter, not prose.
        expect(
            "dsh web: does not print a token yet",
            nil,
            "ignores prose containing the words")

        if failures == 0 {
            print("all parser tests passed")
            exit(0)
        }
        print("\(failures) parser test(s) failed")
        exit(1)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

if arguments.contains("--test-parser") {
    ParserTests.run()
}

if arguments.contains("--check-contract") {
    ContractCheck.run()
}

// A closed stdout/stderr pipe must not kill the app mid-shutdown: writing to it
// then fails with EPIPE instead of raising SIGPIPE, whose default action is
// immediate termination. This is not hypothetical — it is what happens when the
// app is launched from a terminal that exits, or by a supervising process.
signal(SIGPIPE, SIG_IGN)

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
