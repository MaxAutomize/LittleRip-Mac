import Foundation
import Network

struct RobotControlConfig: Codable {
    let espHost: String?
    let espPort: UInt16?
    let commands: [String: String]?

    var host: String { espHost?.isEmpty == false ? espHost! : "192.168.4.1" }
    var port: UInt16 { espPort ?? 4210 }

    var commandMap: [String: String] {
        var base = [
            "forward": "F",
            "up": "F",
            "back": "B",
            "backward": "B",
            "down": "B",
            "left": "L",
            "right": "R",
            "leftfootforward": "Q",
            "leftfootback": "A",
            "leftfootstop": "q",
            "rightfootforward": "O",
            "rightfootback": "l",
            "rightfootstop": "o",
            "weightshiftleft": "Z",
            "weightshiftright": "X",
            "weightshiftstop": "z",
            "stop": "S"
        ]
        commands?.forEach { base[$0.key.lowercased()] = $0.value }
        return base
    }

    static func load() -> RobotControlConfig {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".littlerip/robot.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RobotControlConfig.self, from: data) else {
            return RobotControlConfig(espHost: nil, espPort: nil, commands: nil)
        }
        return decoded
    }
}

@MainActor
final class RobotControlService: ObservableObject {
    @Published private(set) var lastCommand = "S"
    @Published private(set) var lastDirection = "stop"
    @Published private(set) var packetsSent = 0
    @Published private(set) var endpointDescription = ""

    private let config: RobotControlConfig
    private let queue = DispatchQueue(label: "LittleRip.ESP.UDP", qos: .userInteractive)
    private var connection: NWConnection?

    init(config: RobotControlConfig = .load()) {
        self.config = config
        endpointDescription = "udp://\(config.host):\(config.port)"
        connect()
    }

    deinit {
        connection?.cancel()
    }

    func reconnect() {
        connection?.cancel()
        connection = nil
        connect()
    }

    func send(direction: String) {
        let normalized = direction.lowercased()
        guard let command = config.commandMap[normalized] else { return }
        sendRaw(command, direction: normalized)
    }

    func stop() {
        send(direction: "stop")
    }

    func pulse(direction: String, duration: TimeInterval = 0.18) {
        send(direction: direction)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            stop()
        }
    }

    private func connect() {
        guard let port = NWEndpoint.Port(rawValue: config.port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: .udp)
        self.connection = connection
        connection.start(queue: queue)
    }

    private func sendRaw(_ command: String, direction: String) {
        if connection == nil { connect() }
        guard let data = command.data(using: .utf8), let connection else { return }

        lastCommand = command
        lastDirection = direction
        packetsSent += 1

        // UDP has no handshake/ack. This keeps latency minimal; the ESP should
        // treat commands as latest-state packets and stop on "S".
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
