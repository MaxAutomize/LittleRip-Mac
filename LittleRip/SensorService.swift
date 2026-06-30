import Foundation

@MainActor
final class UltrasonicSensorService: ObservableObject {
    @Published var isOn = false
    @Published var distanceCM: Double?
    @Published var lastRawValue = "Awaiting HC-SR04 data"
    @Published var lastUpdated: Date?

    private var timer: Timer?
    private let sensorFile = URL(fileURLWithPath: "/tmp/littlebot_hcsr04.txt")

    var statusText: String {
        guard isOn else { return "Offline" }
        if let distanceCM {
            return String(format: "%.1f cm", distanceCM)
        }
        return "Listening for ultrasonic range data"
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
        lastUpdated = nil
    }

    private func readOnce() {
        guard isOn else { return }
        guard let text = try? String(contentsOf: sensorFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            lastRawValue = "Waiting for /tmp/littlebot_hcsr04.txt"
            distanceCM = nil
            return
        }

        lastRawValue = text
        lastUpdated = Date()

        let number = text
            .replacingOccurrences(of: "cm", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "distance", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: ":", with: " ")
            .split(separator: " ")
            .compactMap { Double($0) }
            .first

        distanceCM = number
    }
}
