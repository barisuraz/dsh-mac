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
    /// Carries a pipe's contents across the queue that drains it.
    final class ErrorBox: @unchecked Sendable {
        var data = Data()
    }

    /// Read a boolean-ish environment variable.
    static func flag(_ name: String, default defaultValue: Bool = false) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return defaultValue }
        return ["1", "true", "yes", "on"].contains(raw.lowercased())
    }

    /// Condense a multi-line failure report into one useful line: the headline
    /// plus the tail of the harness's own output.
    ///
    /// Truncating from the front loses the actual error, which is always at the
    /// end of a Node stack trace, so the tail is what matters.
    static func condense(_ reason: String, limit: Int = 400) -> String {
        let lines = reason
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let headline = lines.first else { return "" }
        // Drop the trailing "at ..." frames; the message line is above them.
        let body = lines.dropFirst().filter { !$0.hasPrefix("at ") }
        let tail = body.suffix(3).joined(separator: " / ")
        let combined = tail.isEmpty ? headline : "\(headline) — \(tail)"
        return String(combined.prefix(limit))
    }

    /// `DSH_NO_SYSTEM_DSH=1` makes the app ignore any harness on `PATH` and use
    /// only its own managed slots, so what it runs does not depend on your shell
    /// setup. An explicit `DSH_BIN` still wins, being a deliberate override.
    static var ignoresSystemDsh: Bool { flag("DSH_NO_SYSTEM_DSH") }

    /// Resolve the `dsh` launcher the way the user's own shell would.
    ///
    /// A Finder-launched bundle has a bare `PATH`, so a plain PATH lookup is not
    /// enough: the login+interactive shell reproduces the terminal environment,
    /// and the `npx` cache glob covers the common `npx @deepseek-ai/dsh` install
    /// even when no shell profile puts it on `PATH`.
    ///
    /// Returns nil when nothing is installed anywhere, which is the signal to
    /// provision a managed copy.
    static func dshPath() -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment

        if let override = env["DSH_BIN"], !override.isEmpty, fm.isExecutableFile(atPath: override) {
            Log.shared.write("dsh: using DSH_BIN override \(override)")
            return override
        }

        if ignoresSystemDsh {
            Log.shared.write("dsh: ignoring harnesses on PATH (DSH_NO_SYSTEM_DSH=1)")
            return nil
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

    /// Resolve `npm`, which is what installs managed harness copies into slots.
    /// It is often only on PATH via a version manager, so the login shell is
    /// asked before the usual install locations are probed.
    static func npmPath() -> String? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["DSH_NPM_BIN"], !override.isEmpty,
            fm.isExecutableFile(atPath: override)
        {
            return override
        }
        if let out = runShell("command -v npm") {
            let candidate = out
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("/") }
            if let candidate, fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        let home = NSHomeDirectory()
        for candidate in [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            "\(home)/.local/bin/npm",
            "\(home)/.bun/bin/npm",
        ] where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// Run a command and return its stdout, or nil if it could not start or
    /// exceeded `timeout`. Used for the small npm queries the updater makes.
    ///
    /// stderr is captured rather than discarded. These commands are how the
    /// updater decides whether an update is even possible, and when one fails
    /// the reason is on stderr — nulling it turned "npm cannot write its cache"
    /// into an unexplained empty result, silently disabling every update.
    static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval,
        environment: [String: String]? = nil
    ) -> String? {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        do {
            try process.run()
        } catch {
            Log.shared.write("could not run \(executable): \(error.localizedDescription)")
            return nil
        }

        // Drain stderr on another queue: a child that fills the 64 KB pipe
        // buffer would otherwise block forever and hang the launch.
        let errorQueue = DispatchQueue(label: "dsh.locator.stderr")
        let errorBox = ErrorBox()
        let drained = DispatchSemaphore(value: 0)
        errorQueue.async {
            errorBox.data = errors.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            Log.shared.write("\(executable) timed out after \(Int(timeout))s")
            process.terminate()
            _ = drained.wait(timeout: .now() + 2)
            let text = String(data: errorBox.data, encoding: .utf8) ?? ""
            if !text.isEmpty { Log.shared.write("\(executable) stderr: \(Locator.condense(text, limit: 300))") }
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = drained.wait(timeout: .now() + 5)
        let stdout = String(data: data, encoding: .utf8) ?? ""

        // Report a failure even when the caller only wants stdout: an empty
        // result with no explanation is what makes this class of bug invisible.
        if process.terminationStatus != 0 {
            let text = String(data: errorBox.data, encoding: .utf8) ?? ""
            Log.shared.write(
                "\(executable) exited \(process.terminationStatus): \(Locator.condense(text, limit: 300))")
        }
        return stdout
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

// MARK: - Application support paths

/// Every path this app owns, in one place so tests can relocate the whole tree
/// with a single environment variable.
enum AppPaths {
    /// Root of the app's own writable state.
    static var support: URL {
        if let override = ProcessInfo.processInfo.environment["DSH_APP_SUPPORT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DeepSeekHarness")
    }

    static var slots: URL { support.appendingPathComponent("slots") }
    static var cache: URL { support.appendingPathComponent("npm-cache") }
    static var state: URL { support.appendingPathComponent("state.json") }

    static func slot(_ name: String) -> URL { slots.appendingPathComponent(name) }

    /// The `dsh` executable inside an installed slot.
    static func slotBinary(_ name: String) -> URL {
        slot(name).appendingPathComponent("node_modules/.bin/dsh")
    }

    static func ensureDirectories() {
        for url in [support, slots, cache] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Managed A/B installation

/// One installed copy of the harness. Two of these exist at a time, so an update
/// is always staged beside a known-good version rather than replacing it.
struct Slot: Codable {
    var version: String
    var installedAt: Date
    /// Set once this slot has been proven to boot and serve the GUI.
    var verifiedAt: Date?
    /// Set when this slot failed to boot; it is never chosen again until it is
    /// reinstalled.
    var broken: Bool = false
    /// When each recent early exit happened, oldest first.
    ///
    /// A version that starts and then dies seconds later is as broken as one
    /// that never starts, but it cannot be caught by the startup check alone.
    /// Counting these lets the app recognize a crash loop and abandon the
    /// version. Kept on disk so a loop that plays out across app launches —
    /// crash, quit, reopen, crash — is still counted.
    var earlyExits: [Date] = []

    var isUsable: Bool { verifiedAt != nil && !broken }

    /// Exits recent enough to still count toward a crash loop.
    func recentEarlyExits(window: TimeInterval) -> [Date] {
        let cutoff = Date().addingTimeInterval(-window)
        return earlyExits.filter { $0 >= cutoff }
    }
}

struct InstallState: Codable {
    var slots: [String: Slot] = [:]
    /// The slot to boot next. Moves only to a slot that has passed its health check.
    var preferred: String?
    /// A slot that was installed and verified but has not been booted yet.
    var staged: String?
    var updatedAt: Date?
    /// Versions that failed verification, mapped to why.
    ///
    /// Recorded so a release that cannot start is not downloaded and tested
    /// again on every single launch. "Check for Harness Updates" clears an entry
    /// and retries it, which is the escape hatch if a bad release is later
    /// republished under the same version.
    var rejected: [String: String] = [:]

    static let slotNames = ["a", "b"]

    /// The slot that is not `preferred`.
    func other(than name: String?) -> String {
        guard let name, Self.slotNames.contains(name) else { return Self.slotNames[0] }
        return Self.slotNames.first { $0 != name } ?? "b"
    }
}

/// What an update attempt actually did. Distinguishing these lets the app tell
/// the user something true — "already current" and "holding off to protect your
/// fallback" are very different from "it failed".
enum UpdateOutcome {
    /// A newer version was installed, verified, and will be used next launch.
    case staged(String)
    /// The running version is already the newest.
    case alreadyCurrent(String)
    /// The newest version previously failed to start, so it was not retried.
    case knownBad(String)
    /// Held off because the running version is still on trial and the other
    /// slot is the only known-good copy.
    case deferredTrial
    /// Nothing newer was available, or the install/verification failed.
    case unavailable(String?)

    /// The staged version, when there is one.
    var stagedVersion: String? {
        if case .staged(let version) = self { return version }
        return nil
    }

    /// A short explanation suitable for showing the user.
    var failureReason: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .knownBad(let version): return "Version \(version) failed to start earlier, so it was not retried."
        case .deferredTrial:
            return "The running version is still being watched to make sure it stays up."
        case .alreadyCurrent, .staged: return nil
        }
    }
}

/// Installs, updates, and verifies harness copies, keeping one known-good
/// version at all times. This mirrors how A/B system updates work: the running
/// version is never mutated, an update lands in the idle slot, and the boot slot
/// only moves after the new copy has proven it starts and serves the UI.
///
/// The app is usable from the moment the preferred slot starts; updating happens
/// afterwards, so a slow or failed download never blocks or breaks a launch.
/// Owns the installed harness copies and which one boots.
///
/// ## Threading
///
/// This type is thread-safe. `state` is reached from the main queue (the app's
/// own records: a boot succeeded, a version crashed) and from `queue` (an
/// update deciding what to install), so every read and write goes through
/// `lock`. The lock is recursive so the small helpers — `save`, `discard` —
/// can be called from inside a critical section without deadlocking.
///
/// Critical sections are kept to state alone. Nothing slow (npm, a health
/// check) and no caller's completion handler runs while the lock is held, so
/// the lock can never be the thing that hangs the UI.
final class ManagedInstall {
    private(set) var state = InstallState()
    private let queue = DispatchQueue(label: "dsh.managed-install")
    /// Serializes every access to `state`. Recursive because the mutating
    /// helpers below are called from within other critical sections.
    private let lock = NSRecursiveLock()
    private var installer: Process?

    /// Run `body` with exclusive access to `state`.
    private func withState<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Escape hatches: `DSH_MANAGED=0` restores the old behaviour of using
    /// whatever `dsh` is on PATH, and `DSH_SLOT_VERSION` pins a version instead
    /// of tracking the newest one.
    var isEnabled: Bool {
        let raw = ProcessInfo.processInfo.environment["DSH_MANAGED"] ?? "1"
        return !["0", "false", "no"].contains(raw.lowercased())
    }

    var pinnedVersion: String? {
        let raw = ProcessInfo.processInfo.environment["DSH_SLOT_VERSION"] ?? ""
        return raw.isEmpty ? nil : raw
    }

    /// Whether updates are staged in the background on launch. `DSH_NO_AUTO_UPDATE=1`
    /// keeps managed slots but stops the app from fetching anything on its own,
    /// which is what you want on a metered connection — "Check for Harness
    /// Updates" still works by hand.
    var autoUpdateEnabled: Bool {
        let raw = ProcessInfo.processInfo.environment["DSH_NO_AUTO_UPDATE"] ?? "0"
        return ["0", "false", "no"].contains(raw.lowercased())
    }

    init() {
        load()
    }

    // MARK: State

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.state),
            let decoded = try? JSONDecoder().decode(InstallState.self, from: data)
        else { return }
        state = decoded
    }

    func save() {
        AppPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        withState {
            if let data = try? encoder.encode(state) {
                try? data.write(to: AppPaths.state, options: .atomic)
            }
        }
    }

    /// Drop a slot's record and its files.
    private func discard(_ name: String) {
        withState {
            state.slots[name] = nil
            if state.preferred == name { state.preferred = nil }
            if state.staged == name { state.staged = nil }
        }
        try? FileManager.default.removeItem(at: AppPaths.slot(name))
    }

    // MARK: Resolving the harness to run

    /// The `dsh` this app should boot right now.
    ///
    /// Order matters: a staged update has already passed its health check and is
    /// meant to be tried next, so it comes first; the slot it replaces stays as
    /// the immediate fallback if the new one cannot boot. Only when no managed
    /// slot is usable does this fall back to whatever `dsh` is on PATH, so an
    /// existing install still works if the managed tree is unavailable.
    func resolveBootCandidate() -> (dsh: String, slot: String?)? {
        if isEnabled {
            let candidate: String? = withState {
                var order: [String] = []
                if let staged = state.staged { order.append(staged) }
                if let preferred = state.preferred, !order.contains(preferred) { order.append(preferred) }
                for name in InstallState.slotNames where !order.contains(name) { order.append(name) }

                for name in order {
                    guard let slot = state.slots[name], !slot.broken else { continue }
                    let binary = AppPaths.slotBinary(name).path
                    if FileManager.default.isExecutableFile(atPath: binary) {
                        return name
                    }
                }
                return nil
            }
            if let candidate { return (AppPaths.slotBinary(candidate).path, candidate) }
        }
        if let path = Locator.dshPath() { return (path, nil) }
        return nil
    }

    /// Mark a slot as having booted successfully, and promote a staged update to
    /// be the next boot.
    func recordHealthy(slot: String?) {
        guard let slot, isEnabled else { return }
        withState {
            state.slots[slot]?.verifiedAt = Date()
            state.slots[slot]?.broken = false
            // Booting the staged slot completes the update: it is now the one we
            // come back to, and the version it replaced becomes the fallback.
            if state.staged == slot {
                state.preferred = slot
                state.staged = nil
                Log.shared.write("update to \(state.slots[slot]?.version ?? "?") is now active")
            } else if state.preferred == nil {
                state.preferred = slot
            }
        }
        save()
    }

    /// Mark a slot as failing to boot, so it is not chosen again and the other
    /// slot is preferred instead.
    func recordBroken(slot: String?, reason: String) {
        guard let slot, isEnabled else { return }
        Log.shared.write("slot \(slot) failed to boot: \(reason)")
        withState {
            // Remember the version too, so the next update run does not download and
            // retest the exact release that just failed.
            if let version = state.slots[slot]?.version {
                state.rejected[version] = reason.split(separator: "\n").first.map(String.init) ?? reason
            }
            state.slots[slot]?.broken = true
            state.slots[slot]?.verifiedAt = nil
            state.staged = nil
            // Fall back to the other slot for the next attempt.
            let other = state.other(than: slot)
            if let candidate = state.slots[other], candidate.isUsable {
                state.preferred = other
                Log.shared.write("falling back to slot \(other) (\(candidate.version))")
            }
        }
        save()
    }

    // MARK: Updating

    /// Bring the idle slot up to date and verify it, in the background.
    ///
    /// Never touches the slot that is currently booted. On success the idle slot
    /// becomes `staged` and is used on the next launch; on failure it is
    /// discarded and the running version is untouched.
    ///
    /// The completion handler is always called on the **main** queue, whichever
    /// path produced the outcome. The early guard runs on the caller's thread,
    /// the work runs on `queue`, and the callers are UI code that must not be
    /// surprised by which one they got; before this was uniform, one branch
    /// mutated and saved state from the background queue while every other
    /// branch hopped to main.
    func updateIdleSlot(
        activeSlot: String?, force: Bool = false, completion: @escaping (UpdateOutcome) -> Void
    ) {
        let finish: (UpdateOutcome) -> Void = { outcome in
            DispatchQueue.main.async { completion(outcome) }
        }
        guard isEnabled else { return finish(.unavailable("managed updates are off")) }

        queue.async { [weak self] in
            guard let self else { return finish(.unavailable(nil)) }
            let target = self.withState { self.state.other(than: activeSlot) }

            if activeSlot == nil {
                Log.shared.write("update: no managed slot yet, provisioning slot \(target)")
            }

            guard let npm = Locator.npmPath() else {
                Log.shared.write("update skipped: npm not found")
                return finish(.unavailable("npm was not found"))
            }

            let wanted = self.pinnedVersion ?? self.latestVersion(npm: npm)
            guard let wanted else {
                Log.shared.write("update skipped: could not determine the newest version")
                return finish(.unavailable("the newest version could not be determined"))
            }

            // Nothing to do when the running slot is already newest. Without
            // this, every launch would install the same version into the idle
            // slot and swap between them pointlessly.
            if !force, let active = activeSlot,
                self.withState({ self.state.slots[active]?.version }) == wanted
            {
                Log.shared.write("update: running slot \(active) is already the newest (\(wanted))")
                return finish(.alreadyCurrent(wanted))
            }

            // Do not keep retrying a release that already failed to start.
            if !force, let why = self.withState({ self.state.rejected[wanted] }) {
                Log.shared.write("update: \(wanted) is known bad (\(why)); not retrying")
                return finish(.knownBad(wanted))
            }

            // Refuse to overwrite the fallback while the running version is
            // still on trial. Installing replaces the target slot's contents,
            // and during the trial period the other slot is the only known-good
            // copy — the one that will be needed if this version turns out to
            // crash. Regaining a newer version later is cheap; losing the
            // fallback is not.
            let targetIsFallback = self.withState { () -> Bool in
                guard let active = activeSlot, let activeInfo = self.state.slots[active],
                    let verified = activeInfo.verifiedAt,
                    Date().timeIntervalSince(verified) < Self.earlyExitSeconds
                else { return false }
                return self.state.slots[target]?.isUsable == true
            }
            if targetIsFallback, let active = activeSlot {
                Log.shared.write(
                    "update deferred: slot \(active) is still on trial and slot \(target) is the fallback")
                return finish(.deferredTrial)
            }

            // Already have this version staged and verified? Nothing to do.
            let alreadyStaged = self.withState { () -> Bool in
                guard let existing = self.state.slots[target], existing.version == wanted,
                    existing.verifiedAt != nil, !existing.broken
                else { return false }
                return FileManager.default.isExecutableFile(atPath: AppPaths.slotBinary(target).path)
            }
            if alreadyStaged {
                Log.shared.write("update: slot \(target) already holds \(wanted)")
                self.markStaged(target, version: wanted, activeSlot: activeSlot)
                return finish(.staged(wanted))
            }

            Log.shared.write("update: installing \(wanted) into slot \(target)")
            self.install(npm: npm, slot: target, version: wanted) { ok in
                guard ok else {
                    Log.shared.write("update: install failed; keeping the running version")
                    self.discard(target)
                    self.save()
                    return finish(.unavailable("the download or install failed"))
                }

                // Prove the new copy boots and serves the GUI before trusting it.
                let binary = AppPaths.slotBinary(target).path
                Log.shared.write("update: verifying slot \(target)")
                let verdict = Self.healthCheck(dsh: binary)

                // It started, so record it. Reading the verdict and writing the
                // outcome happen together, so a crash report arriving from the
                // main queue cannot interleave between the two.
                if let verdict {
                    Log.shared.write("update: slot \(target) failed verification (\(verdict)); discarding")
                    // Remember the version, not just the slot: there is no
                    // point downloading a release that cannot start again
                    // on the next launch.
                    self.withState { self.state.rejected[wanted] = verdict }
                    self.discard(target)
                    self.save()
                    return finish(.unavailable(verdict))
                }
                self.withState {
                    self.state.rejected[wanted] = nil
                    self.state.slots[target] = Slot(
                        version: wanted, installedAt: Date(), verifiedAt: Date(), broken: false)
                }
                self.markStaged(target, version: wanted, activeSlot: activeSlot)
                Log.shared.write("update: \(wanted) verified in slot \(target), ready for next launch")
                return finish(.staged(wanted))
            }
        }
    }

    private func markStaged(_ target: String, version: String, activeSlot: String?) {
        withState {
            self.state.staged = target
            // When nothing has been booted from a slot yet, this becomes the boot slot.
            if self.state.preferred == nil { self.state.preferred = target }
            self.state.updatedAt = Date()
        }
        self.save()
    }

    /// The newest version available to install.
    ///
    /// Queried through the app's own npm cache: a shared cache can be owned by
    /// another user (a `sudo npm` at some point is enough), and npm then prints
    /// nothing at all rather than failing loudly, which would silently disable
    /// updates.
    private func latestVersion(npm: String) -> String? {
        let output = Locator.run(
            npm, ["view", "@deepseek-ai/dsh", "version"], timeout: 120,
            environment: ["npm_config_cache": AppPaths.cache.path])
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // npm prints extra notices on some channels; the version is the last
        // line that looks like one.
        let candidate = trimmed
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.first?.isNumber == true && $0.contains(".") }
        if candidate == nil {
            Log.shared.write("could not determine the newest version (npm output: \(trimmed.prefix(200)))")
        }
        return candidate
    }

    /// Install one version into a slot with npm, into a dedicated cache so the
    /// user's own npm cache is never disturbed.
    private func install(npm: String, slot: String, version: String, completion: @escaping (Bool) -> Void) {
        AppPaths.ensureDirectories()
        let prefix = AppPaths.slot(slot)
        // Start from a clean slot: npm would otherwise leave a half-updated tree.
        try? FileManager.default.removeItem(at: prefix)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npm)
        process.arguments = [
            "install", "--prefix", prefix.path, "--cache", AppPaths.cache.path,
            "--no-audit", "--no-fund", "--loglevel", "error",
            "@deepseek-ai/dsh@\(version)",
        ]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        // npm resolution sometimes needs the user's PATH (for node-gyp, git).
        var environment = ProcessInfo.processInfo.environment
        environment["npm_config_cache"] = AppPaths.cache.path
        environment["npm_config_update_notifier"] = "false"
        process.environment = environment

        installer = process
        do {
            try process.run()
        } catch {
            Log.shared.write("update: could not start npm: \(error.localizedDescription)")
            return completion(false)
        }

        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        installer = nil

        let status = process.terminationStatus
        if status != 0 {
            let text = String(data: data, encoding: .utf8) ?? ""
            Log.shared.write("update: npm exited \(status): \(text.suffix(600))")
        }
        completion(status == 0)
    }

    func cancelInstaller() {
        guard let installer, installer.isRunning else { return }
        installer.terminate()
    }

    // MARK: Crash-loop handling

    /// A run shorter than this is treated as "the version cannot stay up" rather
    /// than an unrelated crash. Long enough to survive slow first-render work,
    /// short enough that a genuine startup crash is always caught.
    static let earlyExitSeconds: TimeInterval = 60

    /// How many early exits, within the window, mean the version is abandoned.
    static let crashLoopLimit = 3

    /// How far back early exits are counted.
    static let crashWindow: TimeInterval = 15 * 60

    /// Record an exit that happened soon after the harness became ready.
    ///
    /// Returns true when this completes a crash loop, meaning the caller should
    /// abandon this version and switch slots.
    func recordEarlyExit(slot: String?, uptime: TimeInterval) -> Bool {
        guard let slot, isEnabled else { return false }

        /// What the locked section decided, so the logging and the disk write
        /// happen outside it.
        enum Verdict {
            case noRecord
            case staleCleared
            case notEvidence
            case recorded(count: Int)
        }

        // Read, decide, and write under a single acquisition: a crash report and
        // an update's state write must not interleave, or one of them is lost.
        let verdict = withState { () -> Verdict in
            guard let existing = state.slots[slot] else { return .noRecord }

            // Only a quick death implicates the version. Something that ran for a
            // good while and then stopped is not evidence about the release.
            guard uptime < Self.earlyExitSeconds else {
                guard !existing.earlyExits.isEmpty else { return .notEvidence }
                state.slots[slot]?.earlyExits = []
                return .staleCleared
            }

            var recent = existing.recentEarlyExits(window: Self.crashWindow)
            recent.append(Date())
            state.slots[slot]?.earlyExits = recent
            return .recorded(count: recent.count)
        }

        switch verdict {
        case .noRecord, .notEvidence:
            return false
        case .staleCleared:
            Log.shared.write("slot \(slot) ran \(Int(uptime))s; clearing its crash history")
            save()
            return false
        case .recorded(let count):
            save()
            Log.shared.write(
                "slot \(slot) exited after \(Int(uptime))s; \(count) of \(Self.crashLoopLimit) early exits in the window")
            return count >= Self.crashLoopLimit
        }
    }

    /// The version currently designated to boot, for messages.
    func version(of slot: String?) -> String? {
        guard let slot else { return nil }
        return withState { state.slots[slot]?.version }
    }

    /// Mark a slot as having proven itself: it served, and it kept serving for
    /// long enough that it is no longer a crash-loop suspect.
    func recordStable(slot: String?) {
        withState {
            guard let slot, isEnabled, state.slots[slot] != nil else { return }
            if !(state.slots[slot]?.earlyExits.isEmpty ?? true) {
                Log.shared.write("slot \(slot) proved stable; clearing its crash history")
            }
            state.slots[slot]?.earlyExits = []
            state.slots[slot]?.verifiedAt = Date()
        }
        save()
    }

    /// Whether the idle slot currently holds a usable copy of the harness — the
    /// one that would be lost if an update overwrote it.
    func idleSlotIsFallback(activeSlot: String?) -> Bool {
        withState { state.slots[state.other(than: activeSlot)]?.isUsable == true }
    }

    /// The slot the next boot should use, for callers that only need to look.
    var preferredSlot: String? { withState { state.preferred } }

    /// The slot holding a verified update waiting for the next launch.
    var stagedSlot: String? { withState { state.staged } }

    /// Test seam: install a slot record directly.
    func setSlot(_ name: String, _ slot: Slot) { withState { state.slots[name] = slot } }

    /// Boot a candidate copy on an ephemeral port and confirm it really serves
    /// the GUI. This is the gate every update must pass before it can be booted,
    /// and it is what makes a broken upstream commit a non-event.
    ///
    /// Returns nil when healthy, or a short reason when not.
    ///
    /// This runs on `ManagedInstall`'s background queue and blocks it until the
    /// candidate answers, so it is deliberately self-contained: it drives its
    /// own `HarnessServer` on a private queue and polls two `Handoff` boxes.
    /// Nothing here touches the main queue or needs a run loop, which matters
    /// because there is no main-queue pump during an update and because the
    /// caller may itself be the main thread (the tests call it that way).
    static func healthCheck(dsh: String, timeout: TimeInterval = 120) -> String? {
        let queue = DispatchQueue(label: "dsh.health-check")
        let server = HarnessServer(callbackQueue: queue)
        let ready = Handoff<URL>()
        let failure = Handoff<String>()

        // Start on the server's own queue so its threading contract holds.
        queue.sync {
            server.onReady = { ready.set($0) }
            server.onFailure = { reason, _ in failure.set(reason) }
            server.start(preferredPort: 0, dsh: dsh)
        }

        func awaitOutcome(until deadline: Date) -> String? {
            while Date() < deadline {
                if ready.value != nil { return nil }
                if let reason = failure.value { return reason }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return nil
        }

        let startupDeadline = Date().addingTimeInterval(timeout)
        let failed = awaitOutcome(until: startupDeadline)

        guard let url = ready.value else {
            queue.sync { server.stop() }
            // Keep the tail of the output: that is where Node puts the actual
            // error, and it is what makes a failed update diagnosable.
            return Locator.condense(
                failed ?? "no listening port within \(Int(timeout))s")
        }

        let status = Handoff<Int>()
        let httpDone = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { _, response, _ in
            if let code = (response as? HTTPURLResponse)?.statusCode { status.set(code) }
            httpDone.signal()
        }
        task.resume()
        // The semaphore supplies the ordering the old captured-`var` read did
        // not have: the write in the completion happens-before this returns.
        _ = httpDone.wait(timeout: .now() + 30)

        queue.sync { server.stop() }

        guard let code = status.value else { return "the GUI did not respond" }
        guard code == 200 else { return "the GUI returned \(code)" }
        return nil
    }
}

// MARK: - Server process

/// A value handed from a callback thread to a waiting thread.
///
/// The obvious spelling — a captured `var` written in a completion handler and
/// read by the thread that waits — is a data race, and one this code actually
/// had. `URLSession` delivers its completion on its own queue while the caller
/// polls, so the two accesses are genuinely concurrent and unsynchronized; that
/// it usually happens to work is luck, not ordering. Swift 6 flags the pattern
/// statically, and ThreadSanitizer reports it at runtime.
///
/// The lock makes the hand-off explicit. It is deliberately tiny: a lock is the
/// right tool here precisely because the critical section is one assignment, and
/// callers need to poll without blocking on a queue.
final class Handoff<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    init() {}

    func set(_ value: T) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: T? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Owns one `dsh web` child process for the lifetime of the window.
///
/// ## Threading
///
/// Every stored property is touched only on `callbackQueue`: `start`, `stop`,
/// the pipe handlers, the termination handler, and the startup ceiling all run
/// there, and `onReady`/`onFailure` are delivered there. The default is the main
/// queue, which is what the app wants — the UI owns the server, and the server
/// owns a child process whose teardown can block for seconds.
///
/// `healthCheck` is the one caller that needs something else. It runs on a
/// background queue during an update and must block until it has an answer, so
/// it gives its server a private queue and polls the result. That is also why
/// the startup ceiling below is scheduled on `callbackQueue` rather than on the
/// main queue directly: a health check has no main-queue pump of its own, and
/// scheduling onto a queue nobody is draining would silently drop the timeout.
final class HarnessServer {
    private let callbackQueue: DispatchQueue

    init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
    }

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
    /// Reports a failure. `atStartup` is true when the harness never reported a
    /// listening port, which is the case the A/B recovery path acts on: a
    /// version that cannot boot is rolled back, while one that dies mid-session
    /// is reported without blaming the version.
    var onFailure: ((_ reason: String, _ atStartup: Bool) -> Void)?

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

    func start(preferredPort: Int, dsh explicitDsh: String? = nil, workingDirectory: String? = nil) {
        stop()

        guard let dsh = explicitDsh ?? Locator.dshPath() else {
            onFailure?("""
                Could not find the `dsh` command.

                Install it with:  npm i -g @deepseek-ai/dsh
                Or point this app at an existing copy with the DSH_BIN environment variable.
                """, true)
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
        if let workingDirectory { child.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }

        generation += 1
        let token = generation
        readySeen = false
        shuttingDown = false
        tail.removeAll()
        scanBuffer.removeAll()

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let self else { return }
            self.callbackQueue.async { self.ingest(stdout: text, generation: token) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let self else { return }
            self.callbackQueue.async { self.ingest(stderr: text, generation: token) }
        }

        child.terminationHandler = { [weak self] exited in
            guard let self else { return }
            self.callbackQueue.async {
                guard self.generation == token else { return }
                self.detachPipes()
                self.isRunning = false
                let status = exited.terminationStatus
                Log.shared.write("dsh exited with status \(status)")
                // A deliberate stop is not a crash: the user asked for it, and
                // on quit nothing would be left to display an error anyway.
                guard !self.shuttingDown else { return }
                guard !self.readySeen else {
                    self.onFailure?("The Harness server stopped unexpectedly (exit \(status)).\n\n\(self.recentLog())", false)
                    return
                }
                self.onFailure?("The Harness server exited during startup (exit \(status)).\n\n\(self.recentLog())", true)
            }
        }

        do {
            try child.run()
        } catch {
            onFailure?("Could not start the Harness: \(error.localizedDescription)", true)
            return
        }

        process = child
        stdoutPipe = stdout
        stderrPipe = stderr
        isRunning = true
        Log.shared.write("dsh started with pid \(child.processIdentifier)")

        // Startup ceiling: a hung or misconfigured harness must not leave a
        // spinner forever. Scheduled on the callback queue, not the main queue
        // directly, so a health check on a private queue still gets its timeout.
        callbackQueue.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.generation == token, !self.readySeen else { return }
            self.onFailure?("The Harness did not report a listening port within 120s.\n\n\(self.recentLog())", true)
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

// MARK: - Screenshots

/// A request to render the window to a file, used to produce documentation
/// images without screen recording permission.
struct ScreenshotRequest {
    /// Whether to include a sample notice, so the README can show one.
    enum Note: Equatable {
        case none
        case rollback
        case staged

        var message: (title: String, detail: String)? {
            switch self {
            case .none:
                return nil
            case .rollback:
                return (
                    "Harness 0.1.6 did not start — back on 0.1.5",
                    "It never began serving the interface, so the app switched back automatically. "
                        + "0.1.6 will not be tried again. See the log for details."
                )
            case .staged:
                return (
                    "Harness 0.1.5 is ready",
                    "Verified and waiting. It will be used the next time this app launches."
                )
            }
        }
    }

    let path: String
    let note: Note

    /// Parse `--screenshot <path> [--notice rollback|staged]`, or nil when the
    /// app is being launched normally.
    init?(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--screenshot") else { return nil }
        guard arguments.index(after: flag) < arguments.endIndex else {
            Log.shared.write("--screenshot needs a destination path")
            exit(2)
        }
        path = arguments[arguments.index(after: flag)]

        var parsed = Note.none
        if let noticeFlag = arguments.firstIndex(of: "--notice"),
            arguments.index(after: noticeFlag) < arguments.endIndex
        {
            switch arguments[arguments.index(after: noticeFlag)] {
            case "rollback": parsed = .rollback
            case "staged": parsed = .staged
            default: parsed = .none
            }
        }
        note = parsed
    }
}

// MARK: - Notice card
/// A small floating card reporting something about the app itself: an update
/// that is ready, or a version that was rolled back.
///
/// Deliberately a card and not a full-width bar. The window is showing the
/// harness's own UI, and an opaque strip across the top of it would cover that
/// UI's header while looking like part of it. It is also fully opaque: a
/// translucent notice over live content is hardest to read for exactly the
/// messages that matter most.
final class NoticeCard: NSView {
    enum Kind {
        case info
        case warning

        var accent: NSColor {
            switch self {
            case .info: return .systemBlue
            case .warning: return .systemOrange
            }
        }

        var symbol: String {
            switch self {
            case .info: return "arrow.down.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }
    }

    let kind: Kind
    /// Called when the user dismisses the card, so the owner can clear it.
    var onDismiss: (() -> Void)?

    /// Widest the card grows before its text wraps.
    static let maximumWidth: CGFloat = 460

    private let closeButton = NSButton()
    private let iconView = NSImageView()

    init(kind: Kind, title: String, detail: String) {
        self.kind = kind
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // An opaque, adaptive background: controlBackgroundColor tracks light
        // and dark mode and hides whatever the window is showing underneath.
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        // The shadow needs an unclipped layer. Nothing is drawn outside the
        // card's bounds, so the rounded background still reads correctly.
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.30
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        iconView.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        iconView.contentTintColor = kind.accent
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 3
        titleLabel.preferredMaxLayoutWidth = Self.maximumWidth - 78

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 6
        detailLabel.preferredMaxLayoutWidth = Self.maximumWidth - 78

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.toolTip = "Dismiss"

        let row = NSStackView(views: [iconView, text, closeButton])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),

            iconView.widthAnchor.constraint(equalToConstant: 17),
            iconView.heightAnchor.constraint(equalToConstant: 17),
            closeButton.widthAnchor.constraint(equalToConstant: 15),
            closeButton.heightAnchor.constraint(equalToConstant: 15),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func closeTapped() { onDismiss?() }
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

// MARK: - Lifecycle

/// What the lifecycle asks the window to show.
///
/// The lifecycle decides *what should happen* — which copy to boot, when to
/// abandon a version, when to check for an update — and the delegate decides
/// how that looks. Keeping the two apart is what stops the update rules from
/// being tangled up with the views that report them, and it is where the
/// threading contract lives: every one of these is called on the main queue.
protocol HarnessLifecycleUIDelegate: AnyObject {
    func lifecycleShowWorking(_ title: String, detail: String)
    func lifecycleShowFailure(_ reason: String)
    func lifecycleDidLoad(url: URL)
    func lifecycleShowBanner(title: String, detail: String, kind: NoticeCard.Kind)
    func lifecycleDismissBanner()
    func lifecycleDidStageUpdate(version: String)
    func lifecycleDidRollBack(
        failed: String, recovered: String, reason: String, cause: HarnessLifecycle.RollbackCause)
}

/// Decides which harness to run, keeps it running, and recovers when it cannot.
///
/// This is the half of the old `AppDelegate` that had nothing to do with AppKit:
/// booting a copy, watching it, attributing a failure to a version, and
/// promoting or abandoning slots. It owns the server and the installed state;
/// it owns no views.
///
/// ## Threading
///
/// Main queue only. Every entry point is called from AppKit, `HarnessServer`
/// delivers its callbacks on the main queue, and `ManagedInstall` is separately
/// thread-safe for the work it does on its own queue.
final class HarnessLifecycle {
    weak var delegate: HarnessLifecycleUIDelegate?

    /// The token-bearing URL, kept so Reload re-authenticates rather than
    /// hitting a 401 on the clean root.
    private(set) var authenticatedURL: URL?

    private let server = HarnessServer()
    private let managed = ManagedInstall()
    private var isStarting = false
    /// The managed slot currently being booted, so a startup failure can be
    /// attributed to a specific installed version.
    private var bootingSlot: String?
    /// The slot whose server is actually serving right now. Kept separate from
    /// `bootingSlot` so a crash later in the session is still attributed to the
    /// right version.
    private var runningSlot: String?
    /// When the current server became ready, used to tell a startup crash from
    /// an unrelated failure much later in the session.
    private var readyAt: Date?
    /// The pending background update, cancelled and rescheduled whenever a new
    /// server starts.
    private var updateWorkItem: DispatchWorkItem?
    private let preferredPort: Int

    init(preferredPort: Int = HarnessLifecycle.defaultPort) {
        self.preferredPort = preferredPort
        wireServer()
    }

    static var defaultPort: Int {
        let raw = ProcessInfo.processInfo.environment["DSH_WRAPPER_PORT"] ?? ""
        return Int(raw).flatMap { $0 > 0 && $0 < 65536 ? $0 : nil } ?? 3080
    }

    var managedUpdatesEnabled: Bool { managed.isEnabled }

    /// Whether a harness process is currently up, for the window's own
    /// navigation-failure message.
    var isServerRunning: Bool { server.isRunning }

    /// The tail of the harness output, for that same message.
    var recentServerLog: String { server.recentLog() }

    /// Why a version is being abandoned, which decides how it is explained.
    enum RollbackCause {
        /// The harness never reported a listening port.
        case failedToStart
        /// It served, then died soon after, repeatedly.
        case crashLoop
    }

    // MARK: Server callbacks

    private func wireServer() {
        server.onReady = { [weak self] url in
            guard let self else { return }
            self.isStarting = false
            self.authenticatedURL = url
            self.readyAt = Date()
            // This copy demonstrably boots and serves, so record it as good and,
            // if it was a staged update, make it the version we return to.
            // Only a real slot promotion counts. Comparing optionals directly
            // would treat "no slot at all" as a promotion, since nil == nil.
            let promoted = self.bootingSlot.map { self.managed.stagedSlot == $0 } ?? false
            self.managed.recordHealthy(slot: self.bootingSlot)
            if promoted { Log.shared.write("running the newly installed harness") }
            self.runningSlot = self.bootingSlot
            self.bootingSlot = nil
            self.delegate?.lifecycleDismissBanner()
            self.delegate?.lifecycleDidLoad(url: url)
            self.updateIdleSlotInBackground()
        }
        server.onFailure = { [weak self] reason, atStartup in
            guard let self else { return }
            self.isStarting = false
            // Mirror to the log: the overlay is easy to miss, and a startup
            // failure is precisely what someone reads the log to explain.
            Log.shared.write("start failure (atStartup=\(atStartup)): \(reason)")

            guard self.managed.isEnabled else { return self.showFailure(reason) }

            if atStartup {
                // It never served, so the version itself is the suspect.
                if let failed = self.bootingSlot {
                    self.rollBack(from: failed, reason: reason, cause: .failedToStart)
                } else {
                    self.showFailure(reason)
                }
                return
            }

            // It was serving and then stopped. A version that dies soon after
            // starting is just as broken as one that never starts, so count
            // those and switch slots once they repeat; a long healthy run
            // followed by a stop is treated as transient and simply restarted.
            let uptime = self.readyAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            if let slot = self.runningSlot,
                self.managed.recordEarlyExit(slot: slot, uptime: uptime)
            {
                self.rollBack(from: slot, reason: reason, cause: .crashLoop)
                return
            }

            if self.runningSlot != nil {
                self.delegate?.lifecycleShowBanner(
                    title: "The Harness stopped unexpectedly — restarting it",
                    detail: """
                        \(reason.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? reason)
                        If this keeps happening, the app will switch back to the previous version automatically.
                        """,
                    kind: .warning)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.start(reason: "auto-restart after an unexpected exit", force: true)
                }
                return
            }
            self.showFailure(reason)
        }
    }

    private func showFailure(_ reason: String) {
        delegate?.lifecycleShowFailure(reason)
    }

    /// Automatic recovery: mark the failed copy unusable, boot the other one,
    /// and tell the user plainly what happened and which version they are on.
    private func rollBack(from failedSlot: String, reason: String, cause: RollbackCause) {
        let failedVersion = managed.version(of: failedSlot) ?? "the updated harness"
        managed.recordBroken(slot: failedSlot, reason: reason)
        runningSlot = nil

        guard let next = managed.resolveBootCandidate(), next.slot != failedSlot else {
            // Nothing left to fall back to: report the original failure.
            showFailure(managed.isEnabled
                ? "Neither installed copy of the Harness could start.\n\n\(reason)"
                : reason)
            return
        }

        let recoveredVersion = next.slot.flatMap { managed.version(of: $0) } ?? "your system install"
        Log.shared.write("rolled back from \(failedVersion) to \(recoveredVersion)")

        delegate?.lifecycleDidRollBack(
            failed: failedVersion, recovered: recoveredVersion, reason: reason, cause: cause)
        launch(dsh: next.dsh, slot: next.slot)
    }

    // MARK: Starting

    func start(reason: String, force: Bool = false) {
        if isStarting && !force {
            Log.shared.write("ignoring start request (\(reason)): one is already in flight")
            return
        }
        isStarting = true
        Log.shared.write("start requested by: \(reason)")

        guard managed.isEnabled else {
            // Unmanaged: use whatever `dsh` the user has, exactly as before.
            guard let dsh = Locator.dshPath() else {
                showFailure("""
                    Could not find the `dsh` command.

                    Install it with:  npm i -g @deepseek-ai/dsh
                    Or point this app at an existing copy with the DSH_BIN environment variable.
                    """)
                return
            }
            launch(dsh: dsh, slot: nil)
            return
        }

        if let candidate = managed.resolveBootCandidate() {
            // A candidate with no slot means it came from PATH. That is the
            // first-run case: use the harness already installed so the launch is
            // instant rather than a download, and provision a managed slot in
            // the background once it is serving. This is also what makes
            // switching to this app non-destructive — the first run behaves
            // exactly like whatever you were using before.
            if candidate.slot == nil {
                Log.shared.write(
                    "no managed slot yet; booting the installed dsh and provisioning one in the background")
            }
            launch(dsh: candidate.dsh, slot: candidate.slot)
            return
        }

        // Nothing installed anywhere: the first run has to fetch one.
        provisionFirstSlot()
    }

    /// Boot a specific copy of the harness.
    private func launch(dsh: String, slot: String?) {
        bootingSlot = slot
        readyAt = nil
        // Name the exact copy being started: when two versions are in play, the
        // log is how you tell which one you were actually running.
        if let slot {
            let version = managed.version(of: slot) ?? "?"
            Log.shared.write("booting managed slot \(slot) (harness \(version)): \(dsh)")
        } else {
            Log.shared.write("booting the harness from PATH: \(dsh)")
        }
        let detail = slot.map { "managed slot \($0)" } ?? "your installed dsh"
        delegate?.lifecycleShowWorking("Starting DeepSeek Harness…", detail: detail)
        server.start(preferredPort: preferredPort, dsh: dsh)
    }

    /// Install the first managed copy. Only reached when no copy is usable, so
    /// it is normally a one-time, first-run step.
    private func provisionFirstSlot() {
        delegate?.lifecycleShowWorking(
            "Installing DeepSeek Harness…",
            detail: "fetching the harness into a managed slot (first run only)")
        managed.updateIdleSlot(activeSlot: nil) { [weak self] outcome in
            guard let self else { return }
            guard let candidate = self.managed.resolveBootCandidate() else {
                self.showFailure("""
                    Could not install DeepSeek Harness.

                    \(outcome.failureReason ?? "The first run needs network access to fetch it.")
                    If you would rather use a harness you already have, launch with DSH_MANAGED=0.
                    """)
                return
            }
            Log.shared.write("provisioned harness \(outcome.stagedVersion ?? "?")")
            self.launch(dsh: candidate.dsh, slot: candidate.slot)
        }
    }

    func stop() {
        server.stop()
    }

    func cancelInstaller() {
        managed.cancelInstaller()
    }

    // MARK: Updates

    /// Stage the newest version into the idle slot while the app runs, so the
    /// next launch starts the new harness and can still fall back to this one.
    ///
    /// Deliberately waits until the running version has been up for the trial
    /// period. The idle slot is the fallback, and an update replaces its
    /// contents — so updating it while a freshly installed version is still on
    /// trial would destroy the only known-good copy at exactly the moment it
    /// might be needed. Only once the running version has proven it stays up
    /// does the other slot become expendable.
    private func updateIdleSlotInBackground() {
        guard managed.isEnabled, managed.autoUpdateEnabled else { return }
        updateWorkItem?.cancel()

        let slot = runningSlot ?? managed.preferredSlot
        // The trial wait exists to protect the fallback, so it only applies when
        // there is one. A first run with nothing installed yet can start right
        // away.
        let elapsed = readyAt.map { Date().timeIntervalSince($0) } ?? 0
        let wait = managed.idleSlotIsFallback(activeSlot: slot)
            ? max(ManagedInstall.earlyExitSeconds - elapsed, 5)
            : 5

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.managed.recordStable(slot: slot)
            self.managed.updateIdleSlot(activeSlot: slot) { [weak self] outcome in
                guard let self, let version = outcome.stagedVersion else { return }
                self.delegate?.lifecycleDidStageUpdate(version: version)
            }
        }
        updateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    /// Bring the idle slot up to date at the user's request. The outcome is
    /// handed back for the caller to explain; the lifecycle has no opinion about
    /// what a "not yet" looks like on screen.
    func checkForUpdates(completion: @escaping (UpdateOutcome) -> Void) {
        managed.updateIdleSlot(activeSlot: runningSlot ?? managed.preferredSlot, force: true) {
            [weak self] outcome in
            guard self != nil else { return }
            completion(outcome)
        }
    }

    /// Ask for the idle slot to be reinstalled, so its outcome is `staged` even
    /// when it was already newest.
    func reinstallIdleSlot(completion: @escaping (UpdateOutcome) -> Void) {
        checkForUpdates(completion: completion)
    }
}

// MARK: - Application

/// The window, the menu, and the notice cards.
///
/// Everything about *how the app looks and responds*; everything about *which
/// harness runs and what happens when it does not* is `HarnessLifecycle`. The
/// two meet at `HarnessLifecycleUIDelegate`.
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate,
    HarnessLifecycleUIDelegate
{
    private var window: NSWindow!
    private var webView: WKWebView!
    private var overlay: StatusOverlay!
    private lazy var lifecycle = HarnessLifecycle()
    /// Retained so the signal handlers stay installed.
    private var signalSources: [DispatchSourceSignal] = []
    /// The floating notice currently on screen, if any.
    private var banner: NoticeCard?
    /// Pending auto-dismiss for an informational notice.
    private var bannerDismissWork: DispatchWorkItem?
    /// Set when the app is rendering itself to a file for documentation.
    private var pendingScreenshot: ScreenshotRequest?

    // MARK: Lifecycle delegate

    func lifecycleShowWorking(_ title: String, detail: String) {
        overlay.showWorking(title, detail: detail)
    }

    func lifecycleShowFailure(_ reason: String) {
        let split = reason.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        overlay.showFailure(
            String(split.first ?? "The Harness could not start."),
            detail: split.count > 1 ? String(split[1]) : "")
    }

    func lifecycleDidLoad(url: URL) {
        webView.load(URLRequest(url: url))
    }

    func lifecycleShowBanner(title: String, detail: String, kind: NoticeCard.Kind) {
        showBanner(title, detail: detail, kind: kind)
    }

    func lifecycleDismissBanner() {
        dismissBanner()
    }

    func lifecycleDidStageUpdate(version: String) {
        reportUpdateStaged(version)
    }

    func lifecycleDidRollBack(
        failed: String, recovered: String, reason: String, cause: HarnessLifecycle.RollbackCause
    ) {
        alertRollback(failed: failed, recovered: recovered, reason: reason, cause: cause)
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.shared.write("launched; log at \(Log.shared.logPath)")
        installSignalHandlers()
        buildMenu()
        buildWindow()
        lifecycle.delegate = self

        // Documentation mode: the app renders its own window to a file. This is
        // how the README's screenshots are produced without depending on screen
        // recording permission, and it captures the real webview rather than an
        // approximation of it.
        if let request = ScreenshotRequest(arguments: arguments) {
            pendingScreenshot = request
            // A fixed size keeps screenshots consistent between runs.
            window.setContentSize(NSSize(width: 1280, height: 820))
        }

        lifecycle.start(reason: "app launch")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Capture the window to a PNG, then optionally show a notice and quit.
    ///
    /// The webview draws out of process, so its pixels are taken with the
    /// snapshot API rather than by caching the view, which would come back
    /// blank. The window chrome is drawn alongside it so the result looks like
    /// the app rather than a bare web page.
    private func captureWindow(to path: String, note: ScreenshotRequest.Note) {
        pendingScreenshot = nil

        // Let the frontend finish its first paint, and give the notice card a
        // moment to animate in when one is being shown.
        let settle: TimeInterval = note == .none ? 2.5 : 1.0

        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self else { return }

            if let message = note.message {
                self.showBanner(message.title, detail: message.detail, kind: .warning)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + (note == .none ? 0.4 : 1.2)) {
                let configuration = WKSnapshotConfiguration()
                configuration.rect = self.webView.bounds
                self.webView.takeSnapshot(with: configuration) { image, error in
                    guard let image else {
                        Log.shared.write("screenshot failed: \(error?.localizedDescription ?? "no image")")
                        exit(1)
                    }
                    self.composeAndWrite(image, to: path)
                }
            }
        }
    }

    /// Draw the window chrome around the captured page and write the result out.
    ///
    /// `lockFocus` uses an unflipped, bottom-left origin, so the page sits at
    /// the bottom of the composite and the title bar goes *above* it. Getting
    /// this backwards draws the bar underneath the page, where the page then
    /// paints over it.
    private func composeAndWrite(_ page: NSImage, to path: String) {
        let titleHeight: CGFloat = 28
        let pageSize = page.size
        let size = NSSize(width: pageSize.width, height: pageSize.height + titleHeight)

        let composite = NSImage(size: size)
        composite.lockFocus()

        // Round only the top corners, the way a real window is shaped.
        let radius: CGFloat = 10
        let shape = NSBezierPath()
        shape.move(to: NSPoint(x: 0, y: 0))
        shape.line(to: NSPoint(x: 0, y: size.height - radius))
        shape.appendArc(
            withCenter: NSPoint(x: radius, y: size.height - radius), radius: radius,
            startAngle: 180, endAngle: 90)
        shape.line(to: NSPoint(x: size.width - radius, y: size.height))
        shape.appendArc(
            withCenter: NSPoint(x: size.width - radius, y: size.height - radius), radius: radius,
            startAngle: 90, endAngle: 0)
        shape.line(to: NSPoint(x: size.width, y: 0))
        shape.close()
        shape.addClip()

        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()

        // The page occupies the bottom of the composite.
        page.draw(
            in: NSRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height),
            from: .zero, operation: .copy, fraction: 1.0)

        let bar = NSRect(x: 0, y: pageSize.height, width: size.width, height: titleHeight)
        NSColor.windowBackgroundColor.setFill()
        bar.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: pageSize.height, width: size.width, height: 1).fill()

        // Traffic lights, drawn rather than captured so the image does not
        // depend on how the window happens to be configured.
        let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: 14 + CGFloat(index) * 20, y: pageSize.height + titleHeight / 2 - 6,
                    width: 12, height: 12)
            ).fill()
        }

        let title = NSAttributedString(
            string: "DeepSeek Harness",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        let titleSize = title.size()
        title.draw(
            at: NSPoint(
                x: (size.width - titleSize.width) / 2,
                y: pageSize.height + (titleHeight - titleSize.height) / 2))

        drawNoticeCard()

        composite.unlockFocus()

        guard let tiff = composite.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            Log.shared.write("screenshot failed: could not encode the image")
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(Int(size.width))x\(Int(size.height)))")
            Log.shared.write("wrote screenshot to \(path)")
            exit(0)
        } catch {
            Log.shared.write("screenshot failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Draw the notice card into the current focus, if one is on screen.
    ///
    /// The card is a sibling of the webview, not part of it, so it is absent
    /// from the page snapshot and has to be rendered separately. It is an
    /// ordinary view, so caching its display works; the webview could not be
    /// captured that way because it draws out of process.
    private func drawNoticeCard() {
        guard let card = banner, card.frame.width > 1 else { return }
        guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return }
        card.cacheDisplay(in: card.bounds, to: rep)

        let image = NSImage(size: card.bounds.size)
        image.addRepresentation(rep)
        image.draw(in: card.frame, from: .zero, operation: .sourceOver, fraction: 1.0)
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
                self?.lifecycle.stop()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop a half-finished install so the next launch starts from a clean slot.
        lifecycle.cancelInstaller()
        lifecycle.stop()
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
        // Layer-backed so the notice card composites reliably above the
        // webview, which draws in its own layer.
        content.wantsLayer = true
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


    // MARK: Menu actions

    @objc private func retryStartup() { lifecycle.start(reason: "retry button") }

    @objc private func restartHarness() { lifecycle.start(reason: "restart command", force: true) }

    @objc private func checkForUpdates() {
        guard lifecycle.managedUpdatesEnabled else {
            showBanner(
                "Managed updates are off",
                detail: "The app was launched with DSH_MANAGED=0, so there is nothing to check.",
                kind: .warning)
            return
        }
        reportUpdateChecking()
        lifecycle.checkForUpdates { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .staged(let version):
                self.reportUpdateStaged(version)
            case .alreadyCurrent(let version):
                self.showBanner(
                    "Harness \(version) is the newest version",
                    detail: "Nothing to install. The app checks again on the next launch.",
                    kind: .info)
            case .deferredTrial:
                self.showBanner(
                    "Not updating yet",
                    detail: """
                        The version you are running is still being watched to be sure it stays up. \
                        Replacing the other copy now would remove the version the app falls back to. \
                        This clears itself in under a minute — or use Reinstall on the next launch.
                        """,
                    kind: .info)
            case .knownBad(let version):
                self.showBanner(
                    "Harness \(version) failed to start earlier",
                    detail: "It will not be tried again automatically. Reinstalling is the way to retry it.",
                    kind: .warning)
            case .unavailable(let reason):
                self.showBanner(
                    "Could not check for updates",
                    detail: reason ?? "No newer version was available. Details are in the log.",
                    kind: .warning)
            }
        }
    }

    /// Reinstall the idle slot even if it is already newest — the way out of a
    /// slot that has been marked broken.
    @objc private func reinstallHarness() {
        guard lifecycle.managedUpdatesEnabled else { return }
        reportUpdateChecking()
        lifecycle.reinstallIdleSlot { [weak self] outcome in
            guard let self else { return }
            if let version = outcome.stagedVersion {
                self.showBanner(
                    "Harness \(version) reinstalled",
                    detail: "It passed a startup check and will be used the next time this app launches.",
                    kind: .info)
            } else {
                self.showBanner(
                    "Could not reinstall the Harness",
                    detail: outcome.failureReason ?? "See the log for the reason.",
                    kind: .warning)
            }
        }
    }

    // MARK: Alerts

    /// Put a notice card at the top-right of the window.
    ///
    /// Deliberately not modal: an update problem must not stop the user from
    /// working. It is the only place a rollback is reported, so a warning stays
    /// until dismissed; an informational notice fades on its own, because it is
    /// reassurance rather than something to act on.
    private func showBanner(_ message: String, detail: String, kind: NoticeCard.Kind) {
        dismissBanner()
        guard let content = window.contentView else { return }

        let card = NoticeCard(kind: kind, title: message, detail: detail)
        card.alphaValue = 0
        card.onDismiss = { [weak self] in self?.dismissBanner() }

        // Placed above everything explicitly. The window hosts a WKWebView, and
        // insertion order alone is not something to rely on for a view that has
        // to be visible over it.
        content.addSubview(card, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: NoticeCard.maximumWidth),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 12),
        ])
        banner = card

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            card.animator().alphaValue = 1
        }

        guard kind == .info else { return }
        // Long enough to read, short enough not to linger over the harness UI.
        let work = DispatchWorkItem { [weak self] in self?.dismissBanner() }
        bannerDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func dismissBanner() {
        bannerDismissWork?.cancel()
        bannerDismissWork = nil
        guard let card = banner else { return }
        banner = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            card.animator().alphaValue = 0
        } completionHandler: {
            card.removeFromSuperview()
        }
    }

    /// Tell the user, in plain words, that the update did not work and that the
    /// previous version is running.
    ///
    /// The card stays readable on purpose: it says what happened and what the
    /// app did about it. The harness's own error text goes to the log instead,
    /// where it is useful for diagnosis and unreadable as a notification.
    private func alertRollback(
        failed: String, recovered: String, reason: String, cause: HarnessLifecycle.RollbackCause
    ) {
        let headline: String
        let explanation: String
        switch cause {
        case .failedToStart:
            headline = "Harness \(failed) did not start — back on \(recovered)"
            explanation = "It never began serving the interface, so the app switched back automatically."
        case .crashLoop:
            headline = "Harness \(failed) kept quitting — back on \(recovered)"
            explanation = """
                It started and then stopped \(ManagedInstall.crashLoopLimit) times in a row, so the app \
                switched back rather than keep restarting it.
                """
        }

        showBanner(
            headline,
            detail: "\(explanation) \(failed) will not be tried again. See the log for details.",
            kind: .warning)
    }

    private func reportUpdateStaged(_ version: String) {
        showBanner(
            "Harness \(version) is ready",
            detail: "Verified and waiting. It will be used the next time this app launches.",
            kind: .info)
    }

    private func reportUpdateChecking() {
        showBanner(
            "Checking for Harness updates…",
            detail: "The running version keeps working while this happens.",
            kind: .info)
    }

    @objc private func reloadHarness() {
        guard let url = lifecycle.authenticatedURL else {
            return lifecycle.start(reason: "reload with no server")
        }
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
        let checkUpdates = NSMenuItem(
            title: "Check for Harness Updates", action: #selector(checkForUpdates), keyEquivalent: "u")
        appMenu.addItem(checkUpdates)
        let reinstall = NSMenuItem(
            title: "Reinstall Harness…", action: #selector(reinstallHarness), keyEquivalent: "")
        appMenu.addItem(reinstall)
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
        if let request = pendingScreenshot { captureWindow(to: request.path, note: request.note) }
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
        guard !lifecycle.isServerRunning else { return }
        overlay.showFailure(
            "The Harness server is not running.",
            detail: lifecycle.recentServerLog)
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
        server.onFailure = { reason, _ in failure = reason }
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
        // The completion arrives on URLSession's own queue and is read from the
        // main thread below, so the hand-off is synchronized rather than shared
        // through a captured `var`.
        let status = Handoff<Int>()
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { _, response, _ in
            if let code = (response as? HTTPURLResponse)?.statusCode { status.set(code) }
            done.signal()
        }
        task.resume()
        wait(until: { status.value != nil }, timeout: 30)
        _ = done.wait(timeout: .now() + 1)
        return status.value
    }
}

/// Provision a managed harness copy without opening a window.
///
/// This is the same work the first launch does when no harness is installed at
/// all, exposed so it can be run headlessly: to pre-fetch the harness, to repair
/// an install, or to set a machine up before anyone signs in to the GUI.
enum InstallHarness {
    static func run() -> Never {
        let managed = ManagedInstall()
        guard managed.isEnabled else {
            print("managed slots are disabled (DSH_MANAGED=0), so there is nothing to install")
            exit(1)
        }

        print("dsh-mac harness install")
        print("  slots: \(AppPaths.slots.path)")

        var outcome: UpdateOutcome?
        managed.updateIdleSlot(activeSlot: nil, force: true) { outcome = $0 }

        // The install runs on a background queue and hops back to the main
        // queue, so pump the run loop rather than blocking on it.
        let deadline = Date().addingTimeInterval(3600)
        while outcome == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        guard let outcome else {
            print("  [FAIL] the install did not finish within an hour")
            exit(1)
        }

        switch outcome {
        case .staged(let version):
            guard let candidate = managed.resolveBootCandidate(), let slot = candidate.slot else {
                print("  [FAIL] \(version) installed, but no slot could be booted")
                exit(1)
            }
            print("  [ ok ] installed harness \(version) into slot \(slot)")
            print("  [ ok ] will boot: \(candidate.dsh)")
            exit(0)
        case .alreadyCurrent(let version):
            print("  [ ok ] harness \(version) is already installed")
            exit(0)
        case .knownBad(let version):
            print("  [FAIL] version \(version) previously failed to start and was not retried")
            print("         run with DSH_SLOT_VERSION to try a different version")
            exit(1)
        case .deferredTrial:
            print("  [FAIL] deferred: a version is still being watched")
            exit(1)
        case .unavailable(let reason):
            print("  [FAIL] could not install the harness: \(reason ?? "unknown reason")")
            exit(1)
        }
    }
}
/// Tests for the A/B update bookkeeping: which slot is booted, and how a slot
/// that fails to boot hands over to the other one. These encode the guarantee
/// that a broken upstream release cannot leave the app unusable.
#if DSH_TESTS
enum UpdateTests {    static func run() -> Never {
        var failures = 0

        // These tests write slot records, so they run against a scratch support
        // directory. Without this they would load and overwrite the state of a
        // real installation — including the user's own slots.
        let scratch = NSTemporaryDirectory() + "dsh-mac-update-tests-\(UUID().uuidString)"
        setenv("DSH_APP_SUPPORT", scratch, 1)
        func finish(_ code: Int32) -> Never {
            try? FileManager.default.removeItem(atPath: scratch)
            exit(code)
        }

        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  [ ok ] \(label)" : "  [FAIL] \(label)")
            if !condition { failures += 1 }
        }

        print("A/B update tests")

        // A fresh install knows nothing yet.
        var state = InstallState()
        check(state.preferred == nil && state.staged == nil, "a new state has no slot selected")

        // The idle slot is always the one that is not preferred.
        check(state.other(than: nil) == "a", "with nothing preferred, the idle slot is a")
        check(state.other(than: "a") == "b", "with a preferred, the idle slot is b")
        check(state.other(than: "b") == "a", "with b preferred, the idle slot is a")
        check(state.other(than: "zzz") != "zzz", "an unknown slot name still yields a real slot")

        // A verified slot is usable; a broken one is not, even if it booted before.
        var healthy = Slot(version: "1.0.0", installedAt: Date(), verifiedAt: Date())
        check(healthy.isUsable, "a verified slot is usable")
        check(!Slot(version: "1.0.0", installedAt: Date()).isUsable, "an unverified slot is not usable")
        healthy.broken = true
        check(!healthy.isUsable, "a broken slot is not usable even though it was verified")

        // A slot is only accepted once it has been proven to boot.
        state.slots["a"] = Slot(version: "1.0.0", installedAt: Date(), verifiedAt: Date())
        check(state.slots["a"]?.isUsable == true, "the booted slot is recorded as usable")

        // Staging an update must not disturb the slot that is running.
        state.staged = "b"
        check(state.preferred != "b", "staging does not move the running slot")

        // ── crash-loop counting ──────────────────────────────────────────────
        //
        // A version that starts and then dies quickly is as broken as one that
        // never starts, so early exits accumulate until the limit is reached.

        let manager = ManagedInstall()

        // Only quick exits count: a slot that ran a long time before stopping
        // says nothing about the release, so its history is cleared instead.
        manager.setSlot("a", Slot(
            version: "1.0.0", installedAt: Date(), verifiedAt: Date(), earlyExits: [Date()]))
        let longRun = manager.recordEarlyExit(slot: "a", uptime: 60 * 30)
        check(!longRun, "a long healthy run does not count as a crash")
        check(
            manager.state.slots["a"]?.earlyExits.isEmpty == true,
            "a long healthy run clears the crash history")

        // Exactly at the threshold the run is still considered long.
        manager.setSlot("a", Slot(version: "1.0.0", installedAt: Date(), verifiedAt: Date()))
        check(
            !manager.recordEarlyExit(slot: "a", uptime: ManagedInstall.earlyExitSeconds),
            "a run reaching the threshold is not an early exit")

        // Quick exits accumulate, and the last one trips the loop.
        manager.setSlot("a", Slot(version: "1.0.0", installedAt: Date(), verifiedAt: Date()))
        for attempt in 1...ManagedInstall.crashLoopLimit {
            let tripped = manager.recordEarlyExit(slot: "a", uptime: 5)
            check(
                tripped == (attempt == ManagedInstall.crashLoopLimit),
                "early exit \(attempt) of \(ManagedInstall.crashLoopLimit) \(attempt == ManagedInstall.crashLoopLimit ? "trips" : "does not trip") the crash loop")
        }
        check(
            manager.state.slots["a"]?.earlyExits.count == ManagedInstall.crashLoopLimit,
            "every early exit is recorded")

        // Old exits fall out of the window, so a version that crashed once long
        // ago is not condemned by an unrelated crash today.
        manager.setSlot("a", Slot(
            version: "1.0.0", installedAt: Date(), verifiedAt: Date(),
            earlyExits: Array(
                repeating: Date().addingTimeInterval(-ManagedInstall.crashWindow - 60),
                count: ManagedInstall.crashLoopLimit)))
        check(
            !manager.recordEarlyExit(slot: "a", uptime: 5),
            "early exits outside the window do not trip the loop")
        check(
            manager.state.slots["a"]?.earlyExits.count == 1,
            "stale early exits are dropped from the history")

        // An unknown slot cannot trip anything.
        check(!manager.recordEarlyExit(slot: "zzz", uptime: 1), "an unknown slot never trips the loop")
        check(!manager.recordEarlyExit(slot: nil, uptime: 1), "no slot never trips the loop")

        if failures == 0 {
            print("all A/B update tests passed")
            finish(0)
        }
        print("\(failures) A/B update test(s) failed")
        finish(1)
    }
}
#endif

/// Tests for the threading guarantees the update path depends on.
///
/// These exist because the code got this wrong in two ways that only showed up
/// under load: `healthCheck` shared a `var` with a URLSession callback and spun
/// its own run loop, and `ManagedInstall.state` was read on the update queue
/// while the main queue wrote to it. Both are invisible in single-threaded
/// tests, which is exactly why they survived. Running the real paths
/// concurrently is the only way to keep them fixed — the lost-update check below
/// fails on the old code.
#if DSH_TESTS
enum ConcurrencyTests {
    static func run() -> Never {
        var failures = 0

        // These write slot records, so they must not touch a real install.
        let scratch = NSTemporaryDirectory() + "dsh-mac-concurrency-tests-\(UUID().uuidString)"
        setenv("DSH_APP_SUPPORT", scratch, 1)
        func finish(_ code: Int32) -> Never {
            try? FileManager.default.removeItem(atPath: scratch)
            exit(code)
        }
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  [ ok ] \(label)" : "  [FAIL] \(label)")
            if !condition { failures += 1 }
        }

        print("concurrency tests")

        // ── the state lock ───────────────────────────────────────────────────

        // Every recorded crash must survive. Without the lock, concurrent
        // read-modify-write of the same slot loses updates: the count lands
        // below the number of calls and the app would under-count crashes, so a
        // genuinely broken release would not trip the crash loop.
        let manager = ManagedInstall()
        manager.setSlot("a", Slot(version: "1.0.0", installedAt: Date(), verifiedAt: Date()))

        let threads = 8
        let perThread = 25
        let group = DispatchGroup()
        for _ in 0..<threads {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<perThread {
                    _ = manager.recordEarlyExit(slot: "a", uptime: 5)
                }
            }
        }
        group.wait()

        let recorded = manager.state.slots["a"]?.earlyExits.count ?? -1
        check(
            recorded == threads * perThread,
            "concurrent crash reports all survive (\(recorded) of \(threads * perThread))")

        // Reads taken while writers run must not crash and must stay coherent.
        // A torn read here would be an unreadable `InstalledState` at boot.
        let readers = DispatchGroup()
        let observed = Handoff<Int>()
        var reads = 0
        let readLock = NSLock()
        for _ in 0..<4 {
            DispatchQueue.global().async(group: readers) {
                for _ in 0..<50 {
                    _ = manager.version(of: "a")
                    _ = manager.preferredSlot
                    _ = manager.idleSlotIsFallback(activeSlot: "a")
                    readLock.lock()
                    reads += 1
                    readLock.unlock()
                }
            }
        }
        readers.wait()
        observed.set(reads)
        check(observed.value == 200, "concurrent reads complete (\(observed.value ?? -1) of 200)")

        // ── healthCheck threading ────────────────────────────────────────────

        // A candidate that cannot run must be reported, not hung on. The old
        // implementation spun a run loop waiting for callbacks that were
        // dispatched to the main queue, so calling it off-main could only work
        // if somebody else happened to be pumping main.
        let missing = Handoff<String?>()
        let missingDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            missing.set(ManagedInstall.healthCheck(dsh: "/nonexistent/dsh", timeout: 20))
            missingDone.signal()
        }
        let waited = missingDone.wait(timeout: .now() + 60)
        check(waited == .success, "healthCheck returns from a background queue")
        check(missing.value ?? nil != nil, "an unrunnable candidate is reported as unhealthy")

        // Several at once, which is what an update racing a manual check looks
        // like. None may crash, hang, or come back healthy.
        let many = DispatchGroup()
        let verdicts = Handoff<Int>()
        var unhealthy = 0
        let verdictLock = NSLock()
        for _ in 0..<4 {
            DispatchQueue.global().async(group: many) {
                let verdict = ManagedInstall.healthCheck(dsh: "/nonexistent/dsh", timeout: 20)
                verdictLock.lock()
                if verdict != nil { unhealthy += 1 }
                verdictLock.unlock()
            }
        }
        let manyDone = many.wait(timeout: .now() + 120)
        verdicts.set(unhealthy)
        check(manyDone == .success, "concurrent health checks all finish")
        check(verdicts.value == 4, "every concurrent health check reports the failure")

        if failures == 0 {
            print("all concurrency tests passed")
            finish(0)
        }
        print("\(failures) concurrency test(s) failed")
        finish(1)
    }
}
#endif

/// Tests for the notice card's appearance.
///
/// The card exists to be read over the harness's own UI, so "does it look
/// right" is a real requirement rather than a matter of taste: if its
/// background is translucent, the harness shows through and the message that
/// matters most becomes the hardest to read. These render the card offscreen
/// and inspect the pixels, so that property is checked rather than assumed.
#if DSH_TESTS
enum NoticeTests {
    static func run() -> Never {
        // AppKit needs an application instance before any view can be drawn.
        _ = NSApplication.shared
        var failures = 0

        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  [ ok ] \(label)" : "  [FAIL] \(label)")
            if !condition { failures += 1 }
        }

        print("notice card tests")

        /// Render a card and hand back its pixels, or nil when this environment
        /// has no window server to draw into.
        func render(kind: NoticeCard.Kind, title: String, detail: String) -> NSBitmapImageRep? {
            let card = NoticeCard(kind: kind, title: title, detail: detail)
            card.layoutSubtreeIfNeeded()
            let size = card.fittingSize
            guard size.width > 1, size.height > 1 else { return nil }
            card.frame = NSRect(origin: .zero, size: size)
            card.layoutSubtreeIfNeeded()
            guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return nil }
            card.cacheDisplay(in: card.bounds, to: rep)
            return rep
        }

        let warning = render(
            kind: .warning, title: "Harness 0.1.6 did not start",
            detail: "Running 0.1.5 instead. It will not be tried again.")
        let info = render(
            kind: .info, title: "Harness 0.1.5 is ready",
            detail: "It will be used the next time this app launches.")

        // Optional: write the cards out so a human can look at them.
        if let directory = ProcessInfo.processInfo.environment["DSH_NOTICE_DUMP"], !directory.isEmpty {
            for (name, rep) in [("warning", warning), ("info", info)] {
                if let rep, let png = rep.representation(using: .png, properties: [:]) {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("notice-\(name).png")
                    try? png.write(to: url)
                    print("  wrote \(url.path)")
                }
            }
        }

        guard let warning, let info else {
            print("  [skip] could not render a view here, so no pixels were checked")
            exit(0)
        }

        func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor? {
            rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        }

        // A fully transparent centre means this environment produced an empty
        // bitmap rather than a real drawing; treat that as "cannot test here"
        // instead of reporting a false failure.
        let centre = pixel(warning, warning.pixelsWide / 2, warning.pixelsHigh / 2)
        guard let centre, centre.alphaComponent > 0.9 else {
            print("  [skip] no window server; the card rendered blank")
            exit(0)
        }

        check(true, "the card renders")
        check(warning.pixelsWide > 150, "the card has a real width (\(warning.pixelsWide)px)")

        // Opaque: the whole point is that the harness UI cannot show through.
        var translucent = 0
        var sampled = 0
        for x in stride(from: 20, to: warning.pixelsWide - 20, by: 7) {
            for y in stride(from: 8, to: warning.pixelsHigh - 8, by: 5) {
                sampled += 1
                if let c = pixel(warning, x, y), c.alphaComponent < 0.99 { translucent += 1 }
            }
        }
        check(sampled > 0 && translucent == 0, "the card is fully opaque (\(translucent)/\(sampled) see-through)")

        // Rounded: the very corner falls outside the rounded background.
        let corner = pixel(warning, 0, 0)
        check((corner?.alphaComponent ?? 1) < 0.5, "the card has rounded corners")

        /// Count pixels matching a hue, used to prove the two kinds are
        /// visually distinguishable rather than only differing in text.
        func count(_ rep: NSBitmapImageRep, _ matches: (NSColor) -> Bool) -> Int {
            var total = 0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    if let c = pixel(rep, x, y), c.alphaComponent > 0.5, matches(c) { total += 1 }
                }
            }
            return total
        }

        let isOrange: (NSColor) -> Bool = { c in
            c.redComponent > 0.75 && c.greenComponent > 0.25 && c.greenComponent < 0.78
                && c.blueComponent < 0.35
        }
        let isBlue: (NSColor) -> Bool = { c in
            c.blueComponent > 0.65 && c.redComponent < 0.5 && c.greenComponent < 0.75
        }

        check(count(warning, isOrange) > 20, "a warning is marked in orange")
        check(count(info, isBlue) > 20, "an informational notice is marked in blue")
        check(
            count(warning, isBlue) < count(info, isBlue) || count(warning, isOrange) > count(info, isOrange),
            "the two kinds are visually distinct")

        if failures == 0 {
            print("all notice card tests passed")
            exit(0)
        }
        print("\(failures) notice card test(s) failed")
        exit(1)
    }
}
#endif

/// Tests for {@link HarnessServer.readyURL}, the single piece of harness output
/// this app interprets. These run in CI so that a change to that log line fails
/// loudly here, rather than silently in someone's window.
#if DSH_TESTS
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
#endif

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

#if DSH_TESTS
// The unit-test runners. Compiled only into a test build (`DSH_BUILD_TESTS=1`),
// so a shipped app carries no test code and cannot be asked to run it. They are
// not diagnostics: nothing a user needs is behind these flags.
if arguments.contains("--test-parser") {
    ParserTests.run()
}

if arguments.contains("--test-update") {
    UpdateTests.run()
}

if arguments.contains("--test-notice") {
    NoticeTests.run()
}

if arguments.contains("--test-concurrency") {
    ConcurrencyTests.run()
}
#else
// Refuse rather than falling through to the GUI: silently opening a window for
// `--test-parser` would look like the flag worked.
for flag in ["--test-parser", "--test-update", "--test-notice", "--test-concurrency"] {
    if arguments.contains(flag) {
        FileHandle.standardError.write(Data("""
            \(flag) is a unit-test runner and is not compiled into a release build.

            Build one with:  DSH_BUILD_TESTS=1 ./build.sh

            """.utf8))
        exit(2)
    }
}
#endif

if arguments.contains("--install-harness") {
    InstallHarness.run()
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
