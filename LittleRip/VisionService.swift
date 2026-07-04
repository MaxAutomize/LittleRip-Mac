import Foundation
import SwiftUI
import CoreGraphics
import AVFoundation

@MainActor
final class VisionService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isOn: Bool = false
    @Published var isAnalyzing: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var framesAnalyzed: Int = 0
    @Published var lastLatencyMs: Int = 0
    @Published var currentDirection: String? = nil
    @Published var currentTutorStep: Int = 1
    @Published var lastSpokenText: String = ""

    private var task: Task<Void, Never>?
    private let framePath = "/tmp/littlerip_latest.jpg"
    private var lastModTime: Date = .distantPast
    private var frameMode: CameraFrameMode = .fast
    private weak var cameraService: CameraService?
    private weak var robotControl: RobotControlService?

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var speechContinuation: CheckedContinuation<Void, Never>?
    private var currentStepInstruction: String?
    private var unclearFrameCount: Int = 0

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    var detail: String {
        if !isOn { return "Off" }
        if frameMode == .slow {
            if isSpeaking { return "Tutor speaking · step \(currentTutorStep)" }
            if isAnalyzing { return "Tutor thinking · step \(currentTutorStep)" }
            return "Tutor loop · step \(currentTutorStep) · \(framesAnalyzed) frames"
        }
        return "\(framesAnalyzed) frames · \(lastLatencyMs)ms"
    }

    private let robotSystemPrompt = """
    You are controlling a robot. Look at the camera frame and decide which direction to move. Respond with ONLY one of these single words — nothing else:

    forward — if the path ahead is clear or mostly clear
    left — if you need to turn left
    right — if you need to turn right
    back — if you need to reverse

    Always pick a direction. One word only. No explanation.
    """

    private let tutorSystemPrompt = """
    You are a helpful math tutor looking through a camera at the user's paper or screen.

    Goal: first identify/define the visible math question, then explain the next step and say exactly what the user should write down.

    Use your own judgment. Do not follow a fixed script. Do not repeat the same wording unless the user truly has not changed anything. Look at the current frame, decide what problem the user is working on, state that problem briefly, then give the next useful written step.

    If the problem is unreadable, blurry, cut off, or you cannot tell what question they mean, ask the user to rewrite it larger or hold it clearly in frame.

    Return ONLY valid JSON with keys: status, step_complete, spoken.
    status must be one of: unclear, rewrite_request, tutor.
    """

    private let keyCodeMap: [String: UInt16] = [
        "forward": 126, "up": 126,
        "back": 125, "backward": 125, "down": 125,
        "left": 123,
        "right": 124
    ]

    func start(frameMode: CameraFrameMode, camera: CameraService? = nil, robotControl: RobotControlService? = nil) {
        guard !isOn else {
            setFrameMode(frameMode)
            return
        }
        self.frameMode = frameMode
        self.cameraService = camera
        self.robotControl = robotControl
        resetTutorState()
        isOn = true
        task = Task {
            while !Task.isCancelled {
                await analyzeFrame()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func setFrameMode(_ mode: CameraFrameMode) {
        guard frameMode != mode else { return }
        frameMode = mode
        currentDirection = nil
        lastModTime = .distantPast
        if mode == .slow { resetTutorState() }
    }

    func stop() {
        task?.cancel()
        task = nil
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechContinuation?.resume()
        speechContinuation = nil
        isOn = false
        isAnalyzing = false
        isSpeaking = false
        currentDirection = nil
        resetTutorState()
    }

    private func resetTutorState() {
        currentTutorStep = 1
        currentStepInstruction = nil
        lastSpokenText = ""
        unclearFrameCount = 0
    }

    private func analyzeFrame() async {
        switch frameMode {
        case .fast:
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: framePath),
                  let mod = attrs[.modificationDate] as? Date,
                  mod > lastModTime else { return }
            lastModTime = mod
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: framePath)) else { return }
            await analyzeRobotFrame(data)

        case .slow:
            // Tutor mode: look through the rolling frame buffer and pick the
            // clearest frame (largest file = most detail) instead of always
            // using the newest one, which may be blurry or mid-motion.
            let bestData: Data?
            if let camera = cameraService, let cameraID = camera.activeCameraID,
               let best = camera.bestBufferedFrame(for: cameraID) {
                bestData = best
            } else if let data = try? Data(contentsOf: URL(fileURLWithPath: framePath)) {
                bestData = data
            } else {
                bestData = nil
            }
            guard let data = bestData else { return }
            await analyzeTutorFrame(data)
        }
    }

    private func analyzeRobotFrame(_ data: Data) async {
        isAnalyzing = true
        let start = Date()
        defer { isAnalyzing = false }

        do {
            let text = try await askVision(
                systemPrompt: robotSystemPrompt,
                userText: "Which direction?",
                imageData: data,
                maxTokens: 10
            )

            let direction = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            lastLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
            framesAnalyzed += 1

            if keyCodeMap[direction] != nil {
                currentDirection = direction
                if let robotControl {
                    robotControl.pulse(direction: direction, duration: 0.18)
                } else {
                    await KeySimulator.press(direction: direction, duration: 0.18)
                }
                try? await Task.sleep(nanoseconds: 180_000_000)
                currentDirection = nil
            }
        } catch {
            // next frame retries
        }
    }

    private func analyzeTutorFrame(_ data: Data) async {
        guard !isSpeaking else { return }
        isAnalyzing = true
        let start = Date()
        defer { isAnalyzing = false }

        let currentInstruction = currentStepInstruction ?? "No previous step yet."
        let previousSpoken = lastSpokenText.isEmpty ? "Nothing spoken yet." : lastSpokenText
        let userText = """
        Look at the math problem visible in this newest camera frame.

        Current tutor step number: \(currentTutorStep)
        Previous step/hint spoken: \(previousSpoken)
        Current step being checked: \(currentInstruction)

        Decide naturally what to do next:
        - If this is the first useful response, first define/read the question briefly, then say exactly what to write down for the first step.
        - Format the spoken response like: "The question is asking us to ... . First, write down ..."
        - On later responses, briefly remind what step we are on, then say exactly what to write next.
        - If the user appears to have completed the previous written step, set step_complete true and give the next written step.
        - If the previous step is not completed, set step_complete false and give a short different hint plus what to write.
        - If the image does not clearly show the problem, return status unclear with empty spoken.
        - If it needs user action to become readable, return status rewrite_request and ask them to rewrite or hold the question clearly.

        Keep spoken short and natural. Return only JSON.
        """

        do {
            let text = try await askTutorGPTViaPi(
                userText: userText,
                imageData: data
            )

            lastLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
            framesAnalyzed += 1

            let reply = parseTutorReply(text)

            if reply.status == "unclear" {
                unclearFrameCount += 1
                lastSpokenText = "Scanning frames for a clear view of the problem…"
                if unclearFrameCount >= 4 {
                    unclearFrameCount = 0
                    let request = "Please rewrite the question larger or hold it clearly in the frame so I can read it."
                    lastSpokenText = request
                    await speak(request)
                }
                return
            }

            unclearFrameCount = 0
            let spoken = reply.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { return }

            if reply.status == "rewrite_request" {
                lastSpokenText = spoken
                await speak(spoken)
                return
            }

            if currentStepInstruction == nil {
                currentStepInstruction = spoken
            } else if reply.stepComplete {
                currentTutorStep += 1
                currentStepInstruction = spoken
            }

            lastSpokenText = spoken
            await speak(spoken)
        } catch {
            // next loop retries with the newest frame
        }
    }

    private func askVision(systemPrompt: String, userText: String, imageData: Data, maxTokens: Int) async throws -> String {
        let b64 = imageData.base64EncodedString()
        let body: [String: Any] = [
            "model": "gemma4:31b-cloud",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText, "images": [b64]]
            ],
            "think": false,
            "stream": false,
            "options": [
                "num_predict": maxTokens,
                "temperature": 0
            ]
        ]

        let httpBody = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = httpBody
        req.timeoutInterval = 90

        let (responseData, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Vision", code: 1)
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NSError(domain: "Vision", code: 2)
        }
        return text
    }

    private func askTutorGPTViaPi(userText: String, imageData: Data) async throws -> String {
        let imageURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("littlerip-tutor-frame-\(UUID().uuidString).jpg")
        try imageData.write(to: imageURL)

        defer { try? FileManager.default.removeItem(at: imageURL) }

        let prompt = """
        \(userText)

        Important: Use the attached camera frame. Use your own reasoning normally, but final output must be only the JSON object requested. Do not include markdown or text outside JSON.
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/pi")
        process.arguments = [
            "--provider", "openai-codex",
            "--model", "gpt-5.5",
            "--thinking", "high",
            "--no-tools",
            "--no-session",
            "--mode", "text",
            "--print",
            "@\(imageURL.path)",
            prompt
        ]
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var finished = false

            func finish(_ result: Result<String, Error>, terminate: Bool) {
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                finished = true
                lock.unlock()

                if terminate, process.isRunning { process.terminate() }

                switch result {
                case .success(let text): continuation.resume(returning: text)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            process.terminationHandler = { p in
                let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    finish(.success(stdout), terminate: false)
                } else {
                    finish(.failure(NSError(domain: "PiGPT", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? "pi GPT call failed" : stderr])), terminate: false)
                }
            }

            do {
                try process.run()
            } catch {
                finish(.failure(error), terminate: false)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
                finish(.failure(NSError(domain: "PiGPT", code: 408, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for pi GPT model"])), terminate: true)
            }
        }
    }

    private func parseTutorReply(_ raw: String) -> (status: String, stepComplete: Bool, spoken: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end {
            jsonText = String(trimmed[start...end])
        } else {
            jsonText = trimmed
        }

        if let data = jsonText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let status = (json["status"] as? String ?? "tutor").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let complete = json["step_complete"] as? Bool ?? false
            let spoken = json["spoken"] as? String ?? ""
            return (status, complete, spoken)
        }

        // If the model fails JSON but gives text, say it only when it is useful.
        if trimmed.localizedCaseInsensitiveContains("don't see") ||
            trimmed.localizedCaseInsensitiveContains("cannot see") ||
            trimmed.localizedCaseInsensitiveContains("can't see") ||
            trimmed.localizedCaseInsensitiveContains("not clear") {
            return ("unclear", false, "")
        }
        return ("tutor", false, trimmed)
    }

    private func speak(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.45
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.voice = sangeetaEnhancedVoice() ?? AVSpeechSynthesisVoice(language: "en-IN") ?? AVSpeechSynthesisVoice(language: "en-US")

        isSpeaking = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            speechContinuation = continuation
            speechSynthesizer.speak(utterance)
        }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            speechContinuation?.resume()
            speechContinuation = nil
            isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            speechContinuation?.resume()
            speechContinuation = nil
            isSpeaking = false
        }
    }

    private func sangeetaEnhancedVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        return voices.first { voice in
            voice.name.localizedCaseInsensitiveContains("Sangeeta") && voice.quality == .premium
        } ?? voices.first { voice in
            voice.name.localizedCaseInsensitiveContains("Sangeeta") && voice.quality == .enhanced
        } ?? voices.first { voice in
            voice.name.localizedCaseInsensitiveContains("Sangeeta")
        }
    }
}
