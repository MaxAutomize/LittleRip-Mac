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

    private weak var robot: RobotControlService?
    private var task: Task<Void, Never>?

    private let rangeFile = URL(fileURLWithPath: "/tmp/littlebot_hcsr04.txt")
    private let soundFile = URL(fileURLWithPath: "/tmp/littlebot_sound.txt")
    private let imuFile = URL(fileURLWithPath: "/tmp/littlebot_mpu6050.json")

    func start(robot: RobotControlService) {
        guard !isOn else { return }
        self.robot = robot
        isOn = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runOnce()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isOn = false
        modelOutput = "—"
        lastCommand = "stop"
        activeAction = nil
        robot?.stop()
    }

    func runOnce() async {
        guard isOn else { return }
        let input = compactSensorInput()
        modelInput = input
        let start = Date()
        do {
            let command = try await askGLM(input)
            lastLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
            ticks += 1
            lastUpdated = Date()
            modelOutput = command
            execute(command)
        } catch {
            lastLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
            modelOutput = "ERR"
        }
    }

    private func compactSensorInput() -> String {
        let range = useRangeSound ? read(rangeFile, fallback: "?") : "off"
        let sound = useRangeSound ? read(soundFile, fallback: "?") : "off"
        let imu = useIMU ? read(imuFile, fallback: "?") : "off"
        return "r=\(range);s=\(sound);imu=\(imu)"
            .replacingOccurrences(of: "\n", with: " ")
            .prefixString(900)
    }

    private func read(_ url: URL, fallback: String) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return fallback
        }
        return text.prefixString(300)
    }

    private func askGLM(_ input: String) async throws -> String {
        // Very short context for speed. The model should output one tiny command.
        let prompt = """
        Robot balance controller. Output one command only.
        Commands: LF,RF,LB,RB,WL,WR,LS,RS,WS,STOP,NONE.
        LF left foot forward. RF right foot forward. LB left foot back. RB right foot back. WL shift weight left. WR shift weight right. LS stop left foot. RS stop right foot. WS stop weight shift.
        Prefer safe/stable action from sensor+IMU. No explanation.
        Data: \(input)
        """

        let body: [String: Any] = [
            "model": "glm-5.1:cloud",
            "messages": [["role": "user", "content": prompt]],
            "think": false,
            "stream": false,
            "options": ["num_predict": 4, "temperature": 0]
        ]

        let httpBody = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
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
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = ["LF", "RF", "LB", "RB", "WL", "WR", "LS", "RS", "WS", "STOP", "NONE"]
        return allowed.first { upper.contains($0) } ?? "NONE"
    }

    private func execute(_ command: String) {
        lastCommand = command
        switch command {
        case "LF": activeAction = "leftFootForward"; robot?.pulse(direction: "leftFootForward", duration: 0.16)
        case "RF": activeAction = "rightFootForward"; robot?.pulse(direction: "rightFootForward", duration: 0.16)
        case "LB": activeAction = "leftFootBack"; robot?.pulse(direction: "leftFootBack", duration: 0.16)
        case "RB": activeAction = "rightFootBack"; robot?.pulse(direction: "rightFootBack", duration: 0.16)
        case "WL": activeAction = "weightShiftLeft"; robot?.pulse(direction: "weightShiftLeft", duration: 0.16)
        case "WR": activeAction = "weightShiftRight"; robot?.pulse(direction: "weightShiftRight", duration: 0.16)
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
