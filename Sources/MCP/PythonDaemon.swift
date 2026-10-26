import Foundation

/// Resident Python process daemon: process launch, crash restart, health check, stop.
///
/// Generic lifecycle skeleton (the parts shared by MCPProcessManager / TokenProxyManager are consolidated here).
/// Business decisions (State enum semantics, event broadcast, reuse probing, crash notification, when to read config)
/// remain with the composing party -- the Daemon reports them via the `onStateChange` / `onMaxRestarts` callbacks, and
/// the composing party maps them itself.
/// - Note: the basis for marking this `@unchecked Sendable` (not "it compiles, that's good enough"):
///   - `process` / `crashCount` / `isStopping` / `state`: owned exclusively by `lifecycleQueue`,
///     every write happens on that queue (`launchProcess` / `stopSync` / the dispatch block of
///     `terminationHandler` / the health check's two convergence points)
///   - `healthCheckTimer`: owned exclusively by the main thread -- `Timer` must live on a thread
///     with a runloop; lifecycleQueue has no runloop, so it inherently does not belong to that queue
///   - `onStateChange` / `onMaxRestarts`: assigned exactly once after init, read-only thereafter
///   - `config`: `let`, immutable
///
///   The closure of `DispatchQueue.async` is `@Sendable`; without the annotation every capture of self
///   raises `SendableClosureCaptures`, and the warning noise drowns out genuinely new warnings.
final class PythonDaemon: @unchecked Sendable {
    struct Config {
        /// Interpreter arguments (closure: a config reload can change the entry without rebuilding the daemon).
        var arguments: () -> [String]
        /// Port (closure: applies the new port after a config reload, avoiding a port race between the old and new processes)
        var port: () -> Int
        /// Health check path, defaults to /health
        var healthPath = "/health"
        /// The service field validated by the health check; nil means no validation (TokenProxy case)
        var service: String?
        /// stderr ready signals; if non-empty, listen on stderr after launch until the signal arrives and only then
        /// health-check; if empty, launch silently (nullDevice) and health-check immediately (TokenProxy case)
        var readySignals: [String] = []
        var maxRestarts = 3
        var restartDelaySec: TimeInterval = 2.0
        /// Health check polling cap (number of attempts), defaults to 20 x 0.5s ~= 10s. Heavy services
        /// (loading models, building indexes) may be slower; the composing party can raise it as needed
        /// without changing this constant.
        var healthCheckMaxRetries = 20
        /// Health check polling interval (seconds)
        var healthCheckIntervalSec: TimeInterval = 0.5
        /// Build environment variables from config live (no caching)
        var environment: () -> [String: String]
        var logTag = "PythonDaemon"
    }

    /// Generic daemon state. The composing party maps it to its own State enum in onStateChange and broadcasts.
    enum State: String {
        case stopped, starting, running, restarting, crashed
    }

    /// State. All write points converge onto `lifecycleQueue` and the main thread (see the various `state = ...`),
    /// but the callback consumers also assume the main thread -- they update the menu bar and post notifications
    /// there. Deliver callbacks uniformly on the main thread to avoid the UI being updated from a background queue.
    private(set) var state: State = .stopped {
        didSet {
            guard oldValue != state else { return }
            let changed = state
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(changed)
            }
        }
    }

    /// State change callback (the composing party updates its own State + broadcasts)
    var onStateChange: ((State) -> Void)?
    /// Callback for reaching the restart cap (the composing party decides whether to notify / stop)
    var onMaxRestarts: ((Int) -> Void)?

    /// Buffer cap for ready-signal probing (bytes); beyond this only the tail is kept.
    private static let readyBufferLimit = 64 * 1024

    private var process: Process?
    private var healthCheckTimer: Timer?
    private var crashCount = 0
    private var isStopping = false
    private let lifecycleQueue = DispatchQueue(label: "python-daemon-lifecycle")
    private let config: Config

    init(config: Config) {
        self.config = config
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    var processIdentifier: Int32? {
        process?.processIdentifier
    }

    /// Probe whether the port already has a healthy process (reuse it if healthy, avoiding a duplicate spawn port race).
    /// The service check prevents mistakenly reusing another service on the same port (MCP case).
    func probeExistingServer() -> Bool {
        guard let url = HTTP.localURL(port: config.port(), path: config.healthPath) else {
            return false
        }
        // Here we wait synchronously on lifecycleQueue (a background queue), not on the main thread --
        // URLSession callbacks go through their own delegate queue and do not depend on the main runloop,
        // so the kind of main-thread deadlock recorded in CLAUDE.md cannot occur. Health polling on the
        // main thread goes through the async checkHealth version.
        let sem = DispatchSemaphore(value: 0)
        var healthy = false
        URLSessionManager.shared.directSession.dataTask(with: url) { [config] data, _, _ in
            if let data {
                healthy = isHealthyBody(data, service: config.service)
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2.0)
        return healthy
    }

    // MARK: - Lifecycle

    /// - Parameter reuseIfHealthy: true on cold start, reuse if the port is already occupied by a healthy process.
    ///   forceRestart/restart pass false -- those cases expect a real restart that applies the new config.
    func start(reuseIfHealthy: Bool = true) {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            // Reuse when the port is already occupied by a healthy process, avoiding a duplicate spawn port race
            if reuseIfHealthy, probeExistingServer() {
                state = .running
                debugLog("[\(config.logTag)] Reusing existing healthy process on port \(config.port())")
                return
            }
            launchProcess()
        }
    }

    func stop() {
        lifecycleQueue.async { [weak self] in
            self?.stopSync()
        }
    }

    /// Force restart (called on config reload): stop the old process -> wait for it to die -> spawn for real.
    ///
    /// If this process is an external healthy process (orphan) "reused" on cold start, `process` is nil,
    /// `stopSync()` cannot stop it, and the spawn will collide on the port. So a port-based cleanup step is
    /// added here. It only runs when there is no managed process -- the normal managed restart path is
    /// completely unchanged.
    func forceRestart() {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            let hadManagedProcess = process != nil
            stopSync()
            if !hadManagedProcess {
                terminatePortOccupant()
            }
            crashCount = 0
            launchProcess()
        }
    }

    func restart() {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            stopSync()
            launchProcess()
        }
    }

    // MARK: - Internal

    /// Synchronous implementation of stop (executed inside lifecycleQueue).
    private func stopSync() {
        isStopping = true
        // healthCheckTimer is created on the main thread (runloop); keep invalidation and nilling on the
        // same thread here, to avoid reading/writing this reference itself across queues
        DispatchQueue.main.async { [weak self] in
            self?.healthCheckTimer?.invalidate()
            self?.healthCheckTimer = nil
        }

        guard let proc = process else {
            state = .stopped
            return
        }

        proc.terminate()
        state = .stopped

        // Wait for the process to confirm death, preventing a new process from concurrently racing on the port
        let deadline = DispatchTime.now() + 3.0
        while proc.isRunning, .now() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        if process?.processIdentifier == proc.processIdentifier {
            process = nil
        }
    }

    /// Terminate the listener on the port -- used for the "reused an orphan process on cold start" case.
    ///
    /// In that case `process` is nil and `stopSync()` has nothing to work with; spawning directly fails
    /// because the port is still occupied (uvicorn reports Errno 48). Here we find the listener by port
    /// and clear it, so the subsequent `launchProcess()` can bind.
    ///
    /// **`-sTCP:LISTEN` is mandatory**: without it, `lsof -ti:<port>` also returns "clients connecting
    /// to that port" (measured on 8613 it returns Clash Verge, which is going through the proxy),
    /// and killing on that basis would kill unrelated processes by mistake.
    private func terminatePortOccupant() {
        for pid in listeningPIDs() {
            kill(pid, SIGTERM)
        }
        // Wait until the port is truly released before returning: launchProcess() binds the same port right
        // after, and the bind still fails if the process has not fully died -- this is exactly why this
        // function exists.
        let deadline = DispatchTime.now() + 3.0
        while .now() < deadline, !listeningPIDs().isEmpty {
            Thread.sleep(forTimeInterval: 0.1)
        }
        for pid in listeningPIDs() {
            kill(pid, SIGKILL)
        }
    }

    /// PIDs of listeners on the port (LISTEN only, excluding connecting parties).
    /// `lsof` uses the full path: this process is launched by launchd and PATH does not include /usr/sbin.
    private func listeningPIDs() -> [Int32] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-ti:\(config.port())", "-sTCP:LISTEN"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            debugLog("[\(config.logTag)] lsof call failed: \(error.localizedDescription)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func launchProcess() {
        isStopping = false
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: PythonScriptRunner.pythonVenvPath)
        proc.arguments = config.arguments()

        // Build environment variables from config live
        proc.environment = config.environment()

        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            let reason = p.terminationReason
            // This closure is invoked by the system on its own queue, while isStopping / crashCount / state
            // are all owned exclusively by lifecycleQueue (stopSync and launchProcess also write there).
            // Converge everything back onto that queue before reading/writing, eliminating this set of
            // unsynchronized races.
            lifecycleQueue.async { [weak self] in
                guard let self else { return }

                // The identity check must take precedence over isStopping. forceRestart's stopSync()
                // sets isStopping and immediately calls launchProcess(), whose first step resets the flag
                // back to false; by the time this async callback actually runs the flag is already invalid,
                // so the old process's normal exit is misjudged as a crash -- observed as an extra process
                // spawned out of thin air on every config reload, which collides with the occupied port and
                // enters an infinite restart loop (measured 2026-09-21: 784 times over 49 minutes).
                // If process has already been replaced with the new process, this exit belongs to the old
                // process; ignore it. On a real crash process still equals p, so this is unaffected.
                if process !== p { return }

                // Do not trigger a restart on an active stop() close
                if isStopping { return }

                // The criterion must cover both "killed by a signal" and "non-zero exit code": looking only
                // at .uncaughtSignal misses the most common failures -- unhandled Python exceptions, port
                // bind failures (uvicorn reports Errno 48 then exit 3), and external kills all degrade to
                // .exit, get treated as a normal exit, silently set .stopped, and never retry.
                if reason == .uncaughtSignal || p.terminationStatus != 0 {
                    crashCount += 1
                    let count = crashCount
                    debugLog(
                        "[\(config.logTag)] Process crashed (\(count)/\(config.maxRestarts))",
                    )
                    if count >= config.maxRestarts {
                        state = .crashed
                        DispatchQueue.main.async {
                            self.onMaxRestarts?(self.config.maxRestarts)
                        }
                        return
                    }
                    state = .restarting
                    DispatchQueue.main.asyncAfter(deadline: .now() + config.restartDelaySec) {
                        self.lifecycleQueue.async {
                            // Probe the port once before restarting: if a healthy process is already
                            // running, this "crash" is most likely the new process colliding with an
                            // occupied port, and spawning again would just collide repeatedly. Adopt it
                            // directly, avoiding amplifying a single port conflict into a restart storm.
                            // probeExistingServer waits synchronously on lifecycleQueue (not the main
                            // thread) and will not deadlock -- same as the call site in start().
                            if self.probeExistingServer() {
                                self.crashCount = 0
                                self.state = .running
                                debugLog("[\(self.config.logTag)] Adopted healthy process after crash")
                            } else {
                                self.launchProcess()
                            }
                        }
                    }
                } else {
                    // Normal exit
                    state = .stopped
                }
            }
        }

        do {
            state = .starting

            // readySignals non-empty: capture stderr to detect the startup signal; empty: silent (nullDevice)
            let stderrPipe = Pipe()
            proc.standardError = config.readySignals.isEmpty ? FileHandle.nullDevice : stderrPipe
            proc.standardOutput = FileHandle.nullDevice

            try proc.run()
            process = proc
            debugLog("[\(config.logTag)] Started (PID \(proc.processIdentifier))")

            if config.readySignals.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.startHealthCheck()
                }
            } else {
                waitForReady(pipe: stderrPipe)
            }
        } catch {
            debugLog("[\(config.logTag)] Failed to launch: \(error.localizedDescription)")
            state = .crashed
        }
    }

    /// Listen on the process's stderr for the ready signal, then begin the health check.
    /// On EOF the handler must be cleared, otherwise the fd_monitoring queue fires endlessly and pegs the CPU.
    private func waitForReady(pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        var ready = false

        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            if !ready {
                buffer.append(data)
                // There must be a cap before ready: if the child process keeps outputting but never
                // emits the ready signal (e.g. repeatedly printing errors after a missing dependency),
                // an unbounded buffer would keep eating memory. Keep the tail -- the signal always
                // appears in the most recent output.
                if buffer.count > Self.readyBufferLimit {
                    buffer = Data(buffer.suffix(Self.readyBufferLimit))
                }
                guard let output = String(data: buffer, encoding: .utf8) else { return }

                if config.readySignals.contains(where: { output.contains($0) }) {
                    ready = true
                    DispatchQueue.main.async { [weak self] in
                        self?.startHealthCheck()
                    }
                }
            }
            // After ready, keep reading and discard the data, preventing the pipe buffer from filling up and blocking the child process
        }
    }

    /// Poll /health until ok or timeout.
    /// The health check must be async/await + @MainActor; DispatchSemaphore cannot be used
    /// (blocking the main thread deadlocks URLSession callbacks -- a lesson measured in this project, see CLAUDE.md).
    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        guard let url = HTTP.localURL(port: config.port(), path: config.healthPath) else {
            return
        }
        var retries = 0
        let maxRetries = config.healthCheckMaxRetries

        healthCheckTimer = Timer.scheduledTimer(
            withTimeInterval: config.healthCheckIntervalSec, repeats: true,
        ) { [weak self] timer in
            guard let self else { return }

            retries += 1
            if retries > maxRetries {
                debugLog("[\(config.logTag)] Health check timed out (unresponsive)")
                timer.invalidate()
                // stopSync touches process / isStopping and must run on lifecycleQueue
                // -- the Timer callback is on the main thread, and calling it directly would race with launchProcess
                lifecycleQueue.async { [weak self] in
                    guard let self else { return }
                    state = .crashed
                    stopSync()
                }
                return
            }

            Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                let healthy = await checkHealth(url: url)
                if healthy {
                    // crashCount and state are both owned exclusively by lifecycleQueue; converge back onto that queue
                    lifecycleQueue.async { [weak self] in
                        guard let self else { return }
                        crashCount = 0
                        state = .running
                    }
                    timer.invalidate()
                    debugLog("[\(config.logTag)] Server ready")
                }
            }
        }
    }

    @MainActor
    private func checkHealth(url: URL) async -> Bool {
        do {
            let (data, _) = try await URLSessionManager.shared.directSession.data(from: url)
            return isHealthyBody(data, service: config.service)
        } catch {
            return false
        }
    }
}

/// Health response determination. The two consumers (reuse probing `probeExistingServer` and
/// polling check `checkHealth`) share the same criterion.
///
/// The reason for extracting it is not to save a few lines: when the criterion is scattered the two
/// places easily drift -- one widens, one tightens -- producing a state like "reused an existing
/// process but keeps judging it not ready" that only reproduces through a single entry point.
private func isHealthyBody(_ data: Data, service: String?) -> Bool {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (json["status"] as? String) == "ok"
    else {
        return false
    }
    return service == nil || (json["service"] as? String) == service
}
