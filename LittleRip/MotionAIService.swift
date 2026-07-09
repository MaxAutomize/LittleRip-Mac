import Foundation

@MainActor
final class MotionAIService: ObservableObject {
    @Published var isOn = false
    @Published var useRangeSound = true
    @Published var useIMU = false
    @Published var modelInput = "AI controller is off."
    @Published var modelOutput = "—"
    @Published var lastCommand = "—"
    @Published var lastLatencyMs = 0
    @Published var ticks = 0
    @Published var lastUpdated: Date?
    @Published var activeAction: String?
    @Published var loopStatus = "stopped"

    private weak var robot: RobotControlService?
    private var task: Task<Void, Never>?
    private var lastSubmittedInput = ""

    private let rangeFile = URL(fileURLWithPath: "/tmp/littlebot_hcsr04.txt")
    private let soundFile = URL(fileURLWithPath: "/tmp/littlebot_sound.txt")
    private let imuFile = URL(fileURLWithPath: "/tmp/littlebot_mpu6050.json")
    private let chatURL = URL(string: "http://127.0.0.1:11434/api/chat")!

    func start(robot: RobotControlService) {
        guard !isOn else { return }
        self.robot = robot
        isOn = true
        loopStatus = "warming glm"
        lastSubmittedInput = ""

        task = Task { [weak self] in
            await self?.warmGLM()
            await self?.continuousControllerLoop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isOn = false
        loopStatus = "stopped"
        modelOutput = "—"
        lastCommand = "stop"
        activeAction = nil
        robot?.stop()
    }

    private func continuousControllerLoop() async {
        while !Task.isCancelled && isOn {
            let input = compactSensorInput()
            modelInput = input
            lastSubmittedInput = input
            loopStatus = "glm in-flight · latest input only"

            let start = Date()
            do {
                let command = try await askGLM(input)
                guard !Task.isCancelled && isOn else { return }

                lastLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
                ticks += 1
                lastUpdated = Date()
                modelOutput = command
                loopStatus = "executed · reading next sensor frame"
                execute(command)

                // Yield to UI + sensor-file writers, then immediately consume the
                // newest sensor state. No stale queue is allowed to build up.
                try? await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                guard !Task.isCancelled && isOn else { return }
                lastLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
                modelOutput = "ERR"
                loopStatus = "error · retrying latest input"
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func warmGLM() async {
        do {
            _ = try await askGLM("warmup")
        } catch {
            // The real loop retries; warmup failure should not block controls.
        }
    }

    private func compactSensorInput() -> String {
        let range = useRangeSound ? read(rangeFile, fallback: "?") : "off"
        let sound = useRangeSound ? read(soundFile, fallback: "?") : "off"
        let imu = useIMU ? read(imuFile, fallback: "?") : "off"
        return "r=\(range);s=\(sound);imu=\(imu)"
            .replacingOccurrences(of: "\n", with: " ")
            .prefixString(700)
    }

    private func read(_ url: URL, fallback: String) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return fallback
        }
        return text.prefixString(240)
    }

    private func askGLM(_ input: String) async throws -> String {
        // Ultra-short context for speed. Latest sensor frame in, one command out.
        let prompt = """
        Balance bot. Reply one token only: LF RF LB RB WL WR LS RS WS STOP NONE.
        LF/RF foot forward. LB/RB foot back. WL/WR shift weight. LS/RS/WS stop part.
        Be safe, stable, fast. Data:
        \(input)
        """

        let body: [String: Any] = [
            "model": "glm-5.1:cloud",
            "messages": [["role": "user", "content": prompt]],
            "think": false,
            "stream": false,
            "keep_alive": "30m",
            "options": [
                "num_predict": 3,
                "temperature": 0,
                "num_ctx": 512
            ]
        ]

        let httpBody = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: chatURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = httpBody
        req.timeoutInterval = 8

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "MotionAI", code: 1)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NSError(domain: "MotionAI", code: 2)
        }
        return normalize(text)
    }

    private func normalize(_ text: String) -> String {
        let upper = text.uppercased()
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = ["STOP", "NONE", "LF", "RF", "LB", "RB", "WL", "WR", "LS", "RS", "WS"]
        return allowed.first { upper == $0 || upper.hasPrefix($0 + " ") || upper.contains("\n\($0)") } ?? allowed.first { upper.contains($0) } ?? "NONE"
    }

    private func execute(_ command: String) {
        lastCommand = command
        switch command {
        case "LF": activeAction = "leftFootForward"; robot?.pulse(direction: "leftFootForward", duration: 0.14)
        case "RF": activeAction = "rightFootForward"; robot?.pulse(direction: "rightFootForward", duration: 0.14)
        case "LB": activeAction = "leftFootBack"; robot?.pulse(direction: "leftFootBack", duration: 0.14)
        case "RB": activeAction = "rightFootBack"; robot?.pulse(direction: "rightFootBack", duration: 0.14)
        case "WL": activeAction = "weightShiftLeft"; robot?.pulse(direction: "weightShiftLeft", duration: 0.14)
        case "WR": activeAction = "weightShiftRight"; robot?.pulse(direction: "weightShiftRight", duration: 0.14)
        case "LS": activeAction = nil; robot?.send(direction: "leftFootStop")
        case "RS": activeAction = nil; robot?.send(direction: "rightFootStop")
        case "WS": activeAction = nil; robot?.send(direction: "weightShiftStop")
        case "STOP": activeAction = nil; robot?.stop()
        default: activeAction = nil
        }
    }
}

private extension String {
    func prefixString(_ maxLength: Int) -> String {
        if count <= maxLength { return self }
        return String(prefix(maxLength))
    }
}

private extension String.SubSequence {
    func prefixString(_ maxLength: Int) -> String {
        String(self).prefixString(maxLength)
    }
}
