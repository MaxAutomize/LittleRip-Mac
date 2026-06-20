import Foundation
import AppKit

// Camera connection secrets are read from ~/.littlerip/camera.json (gitignored / lives
// outside the repo). See camera.example.json for the format. If the file is absent the
// app falls back to harmless placeholders so it still builds and runs.
struct CameraSecrets: Codable {
    let rtspURL: String?
    let activatorPath: String?

    static func load() -> CameraSecrets {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".littlerip/camera.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CameraSecrets.self, from: data) else {
            return CameraSecrets(rtspURL: nil, activatorPath: nil)
        }
        return decoded
    }
}

@MainActor
final class CameraService: ObservableObject {
    @Published var isOn: Bool = false
    @Published var isStarting: Bool = false
    @Published var latestFrame: NSImage?

    private var ffmpegProcess: Process?
    private let frameURL = URL(fileURLWithPath: "/tmp/littlerip_latest.jpg")
    private var refreshTimer: Timer?

    private let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
    private let rtspURL: String
    private let activatorPath: String

    init() {
        let secrets = CameraSecrets.load()
        rtspURL = secrets.rtspURL ?? "rtsp://localhost:554/rtp/0"
        activatorPath = secrets.activatorPath ?? ""
    }

    func start() {
        guard !isOn, !isStarting else { return }
        isStarting = true

        Task {
            do {
                if !activatorPath.isEmpty {
                    try await Self.runCommand(
                        executable: "/usr/bin/env",
                        arguments: ["python3", activatorPath],
                        extraPath: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                    )
                }

                try startFFmpeg()
                isOn = true
                isStarting = false
                startRefreshing()
            } catch {
                isStarting = false
                isOn = false
                stop()
            }
        }
    }

    func stop() {
        if let process = ffmpegProcess, process.isRunning {
            process.terminate()
        }
        ffmpegProcess = nil
        isOn = false
        isStarting = false
        stopRefreshing()
    }

    // MARK: - FFmpeg

    private func startFFmpeg() throws {
        if FileManager.default.fileExists(atPath: frameURL.path) {
            try? FileManager.default.removeItem(at: frameURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-y", "-rtsp_transport", "tcp", "-i", rtspURL,
            "-vf", "fps=1", "-update", "1", frameURL.path
        ]
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try process.run()
        ffmpegProcess = process
    }

    // MARK: - Frame Refresh

    private func startRefreshing() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.loadFrame()
            }
        }
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func loadFrame() {
        guard FileManager.default.fileExists(atPath: frameURL.path),
              let image = NSImage(contentsOf: frameURL) else { return }
        latestFrame = image
    }

    // MARK: - Shell

    private static func runCommand(executable: String, arguments: [String], extraPath: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ["PATH": extraPath, "HOME": NSHomeDirectory()]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err

            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(throwing: CameraError.failed(stderr.isEmpty ? "Command failed" : stderr))
                }
            }

            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

enum CameraError: LocalizedError {
    case failed(String)
    var errorDescription: String? { String(describing: self) }
}