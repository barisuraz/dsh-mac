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
    static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval,
        environment: [String: String]? = nil
    ) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
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

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            Log.shared.write("\(executable) timed out after \(Int(timeout))s")
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
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
final class ManagedInstall {
    private(set) var state = InstallState()
    private let queue = DispatchQueue(label: "dsh.managed-install")
    private var installer: Process?

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
        if let data = try? encoder.encode(state) {
            try? data.write(to: AppPaths.state, options: .atomic)
        }
    }

    /// Drop a slot's record and its files.
    private func discard(_ name: String) {
        state.slots[name] = nil
        if state.preferred == name { state.preferred = nil }
        if state.staged == name { state.staged = nil }
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
            var order: [String] = []
            if let staged = state.staged { order.append(staged) }
            if let preferred = state.preferred, !order.contains(preferred) { order.append(preferred) }
            for name in InstallState.slotNames where !order.contains(name) { order.append(name) }

            for name in order {
                guard let slot = state.slots[name], !slot.broken else { continue }
                let binary = AppPaths.slotBinary(name).path
                if FileManager.default.isExecutableFile(atPath: binary) {
                    return (binary, name)
                }
            }
        }
        if let path = Locator.dshPath() { return (path, nil) }
        return nil
    }

    /// Mark a slot as having booted successfully, and promote a staged update to
    /// be the next boot.
    func recordHealthy(slot: String?) {
        guard let slot, isEnabled else { return }
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
        save()
    }

    /// Mark a slot as failing to boot, so it is not chosen again and the other
    /// slot is preferred instead.
    func recordBroken(slot: String?, reason: String) {
        guard let slot, isEnabled else { return }
        Log.shared.write("slot \(slot) failed to boot: \(reason)")
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
        save()
    }

    // MARK: Updating

    /// Bring the idle slot up to date and verify it, in the background.
    ///
    /// Never touches the slot that is currently booted. On success the idle slot
    /// becomes `staged` and is used on the next launch; on failure it is
    /// discarded and the running version is untouched.
    func updateIdleSlot(
        activeSlot: String?, force: Bool = false, completion: @escaping (UpdateOutcome) -> Void
    ) {
        guard isEnabled else { return completion(.unavailable("managed updates are off")) }

        queue.async { [weak self] in
            guard let self else { return completion(.unavailable(nil)) }
            let target = self.state.other(than: activeSlot)

            guard let npm = Locator.npmPath() else {
                Log.shared.write("update skipped: npm not found")
                return completion(.unavailable("npm was not found"))
            }

            let wanted = self.pinnedVersion ?? self.latestVersion(npm: npm)
            guard let wanted else {
                Log.shared.write("update skipped: could not determine the newest version")
                return completion(.unavailable("the newest version could not be determined"))
            }

            // Nothing to do when the running slot is already newest. Without
            // this, every launch would install the same version into the idle
            // slot and swap between them pointlessly.
            if !force, let active = activeSlot, self.state.slots[active]?.version == wanted {
                Log.shared.write("update: running slot \(active) is already the newest (\(wanted))")
                return completion(.alreadyCurrent(wanted))
            }

            // Do not keep retrying a release that already failed to start.
            if !force, let why = self.state.rejected[wanted] {
                Log.shared.write("update: \(wanted) is known bad (\(why)); not retrying")
                return completion(.knownBad(wanted))
            }

            // Refuse to overwrite the fallback while the running version is
            // still on trial. Installing replaces the target slot's contents,
            // and during the trial period the other slot is the only known-good
            // copy — the one that will be needed if this version turns out to
            // crash. Regaining a newer version later is cheap; losing the
            // fallback is not.
            if let active = activeSlot, let activeInfo = self.state.slots[active],
                let verified = activeInfo.verifiedAt,
                Date().timeIntervalSince(verified) < Self.earlyExitSeconds,
                self.state.slots[target]?.isUsable == true
            {
                Log.shared.write(
                    "update deferred: slot \(active) is still on trial and slot \(target) is the fallback")
                return completion(.deferredTrial)
            }

            // Already have this version staged and verified? Nothing to do.
            if let existing = self.state.slots[target], existing.version == wanted,
                existing.verifiedAt != nil, !existing.broken,
                FileManager.default.isExecutableFile(atPath: AppPaths.slotBinary(target).path)
            {
                Log.shared.write("update: slot \(target) already holds \(wanted)")
                DispatchQueue.main.async {
                    self.markStaged(target, version: wanted, activeSlot: activeSlot)
                    completion(.staged(wanted))
                }
                return
            }

            Log.shared.write("update: installing \(wanted) into slot \(target)")
            self.install(npm: npm, slot: target, version: wanted) { ok in
                guard ok else {
                    Log.shared.write("update: install failed; keeping the running version")
                    self.discard(target)
                    self.save()
                    return completion(.unavailable("the download or install failed"))
                }

                // Prove the new copy boots and serves the GUI before trusting it.
                let binary = AppPaths.slotBinary(target).path
                Log.shared.write("update: verifying slot \(target)")
                let verdict = Self.healthCheck(dsh: binary)

                DispatchQueue.main.async {
                    guard verdict == nil else {
                        Log.shared.write("update: slot \(target) failed verification (\(verdict!)); discarding")
                        // Remember the version, not just the slot: there is no
                        // point downloading a release that cannot start again
                        // on the next launch.
                        self.state.rejected[wanted] = verdict!
                        self.discard(target)
                        self.save()
                        return completion(.unavailable(verdict))
                    }
                    // It started, so drop any earlier bad verdict for it.
                    self.state.rejected[wanted] = nil
                    self.state.slots[target] = Slot(
                        version: wanted, installedAt: Date(), verifiedAt: Date(), broken: false)
                    self.markStaged(target, version: wanted, activeSlot: activeSlot)
                    Log.shared.write("update: \(wanted) verified in slot \(target), ready for next launch")
                    completion(.staged(wanted))
                }
            }
        }
    }

    private func markStaged(_ target: String, version: String, activeSlot: String?) {
        self.state.staged = target
        // When nothing has been booted from a slot yet, this becomes the boot slot.
        if self.state.preferred == nil { self.state.preferred = target }
        self.state.updatedAt = Date()
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
        guard let slot, isEnabled, let existing = state.slots[slot] else { return false }
        // Only a quick death implicates the version. Something that ran for a
        // good while and then stopped is not evidence about the release.
        guard uptime < Self.earlyExitSeconds else {
            if !existing.earlyExits.isEmpty {
                Log.shared.write("slot \(slot) ran \(Int(uptime))s; clearing its crash history")
                state.slots[slot]?.earlyExits = []
                save()
            }
            return false
        }

        var recent = existing.recentEarlyExits(window: Self.crashWindow)
        recent.append(Date())
        state.slots[slot]?.earlyExits = recent
        save()

        Log.shared.write(
            "slot \(slot) exited after \(Int(uptime))s; \(recent.count) of \(Self.crashLoopLimit) early exits in the window")
        return recent.count >= Self.crashLoopLimit
    }

    /// The version currently designated to boot, for messages.
    func version(of slot: String?) -> String? {
        guard let slot else { return nil }
        return state.slots[slot]?.version
    }

    /// Mark a slot as having proven itself: it served, and it kept serving for
    /// long enough that it is no longer a crash-loop suspect.
    func recordStable(slot: String?) {
        guard let slot, isEnabled, state.slots[slot] != nil else { return }
        if !(state.slots[slot]?.earlyExits.isEmpty ?? true) {
            Log.shared.write("slot \(slot) proved stable; clearing its crash history")
        }
        state.slots[slot]?.earlyExits = []
        state.slots[slot]?.verifiedAt = Date()
        save()
    }

    /// Whether the idle slot currently holds a usable copy of the harness — the
    /// one that would be lost if an update overwrote it.
    func idleSlotIsFallback(activeSlot: String?) -> Bool {
        state.slots[state.other(than: activeSlot)]?.isUsable == true
    }

    /// Test seam: install a slot record directly.
    func setSlot(_ name: String, _ slot: Slot) { state.slots[name] = slot }

    /// Boot a candidate copy on an ephemeral port and confirm it really serves
    /// the GUI. This is the gate every update must pass before it can be booted,
    /// and it is what makes a broken upstream commit a non-event.
    ///
    /// Returns nil when healthy, or a short reason when not.
    static func healthCheck(dsh: String, timeout: TimeInterval = 120) -> String? {
        let server = HarnessServer()
        var ready: URL?
        var failure: String?
        server.onReady = { ready = $0 }
        server.onFailure = { reason, _ in failure = reason }
        server.start(preferredPort: 0, dsh: dsh)

        let deadline = Date().addingTimeInterval(timeout)
        while ready == nil && failure == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        guard let url = ready else {
            server.stop()
            return failure.map { String($0.prefix(200)) } ?? "no listening port within \(Int(timeout))s"
        }

        var status: Int?
        let task = URLSession.shared.dataTask(with: url) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
        }
        task.resume()
        let httpDeadline = Date().addingTimeInterval(30)
        while status == nil && Date() < httpDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        server.stop()

        guard status == 200 else { return "the GUI returned \(status.map(String.init) ?? "no response")" }
        return nil
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
        // spinner forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
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
    private let managed = ManagedInstall()
    /// The floating notice currently on screen, if any.
    private var banner: NSView?

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
        // Stop a half-finished install so the next launch starts from a clean slot.
        managed.cancelInstaller()
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
            self.readyAt = Date()
            // This copy demonstrably boots and serves, so record it as good and,
            // if it was a staged update, make it the version we return to.
            let promoted = self.managed.state.staged == self.bootingSlot
            self.managed.recordHealthy(slot: self.bootingSlot)
            if promoted { self.reportUpdateAdopted() }
            self.runningSlot = self.bootingSlot
            self.bootingSlot = nil
            self.dismissBanner()
            self.webView.load(URLRequest(url: url))
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
                self.showBanner(
                    "The Harness stopped unexpectedly — restarting it",
                    detail: """
                        \(reason.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? reason)
                        If this keeps happening, the app will switch back to the previous version automatically.
                        """,
                    kind: .warning)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.startHarness("auto-restart after an unexpected exit", force: true)
                }
                return
            }
            self.showFailure(reason)
        }
    }

    private func showFailure(_ reason: String) {
        let split = reason.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        overlay.showFailure(
            String(split.first ?? "The Harness could not start."),
            detail: split.count > 1 ? String(split[1]) : "")
    }

    /// Why a version is being abandoned, which decides how it is explained.
    enum RollbackCause {
        /// The harness never reported a listening port.
        case failedToStart
        /// It served, then died soon after, repeatedly.
        case crashLoop
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

        alertRollback(
            failed: failedVersion, recovered: recoveredVersion, reason: reason, cause: cause)
        launch(dsh: next.dsh, slot: next.slot)
    }

    // MARK: Managed updates

    private func startHarness(_ reason: String, force: Bool = false) {
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
            launch(dsh: candidate.dsh, slot: candidate.slot)
            return
        }

        // No managed copy yet. When a harness is already installed, use it
        // immediately so the first launch is instant rather than a download,
        // and provision a managed slot in the background for next time. This is
        // also what makes switching to this app non-destructive: the first run
        // behaves exactly like whatever you were using before.
        if let system = Locator.dshPath() {
            Log.shared.write(
                "no managed slot yet; starting your installed dsh and provisioning one in the background")
            launch(dsh: system, slot: nil)
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
        overlay.showWorking("Starting DeepSeek Harness…", detail: detail)
        server.start(preferredPort: preferredPort, dsh: dsh)
    }

    /// Install the first managed copy. Only reached when no copy is usable, so
    /// it is normally a one-time, first-run step.
    private func provisionFirstSlot() {
        overlay.showWorking(
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

        let slot = runningSlot ?? managed.state.preferred
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
                self.reportUpdateStaged(version)
            }
        }
        updateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    @objc private func checkForUpdates() {
        guard managed.isEnabled else {
            showFailure("Managed updates are off (DSH_MANAGED=0), so there is nothing to check.")
            return
        }
        reportUpdateChecking()
        managed.updateIdleSlot(activeSlot: runningSlot ?? managed.state.preferred, force: true) {
            [weak self] outcome in
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
        guard managed.isEnabled else { return }
        reportUpdateChecking()
        managed.updateIdleSlot(activeSlot: runningSlot ?? managed.state.preferred, force: true) {
            [weak self] outcome in
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

    @objc private func retryStartup() { startHarness("retry button") }

    @objc private func restartHarness() { startHarness("restart command", force: true) }

    // MARK: Alerts

    enum BannerKind { case info, warning }

    /// A floating notice across the top of the window.
    ///
    /// Deliberately not a modal: an update problem must not stop the user from
    /// working, so the message sits above the GUI, explains itself, and can be
    /// dismissed. It is the only place the user is told that a rollback
    /// happened, so it carries the reason, not just the fact.
    private func showBanner(_ message: String, detail: String, kind: BannerKind) {
        dismissBanner()
        guard let content = window.contentView else { return }

        let tint: NSColor = kind == .warning ? .systemOrange : .systemBlue
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
        bar.layer?.borderColor = tint.withAlphaComponent(0.40).cgColor
        bar.layer?.borderWidth = 1
        bar.layer?.cornerRadius = 8

        let title = NSTextField(labelWithString: message)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2

        let body = NSTextField(wrappingLabelWithString: detail)
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 5

        let text = NSStackView(views: [title, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissBannerAction))
        dismiss.bezelStyle = .rounded
        dismiss.controlSize = .small

        let row = NSStackView(views: [text, dismiss])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: bar.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
        ])

        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
        ])
        banner = bar
    }

    @objc private func dismissBannerAction() { dismissBanner() }

    private func dismissBanner() {
        banner?.removeFromSuperview()
        banner = nil
    }

    /// Tell the user, in plain words, that the update did not work and that the
    /// previous version is running.
    private func alertRollback(
        failed: String, recovered: String, reason: String, cause: RollbackCause
    ) {
        let firstLine = reason
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? reason

        let headline: String
        let explanation: String
        switch cause {
        case .failedToStart:
            headline = "The updated Harness (\(failed)) did not start — running \(recovered) instead"
            explanation = "It never began serving the interface, so the app switched back automatically."
        case .crashLoop:
            headline = "The updated Harness (\(failed)) kept quitting — running \(recovered) instead"
            explanation = """
                It started and then stopped \(ManagedInstall.crashLoopLimit) times in a row, so the app \
                switched back automatically rather than keep restarting it.
                """
        }

        showBanner(
            headline,
            detail: """
                \(explanation)
                \(firstLine)
                \(recovered) stays as the fallback and \(failed) will not be tried again. \
                Details are in the log.
                """,
            kind: .warning)
    }

    private func reportUpdateStaged(_ version: String) {
        showBanner(
            "Harness \(version) is ready",
            detail: "It installed and passed a startup check. It will be used the next time this app launches.",
            kind: .info)
    }

    private func reportUpdateAdopted() {
        Log.shared.write("running the newly installed harness")
    }

    private func reportUpdateChecking() {
        showBanner(
            "Checking for Harness updates…",
            detail: "The running version keeps working while this happens.",
            kind: .info)
    }

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
        var status: Int?
        let task = URLSession.shared.dataTask(with: url) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
        }
        task.resume()
        wait(until: { status != nil }, timeout: 30)
        return status
    }
}

/// Tests for the A/B update bookkeeping: which slot is booted, and how a slot
/// that fails to boot hands over to the other one. These encode the guarantee
/// that a broken upstream release cannot leave the app unusable.
enum UpdateTests {
    static func run() -> Never {
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

if arguments.contains("--test-update") {
    UpdateTests.run()
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
