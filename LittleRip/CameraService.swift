import Foundation
import AppKit

// Camera connection secrets are read from ~/.littlerip/camera.json (gitignored / lives
// outside the repo). See camera.example.json for the format. If the file is absent the
// app falls back to harmless placeholders so it still builds and runs.
struct CameraConfig: Codable, Identifiable, Equatable {
    let name: String?
    let uid: String?
    let rtspURL: String?

    var id: String { uid ?? name ?? rtspURL ?? "camera" }
    var displayName: String { name ?? uid.map { "Camera \($0.suffix(4))" } ?? "Camera" }

    init(name: String? = nil, uid: String? = nil, rtspURL: String? = nil) {
        self.name = name
        self.uid = uid
        self.rtspURL = rtspURL
    }
}

struct CameraRuntimeState {
    var isOn: Bool = false
    var isStarting: Bool = false
    var latestFrame: NSImage? = nil
    var lastFrameModifiedAt: Date? = nil
    var lastFrameLoadedAt: Date? = nil
}

enum CameraFrameMode: String, CaseIterable, Identifiable {
    case fast
    case slow

    var id: String { rawValue }
    var label: String { self == .fast ? "Vision" : "Tutor" }
    var detail: String { self == .fast ? "D-pad arrows" : "Math tutor" }
    var ffmpegFPS: String { "1" }
    var refreshInterval: TimeInterval { 1 }
}

struct CameraSecrets: Codable {
    let rtspURL: String?
    let activatorPath: String?
    let cameras: [CameraConfig]?

    var configuredCameras: [CameraConfig] {
        if let cameras, !cameras.isEmpty { return cameras }
        return [CameraConfig(name: "Camera", uid: nil, rtspURL: rtspURL)]
    }

    static func load() -> CameraSecrets {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".littlerip/camera.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CameraSecrets.self, from: data) else {
            return CameraSecrets(rtspURL: nil, activatorPath: nil, cameras: nil)
        }
        return decoded
    }
}

@MainActor
final class CameraService: ObservableObject {
    @Published private var states: [String: CameraRuntimeState] = [:]
    @Published var activeCameraID: String?
    @Published var activeCameraName: String?
    @Published private(set) var frameMode: CameraFrameMode = .fast

    let cameras: [CameraConfig]

    var isOn: Bool { states.values.contains { $0.isOn } }
    var isStarting: Bool { states.values.contains { $0.isStarting } }
    var latestFrame: NSImage? {
        guard let activeCameraID else { return nil }
        return states[activeCameraID]?.latestFrame
    }

    private var ffmpegProcesses: [String: Process] = [:]
    private var relayProcesses: [String: Process] = [:]
    private var refreshTimers: [String: Timer] = [:]
    private var desiredCameraIDs: Set<String> = []

    private let sharedFrameURL = URL(fileURLWithPath: "/tmp/littlerip_latest.jpg")
    private let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
    private let fallbackRTSPURL: String
    private let activatorPath: String

    init() {
        let secrets = CameraSecrets.load()
        cameras = secrets.configuredCameras
        fallbackRTSPURL = secrets.rtspURL ?? cameras.first?.rtspURL ?? "rtsp://localhost:554/rtp/0"
        activatorPath = secrets.activatorPath ?? ""

        for config in cameras {
            states[config.id] = CameraRuntimeState()
        }
    }

    func state(for config: CameraConfig) -> CameraRuntimeState {
        states[config.id] ?? CameraRuntimeState()
    }

    func setFrameMode(_ mode: CameraFrameMode) {
        guard frameMode != mode else { return }
        let running = cameras.filter { state(for: $0).isOn || state(for: $0).isStarting }
        frameMode = mode

        // Rebuild running ffmpeg streams with the new fps setting.
        for config in running {
            cleanup(cameraID: config.id, clearDesired: false)
            connect(camera: config)
        }
    }

    func start(camera config: CameraConfig) {
        desiredCameraIDs.insert(config.id)
        connect(camera: config)
    }

    private func connect(camera config: CameraConfig) {
        let id = config.id
        let current = states[id] ?? CameraRuntimeState()
        guard desiredCameraIDs.contains(id), !current.isOn, !current.isStarting else { return }

        activeCameraID = id
        activeCameraName = config.displayName
        updateState(id: id) {
            $0.isStarting = true
            $0.lastFrameLoadedAt = Date()
        }

        Task {
            do {
                var streamURL = config.rtspURL ?? fallbackRTSPURL
                if !activatorPath.isEmpty {
                    // Keep the relay activator alive. These cameras stop after a
                    // few frames unless the UDP hello/keepalive continues.
                    streamURL = try await startRelayProcess(camera: config, cameraID: id)
                }

                guard desiredCameraIDs.contains(id) else { return }
                try startFFmpeg(rtspURL: streamURL, cameraID: id)
                updateState(id: id) {
                    $0.isOn = true
                    $0.isStarting = false
                    $0.lastFrameLoadedAt = Date()
                }
                startRefreshing(cameraID: id)
            } catch {
                cleanup(cameraID: id, clearDesired: false)
                guard desiredCameraIDs.contains(id) else { return }
                updateState(id: id) {
                    $0.isOn = false
                    $0.isStarting = true
                    $0.lastFrameLoadedAt = Date()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.desiredCameraIDs.contains(id) else { return }
                    self.updateState(id: id) { $0.isStarting = false }
                    self.connect(camera: config)
                }
            }
        }
    }

    func stop(camera config: CameraConfig) {
        cleanup(cameraID: config.id, clearDesired: true)
    }

    private func cleanup(cameraID id: String, clearDesired: Bool) {
        if clearDesired { desiredCameraIDs.remove(id) }

        if let process = ffmpegProcesses[id], process.isRunning {
            process.terminate()
        }
        ffmpegProcesses[id] = nil

        if let relay = relayProcesses[id], relay.isRunning {
            relay.terminate()
        }
        relayProcesses[id] = nil

        stopRefreshing(cameraID: id)
        updateState(id: id) {
            $0.isOn = false
            $0.isStarting = false
        }

        if activeCameraID == id && clearDesired {
            let nextActive = cameras.first { state(for: $0).isOn && $0.id != id }
            activeCameraID = nextActive?.id
            activeCameraName = nextActive?.displayName
        }
    }

    func stop() {
        for config in cameras {
            stop(camera: config)
        }
        activeCameraID = nil
        activeCameraName = nil
    }

    private func restart(camera config: CameraConfig) {
        let id = config.id
        guard desiredCameraIDs.contains(id), let state = states[id], state.isOn, !state.isStarting else { return }
        cleanup(cameraID: id, clearDesired: false)
        connect(camera: config)
    }

    // MARK: - Relay Activator

    private func startRelayProcess(camera config: CameraConfig, cameraID: String) async throws -> String {
        if let existing = relayProcesses[cameraID], existing.isRunning {
            existing.terminate()
        }
        relayProcesses[cameraID] = nil

        var arguments = ["python3", "-u", activatorPath, "--keepalive"]
        if let uid = config.uid, !uid.isEmpty {
            arguments += ["--uid", uid]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Drain stderr so the helper can never block because a pipe fills up.
        err.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var finished = false
            var buffer = Data()

            func finish(_ result: Result<String, Error>, terminate: Bool) {
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                finished = true
                lock.unlock()

                // Keep draining stdout after success so the helper can never block.
                if terminate {
                    out.fileHandleForReading.readabilityHandler = nil
                    if process.isRunning { process.terminate() }
                } else if case .failure = result {
                    out.fileHandleForReading.readabilityHandler = nil
                }

                switch result {
                case .success(let url):
                    continuation.resume(returning: url)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    if !process.isRunning {
                        finish(.failure(CameraError.failed("Relay activator exited before printing RTSP_URL")), terminate: false)
                    }
                    return
                }
                buffer.append(data)
                if let text = String(data: buffer, encoding: .utf8),
                   let url = Self.extractMachineRTSPURL(from: text) {
                    // Leave process running: it sends UDP/cloud keepalives in the background.
                    finish(.success(url), terminate: false)
                }
            }

            process.terminationHandler = { p in
                if p.terminationStatus != 0 {
                    finish(.failure(CameraError.failed("Relay activator exited with status \(p.terminationStatus)")), terminate: false)
                }
            }

            do {
                try process.run()
                relayProcesses[cameraID] = process
            } catch {
                finish(.failure(error), terminate: false)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 75) {
                finish(.failure(CameraError.failed("Timed out waiting for RTSP_URL")), terminate: true)
            }
        }
    }

    // MARK: - FFmpeg

    private func startFFmpeg(rtspURL: String, cameraID: String) throws {
        let url = frameURL(for: cameraID)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-y",
            "-loglevel", "error",
            "-rtsp_transport", "tcp",
            "-rw_timeout", "5000000",
            "-fflags", "+discardcorrupt+genpts",
            "-err_detect", "ignore_err",
            "-i", rtspURL,
            "-vf", "fps=\(frameMode.ffmpegFPS)",
            "-update", "1",
            url.path
        ]

        // Drain ffmpeg pipes. If stderr/stdout fills, ffmpeg can block and the
        // preview looks frozen even though the app is still running.
        let out = Pipe()
        let err = Pipe()
        out.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        err.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.standardOutput = out
        process.standardError = err

        process.terminationHandler = { _ in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }

        try process.run()
        ffmpegProcesses[cameraID] = process
    }

    // MARK: - Frame Refresh

    private func startRefreshing(cameraID: String) {
        refreshTimers[cameraID]?.invalidate()
        refreshTimers[cameraID] = Timer.scheduledTimer(withTimeInterval: frameMode.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.loadFrame(cameraID: cameraID)
            }
        }
    }

    private func stopRefreshing(cameraID: String) {
        refreshTimers[cameraID]?.invalidate()
        refreshTimers[cameraID] = nil
    }

    private func loadFrame(cameraID: String) {
        let url = frameURL(for: cameraID)
        let now = Date()

        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modifiedAt = attrs[.modificationDate] as? Date else {
            restartIfStale(cameraID: cameraID, now: now)
            return
        }

        if let lastModified = states[cameraID]?.lastFrameModifiedAt,
           modifiedAt <= lastModified {
            restartIfStale(cameraID: cameraID, now: now)
            return
        }

        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else {
            restartIfStale(cameraID: cameraID, now: now)
            return
        }

        // Use NSImage(data:) instead of NSImage(contentsOf:). The contentsOf URL
        // initializer can cache by path, which made the preview stay stuck on an
        // old JPEG even while ffmpeg was overwriting the file every second.
        updateState(id: cameraID) {
            $0.latestFrame = image
            $0.lastFrameModifiedAt = modifiedAt
            $0.lastFrameLoadedAt = now
        }

        // Save a copy into the rolling frame buffer so the tutor can pick the
        // clearest frame instead of always using the newest (possibly blurry)
        // one.
        saveToBuffer(data: data, cameraID: cameraID)

        // VisionService still watches /tmp/littlerip_latest.jpg. The currently
        // active camera mirrors its latest frame there, while every camera keeps
        // its own preview file too.
        if activeCameraID == cameraID {
            try? FileManager.default.removeItem(at: sharedFrameURL)
            try? FileManager.default.copyItem(at: url, to: sharedFrameURL)
        }
    }

    // MARK: - Frame Buffer

    private let bufferDir = "/tmp/littlerip_buffer"
    private let bufferMaxFrames = 8

    private func saveToBuffer(data: Data, cameraID: String) {
        let dir = URL(fileURLWithPath: bufferDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let file = dir.appendingPathComponent("\(cameraID)_\(stamp).jpg")
        try? data.write(to: file)

        // Prune old frames for this camera, keep only the most recent bufferMaxFrames.
        if let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let mine = entries.filter { $0.lastPathComponent.hasPrefix(cameraID + "_") }
                .sorted { (a, b) -> Bool in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da < db
                }
            if mine.count > bufferMaxFrames {
                for f in mine.prefix(mine.count - bufferMaxFrames) {
                    try? FileManager.default.removeItem(at: f)
                }
            }
        }
    }

    /// Returns the best-quality buffered frame (largest file = most visual detail)
    /// for the given camera, or nil if the buffer is empty.
    func bestBufferedFrame(for cameraID: String) -> Data? {
        let dir = URL(fileURLWithPath: "/tmp/littlerip_buffer")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let mine = entries.filter { $0.lastPathComponent.hasPrefix(cameraID + "_") }
        guard !mine.isEmpty else { return nil }

        // Pick the frame with the largest file size — bigger JPEG = clearer/more detail.
        let best = mine.max { a, b in
            let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sa < sb
        }
        guard let best else { return nil }
        return try? Data(contentsOf: best)
    }

    private func restartIfStale(cameraID: String, now: Date) {
        guard let config = cameras.first(where: { $0.id == cameraID }),
              let state = states[cameraID],
              state.isOn,
              !state.isStarting else { return }

        let lastLoaded = state.lastFrameLoadedAt ?? .distantPast
        if now.timeIntervalSince(lastLoaded) > 4 {
            restart(camera: config)
        }
    }

    private func frameURL(for cameraID: String) -> URL {
        let safeID = cameraID.map { char -> String in
            char.isLetter || char.isNumber ? String(char) : "_"
        }.joined()
        return URL(fileURLWithPath: "/tmp/littlerip_\(safeID).jpg")
    }

    private func updateState(id: String, mutate: (inout CameraRuntimeState) -> Void) {
        var state = states[id] ?? CameraRuntimeState()
        mutate(&state)
        states[id] = state
    }

    // MARK: - Helpers

    nonisolated private static func extractMachineRTSPURL(from output: String) -> String? {
        for rawLine in output.split(separator: "\n").reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = line.range(of: "RTSP_URL=") {
                return cleanRTSP(String(line[range.upperBound...]))
            }
        }
        return nil
    }

    nonisolated private static func extractRTSPURL(from output: String) -> String? {
        for rawLine in output.split(separator: "\n").reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = line.range(of: "RTSP_URL=") {
                return cleanRTSP(String(line[range.upperBound...]))
            }
            if let range = line.range(of: "rtsp://") {
                return cleanRTSP(String(line[range.lowerBound...]))
            }
        }
        return nil
    }

    nonisolated private static func cleanRTSP(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
    }
}

enum CameraError: LocalizedError {
    case failed(String)
    var errorDescription: String? { String(describing: self) }
}
