import Foundation

@MainActor
final class UltrasonicSensorService: ObservableObject {
    @Published var isOn = false
    @Published var distanceCM: Double?
    @Published var lastRawValue = "Awaiting HC-SR04 data"
    @Published var lastSoundRawValue = "Awaiting sound sensor data"
    @Published var lastUpdated: Date?
    @Published var sensorAIStatus = "AI standby"
    @Published var sensorAILatencyMs = 0

    private var timer: Timer?
    private let sensorFile = URL(fileURLWithPath: "/tmp/littlebot_hcsr04.txt")
    private let soundFile = URL(fileURLWithPath: "/tmp/littlebot_sound.txt")
    private var lastAnalysisInput = ""
    private var lastAnalysisAt: Date = .distantPast
    private var isAnalyzing = false

    var statusText: String {
        guard isOn else { return "Offline" }
        if let distanceCM {
            return String(format: "%.1f cm", distanceCM)
        }
        return "Listening"
    }

    func start() {
        guard !isOn else { return }
        isOn = true
        readOnce()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readOnce() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isOn = false
        distanceCM = nil
        lastRawValue = "Sensor offline"
        lastSoundRawValue = "Sound sensor offline"
        lastUpdated = nil
        sensorAIStatus = "AI standby"
        sensorAILatencyMs = 0
        isAnalyzing = false
    }

    private func readOnce() {
        guard isOn else { return }

        let distanceText = (try? String(contentsOf: sensorFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let soundText = (try? String(contentsOf: soundFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""

        if distanceText.isEmpty {
            lastRawValue = "Waiting for /tmp/littlebot_hcsr04.txt"
            distanceCM = nil
        } else {
            lastRawValue = distanceText
            distanceCM = parseFirstNumber(distanceText)
        }

        if soundText.isEmpty {
            lastSoundRawValue = "Waiting for /tmp/littlebot_sound.txt"
        } else {
            lastSoundRawValue = soundText
        }

        if !distanceText.isEmpty || !soundText.isEmpty {
            lastUpdated = Date()
            maybeAnalyze(distanceText: distanceText, soundText: soundText)
        }
    }

    private func parseFirstNumber(_ text: String) -> Double? {
        text
            .replacingOccurrences(of: "cm", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "distance", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "sound", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: ":", with: " ")
            .split(separator: " ")
            .compactMap { Double($0) }
            .first
    }

    private func maybeAnalyze(distanceText: String, soundText: String) {
        let input = "distance=\(distanceText.isEmpty ? "unknown" : distanceText); sound=\(soundText.isEmpty ? "unknown" : soundText)"
        guard input != lastAnalysisInput || Date().timeIntervalSince(lastAnalysisAt) > 2.0 else { return }
        guard !isAnalyzing else { return }

        lastAnalysisInput = input
        lastAnalysisAt = Date()
        isAnalyzing = true

        Task { @MainActor in
            let start = Date()
            do {
                sensorAIStatus = try await analyzeSensorsWithGLM(input)
                sensorAILatencyMs = Int(Date().timeIntervalSince(start) * 1000)
            } catch {
                sensorAIStatus = "AI retrying"
            }
            isAnalyzing = false
        }
    }

    private func analyzeSensorsWithGLM(_ input: String) async throws -> String {
        let prompt = """
        You are a low-latency robot safety sensor classifier.
        Read ultrasonic distance and sound sensor values.
        Return ONLY one word: clear, caution, stop, loud, quiet, or unknown.
        Prefer stop if distance is dangerously close. Prefer caution if distance is low or sound is unusually high.
        Sensor input: \(input)
        """

        let body: [String: Any] = [
            "model": "glm-5.1:cloud",
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "think": false,
            "stream": false,
            "options": [
                "num_predict": 6,
                "temperature": 0
            ]
        ]

        let httpBody = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = httpBody
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "SensorAI", code: 1)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NSError(domain: "SensorAI", code: 2)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
