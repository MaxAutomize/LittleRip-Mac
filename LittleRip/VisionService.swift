import Foundation
import SwiftUI
import CoreGraphics

@MainActor
final class VisionService: ObservableObject {
    @Published var isOn: Bool = false
    @Published var isAnalyzing: Bool = false
    @Published var framesAnalyzed: Int = 0
    @Published var lastLatencyMs: Int = 0
    @Published var currentDirection: String? = nil

    private var task: Task<Void, Never>?
    private let framePath = "/tmp/littlerip_latest.jpg"
    private var lastModTime: Date = .distantPast

    private let systemPrompt = """
    You are controlling a robot. Look at the camera frame and decide which direction to move. Respond with ONLY one of these single words — nothing else:

    forward — if the path ahead is clear or mostly clear
    left — if you need to turn left
    right — if you need to turn right
    back — if you need to reverse

    Always pick a direction. One word only. No explanation.
    """

    private let keyCodeMap: [String: UInt16] = [
        "forward": 126, "up": 126,
        "back": 125, "backward": 125, "down": 125,
        "left": 123,
        "right": 124
    ]

    func start() {
        guard !isOn else { return }
        isOn = true
        task = Task {
            while !Task.isCancelled {
                await analyzeFrame()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isOn = false
        isAnalyzing = false
        currentDirection = nil
    }

    private func analyzeFrame() async {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: framePath),
              let mod = attrs[.modificationDate] as? Date,
              mod > lastModTime else { return }

        lastModTime = mod
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: framePath)) else { return }

        let b64 = data.base64EncodedString()
        isAnalyzing = true
        let start = Date()

        let userContent: [[String: Any]] = [
            ["type": "text", "text": "Which direction?"],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]]
        ]

        let body: [String: Any] = [
            "model": "gemma4:31b-cloud",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "max_tokens": 10
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            isAnalyzing = false
            return
        }

        do {
            var req = URLRequest(url: URL(string: "http://localhost:11434/v1/chat/completions")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = httpBody
            req.timeoutInterval = 60

            let (responseData, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                isAnalyzing = false
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let content = choices.first?["message"] as? [String: Any],
               let text = content["content"] as? String {

                let direction = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                lastLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
                framesAnalyzed += 1

                // Execute the key press
                if let code = keyCodeMap[direction] {
                    currentDirection = direction
                    let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
                    downEvent?.post(tap: .cghidEventTap)
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
                    upEvent?.post(tap: .cghidEventTap)
                    currentDirection = nil
                }
            }
        } catch {
            // silent fail, next frame will retry
        }

        isAnalyzing = false
    }
}